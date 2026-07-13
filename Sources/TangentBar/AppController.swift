// Wires the four layers: sensor → extraction → surfaces → engine.
// One controller, one flow: double-click → ladder → pill → panel → stream.

import AppKit
import ServiceManagement

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()
    private let eventTap = EventTap()
    private let pill = Pill()
    private let panel = TangentPanel()
    private let chatPanel = ChatPanel()
    private var chatExcerpt = ""
    private var chatHistory: [Excerpt.Turn] = []
    private let engine = Engine()
    private var statusItem: NSStatusItem?
    private let modelItem = NSMenuItem(title: "Define Model", action: nil, keyEquivalent: "")
    private let chatModelItem = NSMenuItem(title: "Chat Model", action: nil, keyEquivalent: "")
    private let triggerItem = NSMenuItem(title: "Trigger", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private let excludeItem = NSMenuItem(title: "Exclude This App", action: nil, keyEquivalent: "")
    private let excludedListItem = NSMenuItem(title: "Excluded Apps", action: nil, keyEquivalent: "")
    private let noModelItem = NSMenuItem(title: "No local models — Install Ollama…", action: nil, keyEquivalent: "")
    private var frontmostForExclude: String?
    private var localModels: [LocalModel] = []
    /// Badge state: "!" while either problem stands.
    private var axProblem = false
    private var noModels = false
    /// A define waiting out the triple-click window; a third click cancels it.
    private var pendingOpen: DispatchWorkItem?
    private let extractQueue = DispatchQueue(label: "tangent.extract", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        config.save()  // materialize defaults on first run
        setupEditMenu()

        if CommandLine.arguments.contains("--models") {
            runModelProbe()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--tangent"),
           CommandLine.arguments.count > i + 1 {
            runTangentProbe(word: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--termctx"),
           CommandLine.arguments.count > i + 1 {
            // Exercise the terminal context rung exactly as a cmux click would.
            let word = CommandLine.arguments[i + 1]
            if let ctx = TerminalContext.forWord(word, app: "cmux") {
                print("context (\(ctx.count) chars):\n…\(ctx.suffix(300))")
            } else {
                print("no terminal context for \"\(word)\"")
            }
            exit(0)
        }

        setupStatusItem()
        // Prewarm the saved model NOW — every ms counts against a ~7.6 s cold
        // JIT load. Discovery refines afterwards and re-prewarms on change.
        engine.prewarm(config: config)
        refreshLocalModels(autoSelect: true)

        if CommandLine.arguments.contains("--chat") {
            runChatProbe()
            return
        }
        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
            return
        }
        if CommandLine.arguments.contains("--demo") {
            // The canned panel, held open for screenshots; auto-exits.
            let center = CGPoint(x: (NSScreen.main?.frame.width ?? 1200) / 2,
                                 y: (NSScreen.main?.frame.height ?? 800) / 2)
            panel.present(word: "tangent", sourceApp: "TangentBar", model: config.tangentModel, atCG: center) {}
            panel.append("A line that touches a curve at a single point without crossing it; figuratively, a sudden divergence from the main subject — *exactly* the kind this app exists to indulge.")
            panel.setStatus("done · \(config.tangentModel) — click outside to dismiss")
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSApp.terminate(nil) }
            return
        }

        guard ensureTrusted() else { return }
        armTap()
    }

    // MARK: Permissions

    private func ensureTrusted() -> Bool {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        let trusted = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        if !trusted {
            axProblem = true
            updateBadge()
            // Poll until granted, then arm. (Real onboarding flow replaces this.)
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.axProblem = false
                self?.updateBadge()
                self?.armTap()
            }
        }
        return trusted
    }

    private func armTap() {
        eventTap.onDoubleClick = { [weak self] location, flags, pbCount in
            self?.handleDoubleClick(at: location, flags: flags, pbCountAtClick: pbCount)
        }
        eventTap.onDragSelect = { [weak self] location, pbCountAtDown in
            self?.handleDragSelect(at: location, pbCountAtDown: pbCountAtDown)
        }
        eventTap.onTripleClick = { [weak self] in
            self?.pendingOpen?.cancel()
            self?.pendingOpen = nil
        }
        if !eventTap.start() {
            axProblem = true
            updateBadge()
        }
    }

    // MARK: The flow

    /// The modifier each trigger mode requires with the double-click.
    static let triggerModifiers: [(key: String, label: String, flag: CGEventFlags?)] = [
        ("none", "Double-Click", nil),
        ("option", "⌥ + Double-Click", .maskAlternate),
        ("command", "⌘ + Double-Click", .maskCommand),
        ("control", "⌃ + Double-Click", .maskControl),
    ]

    private func handleDoubleClick(at location: CGPoint, flags: CGEventFlags, pbCountAtClick: Int) {
        guard config.enabled else { return }
        guard !panel.isVisible, !chatPanel.isVisible else { return }  // one surface at a time
        // Trigger mode: users who don't want every double-click to define can
        // require a held modifier (menu: Trigger submenu).
        if let required = Self.triggerModifiers.first(where: { $0.key == config.triggerModifier })?.flag,
           !flags.contains(required) { return }
        let alt = flags.contains(.maskAlternate)

        NSLog("double-click at (%.0f, %.0f) alt=%d", location.x, location.y, alt ? 1 : 0)
        let allowClipboard = config.clipboardFallback
        let excluded = config.excludedApps
        // Extraction starts NOW; presenting waits out the triple-click window
        // below, so a select-paragraph doesn't flash a spurious definition.
        let clickTime = DispatchTime.now()
        extractQueue.async { [weak self] in
            let extraction = Extractor.forDoubleClick(at: location,
                                                      pbCountAtClick: pbCountAtClick,
                                                      allowClipboard: allowClipboard,
                                                      excludedApps: excluded)
            // Extracted CONTENT is only logged with --debug; the unified log
            // is readable by any process (privacy ship-blocker).
            NSLog("extraction: app=%@ ladder=%@ hasText=%d",
                  extraction.app, extraction.ladder, extraction.hasText ? 1 : 0)
            Log.d("extraction word=%@", extraction.word ?? "∅")
            guard let self, extraction.hasText, let word = extraction.word else { return }
            if self.config.excludedApps.contains(extraction.app) { return }
            DispatchQueue.main.async {
                // Default: double-click just defines. The pill interposes only
                // when configured; ⌥ always bypasses it.
                let work = DispatchWorkItem {
                    if self.config.usePill && !alt {
                        self.pill.show(word: word, atCG: location, timeout: self.config.pillTimeout) {
                            self.openTangent(extraction, word: word, at: location)
                        }
                    } else {
                        self.openTangent(extraction, word: word, at: location)
                    }
                }
                self.pendingOpen?.cancel()
                self.pendingOpen = work
                // Extraction usually outlasts the window, so this rarely adds
                // real latency — it only refuses to present before it closes.
                let tripleWindow = clickTime + .milliseconds(280)
                DispatchQueue.main.asyncAfter(deadline: max(tripleWindow, .now()), execute: work)
            }
        }
    }

    // MARK: Selection chat (flow B)

    private func handleDragSelect(at location: CGPoint, pbCountAtDown: Int) {
        NSLog("drag-up at (%.0f, %.0f)", location.x, location.y)
        guard config.enabled, config.chatOnSelect else { return }
        guard !panel.isVisible, !chatPanel.isVisible else {
            NSLog("drag-select: blocked — a surface is open (tangent=%d chat=%d)",
                  panel.isVisible ? 1 : 0, chatPanel.isVisible ? 1 : 0)
            return
        }
        extractQueue.async { [weak self] in
            guard let self else { return }
            guard let grab = Extractor.forSelection(pbCountAtDragStart: pbCountAtDown) else {
                return  // forSelection logged why
            }
            if self.config.excludedApps.contains(grab.app) { return }
            NSLog("drag-select: app=%@ selection=%d chars", grab.app, grab.selection.count)
            DispatchQueue.main.async {
                let title = Excerpt.title(of: grab.selection)
                self.pill.show(label: "⌁ ask about “\(title)”", atCG: location,
                               timeout: self.config.pillTimeout) {
                    self.openChat(selection: grab.selection, source: grab.source,
                                  app: grab.app, at: location)
                }
            }
        }
    }

    private func openChat(selection: String, source: String?, app: String, at location: CGPoint) {
        chatExcerpt = Excerpt.focus(source: source, selection: selection)
        chatHistory = []
        chatPanel.present(title: Excerpt.title(of: selection), excerpt: chatExcerpt,
                          sourceApp: app, model: config.resolvedChatModel, atCG: location,
                          onSend: { [weak self] question in
                              self?.sendChatTurn(question)
                          },
                          onClose: { [weak self] in
                              self?.engine.cancel()
                          })
    }

    private func sendChatTurn(_ question: String) {
        chatHistory.append(.init(role: .user, content: question))
        chatPanel.appendUser(question)
        chatPanel.setStatus("thinking…")
        var reply = ""
        engine.streamChat(excerpt: chatExcerpt, history: chatHistory, config: config,
                          onChunk: { [weak self] chunk in
                              reply += chunk
                              self?.chatPanel.appendAssistant(chunk)
                          },
                          onStatus: { [weak self] status in
                              self?.chatPanel.setStatus(status)
                              // The configured local server just failed; adopt
                              // whichever local server is alive for next time.
                              self?.refreshLocalModels(autoSelect: true)
                          },
                          onDone: { [weak self] status in
                              guard let self else { return }
                              if !reply.isEmpty {
                                  self.chatHistory.append(.init(role: .assistant, content: reply))
                                  self.chatPanel.appendAssistant("\n")
                              }
                              self.chatPanel.setStatus(status)
                          })
    }

    private func openTangent(_ extraction: Extraction, word: String, at location: CGPoint) {
        panel.present(word: word, sourceApp: extraction.app, model: config.tangentModel,
                      atCG: location) { [weak self] in
            self?.engine.cancel()
        }
        let context = extraction.context ?? word
        NSLog("openTangent: model=%@ context=%d chars", config.tangentModel, context.count)
        Log.d("openTangent word=%@", word)
        panel.setStatus("thinking… (\(extraction.ladder))")
        var gotFirstChunk = false
        engine.streamTangent(word: word, context: context, config: config,
                             onChunk: { [weak self] chunk in
                                 if !gotFirstChunk, !chunk.isEmpty {
                                     gotFirstChunk = true
                                     NSLog("first chunk received")
                                 }
                                 self?.panel.append(chunk)
                             },
                             onStatus: { [weak self] status in
                                 self?.panel.setStatus(status)
                                 // The configured local server just failed; adopt
                                 // whichever local server is alive for next time.
                                 self?.refreshLocalModels(autoSelect: true)
                             },
                             onDone: { [weak self] status in
                                 NSLog("stream done: %@", status)
                                 self?.panel.setStatus("\(status) — click outside to dismiss")
                             })
    }

    /// ⌘V/⌘C/⌘X/⌘A in text fields are routed through the Edit menu's key
    /// equivalents — a menu-bar-less accessory app silently drops them, which
    /// breaks both manual paste and dictation tools that insert by simulating
    /// ⌘V (Wispr Flow). A programmatic main menu restores the routing.
    private func setupEditMenu() {
        let main = NSMenu()
        let editHolder = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editHolder.submenu = edit
        main.addItem(editHolder)
        NSApp.mainMenu = main
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusIcon.make()
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = config.enabled ? .on : .off
        menu.addItem(toggle)

        let pillToggle = NSMenuItem(title: "Ask First (pill)", action: #selector(togglePill(_:)), keyEquivalent: "")
        pillToggle.target = self
        pillToggle.state = config.usePill ? .on : .off
        menu.addItem(pillToggle)

        let chatToggle = NSMenuItem(title: "Chat on Selection", action: #selector(toggleChat(_:)), keyEquivalent: "")
        chatToggle.target = self
        chatToggle.state = config.chatOnSelect ? .on : .off
        menu.addItem(chatToggle)

        // Trigger mode: bare double-click or modifier + double-click.
        let trig = NSMenu()
        for opt in Self.triggerModifiers {
            let item = NSMenuItem(title: opt.label, action: #selector(selectTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = opt.key
            item.state = (opt.key == config.triggerModifier) ? .on : .off
            trig.addItem(item)
        }
        triggerItem.submenu = trig
        menu.addItem(triggerItem)

        loginItem.action = #selector(toggleLogin(_:))
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())

        modelItem.submenu = NSMenu()
        menu.addItem(modelItem)
        chatModelItem.submenu = NSMenu()
        menu.addItem(chatModelItem)
        noModelItem.action = #selector(openOllamaSite)
        noModelItem.target = self
        noModelItem.isHidden = true
        menu.addItem(noModelItem)
        rebuildModelMenu()
        menu.addItem(.separator())

        excludeItem.action = #selector(excludeFrontmost(_:))
        excludeItem.target = self
        menu.addItem(excludeItem)
        excludedListItem.submenu = NSMenu()
        menu.addItem(excludedListItem)
        rebuildExcludedMenu()
        menu.addItem(.separator())

        // Dev submenu: maintenance hatches that don't belong in daily use.
        let dev = NSMenu()
        let test = NSMenuItem(title: "Test Panel", action: #selector(testPanel), keyEquivalent: "")
        test.target = self
        dev.addItem(test)
        let openCfg = NSMenuItem(title: "Open Config File", action: #selector(devOpenConfig), keyEquivalent: "")
        openCfg.target = self
        dev.addItem(openCfg)
        let resetAX = NSMenuItem(title: "Reset Accessibility Permission…", action: #selector(devResetAccessibility), keyEquivalent: "")
        resetAX.target = self
        dev.addItem(resetAX)
        dev.addItem(.separator())
        let uninstall = NSMenuItem(title: "Uninstall TangentBar…", action: #selector(devUninstall), keyEquivalent: "")
        uninstall.target = self
        dev.addItem(uninstall)
        let devItem = NSMenuItem(title: "Dev", action: nil, keyEquivalent: "")
        devItem.submenu = dev
        menu.addItem(devItem)
        menu.addItem(.separator())

        let version = NSMenuItem(title: "TangentBar \(Self.appVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let quit = NSMenuItem(title: "Quit TangentBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self  // refresh the model list each time the menu opens
        item.menu = menu
        statusItem = item
    }

    /// Version baked into the bundle's Info.plist by scripts/build-app.sh;
    /// a bare `swift build` binary has no bundle dictionary → "dev".
    static let appVersion: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "v" + $0 } ?? "dev"

    /// Text badge next to the logo — "!" while a permission/tap problem stands
    /// or no model is reachable; the menu explains which.
    private func updateBadge() {
        let s = (axProblem || noModels) ? "!" : ""
        statusItem?.button?.title = s
        statusItem?.button?.imagePosition = s.isEmpty ? .imageOnly : .imageLeft
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Captured before our menu opens: status-item clicks don't activate
        // an accessory app, so the reading app is still frontmost.
        let front = NSWorkspace.shared.frontmostApplication?.localizedName
        frontmostForExclude = (front == nil || front == "TangentBar") ? nil : front
        excludeItem.title = frontmostForExclude.map { "Exclude “\($0)”" } ?? "Exclude This App"
        excludeItem.isHidden = frontmostForExclude == nil
            || config.excludedApps.contains(frontmostForExclude!)
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        refreshLocalModels(autoSelect: false)
    }

    @objc private func selectTrigger(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        config.triggerModifier = key
        config.save()
        for item in triggerItem.submenu?.items ?? [] {
            item.state = (item.representedObject as? String == key) ? .on : .off
        }
    }

    /// Launch at Login via SMAppService — only effective from the .app bundle;
    /// a bare binary throws, which we surface in the log and leave the state off.
    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("launch-at-login toggle failed: %@", error.localizedDescription)
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openOllamaSite() {
        NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
    }

    // MARK: Excluded apps

    @objc private func excludeFrontmost(_ sender: NSMenuItem) {
        guard let app = frontmostForExclude, !config.excludedApps.contains(app) else { return }
        config.excludedApps.append(app)
        config.save()
        rebuildExcludedMenu()
    }

    @objc private func removeExcluded(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? String else { return }
        config.excludedApps.removeAll { $0 == app }
        config.save()
        rebuildExcludedMenu()
    }

    private func rebuildExcludedMenu() {
        excludedListItem.isHidden = config.excludedApps.isEmpty
        let submenu = excludedListItem.submenu ?? NSMenu()
        submenu.removeAllItems()
        for app in config.excludedApps {
            let item = NSMenuItem(title: "Include “\(app)” again", action: #selector(removeExcluded(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            submenu.addItem(item)
        }
        excludedListItem.submenu = submenu
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        config.enabled.toggle()
        sender.state = config.enabled ? .on : .off
        config.save()
    }

    @objc private func togglePill(_ sender: NSMenuItem) {
        config.usePill.toggle()
        sender.state = config.usePill ? .on : .off
        config.save()
    }

    @objc private func toggleChat(_ sender: NSMenuItem) {
        config.chatOnSelect.toggle()
        sender.state = config.chatOnSelect ? .on : .off
        config.save()
    }

    // MARK: Model selection

    /// Probe the local servers. With `autoSelect`, adopt the best available
    /// model when the configured one isn't served anymore, then prewarm.
    private func refreshLocalModels(autoSelect: Bool) {
        ModelDiscovery.discover(including: config.localBaseURL) { [weak self] models in
            guard let self else { return }
            self.localModels = models
            // First-run reality for strangers: no server, no models. Badge the
            // status item and surface the "install Ollama" path in the menu.
            // Claude entries don't count — the hint is about LOCAL models.
            let hasLocal = models.contains { !$0.isClaude }
            self.noModels = !hasLocal
            self.noModelItem.isHidden = hasLocal
            self.noModelItem.title = Engine.claudePath != nil
                ? "No local models (claude fallback active) — Install Ollama…"
                : "No local models — Install Ollama…"
            self.updateBadge()
            let before = (self.config.tangentModel, self.config.localBaseURL)
            if let current = models.first(where: { $0.id == self.config.tangentModel }) {
                // Model still served — track its base URL in case it moved servers.
                if self.config.localBaseURL != current.baseURL {
                    self.config.localBaseURL = current.baseURL
                    self.config.save()
                }
            } else if autoSelect, let best = models.first(where: { !$0.isClaude }) ?? models.first {
                // Local-first (D7): a claude entry is only auto-adopted when
                // there is no local model at all. Explicit picks always stick.
                self.config.tangentModel = best.id
                self.config.localBaseURL = best.baseURL
                self.config.save()
            }
            // A chat model that's no longer served falls back to "same as define".
            if !models.isEmpty, !self.config.chatModel.isEmpty,
               !models.contains(where: { $0.id == self.config.chatModel }) {
                self.config.chatModel = ""
                self.config.chatLocalBaseURL = ""
                self.config.save()
            }
            self.rebuildModelMenu()
            // Launch already prewarmed the saved model; only re-warm on change.
            if autoSelect, (self.config.tangentModel, self.config.localBaseURL) != before {
                self.engine.prewarm(config: self.config)
            }
        }
    }

    private func rebuildModelMenu() {
        modelItem.title = "Define Model: \(config.tangentModel)"
        chatModelItem.title = "Chat Model: \(config.chatModel.isEmpty ? "same as define" : config.chatModel)"

        let defineMenu = modelItem.submenu ?? NSMenu()
        defineMenu.removeAllItems()
        if localModels.isEmpty {
            let none = NSMenuItem(title: "No local models found (claude fallback)",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            defineMenu.addItem(none)
        }
        for model in localModels {
            let item = NSMenuItem(title: "\(model.id) — \(model.server)",
                                  action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model
            item.state = (model.id == config.tangentModel && model.baseURL == config.localBaseURL) ? .on : .off
            defineMenu.addItem(item)
        }
        modelItem.submenu = defineMenu

        let chatMenu = chatModelItem.submenu ?? NSMenu()
        chatMenu.removeAllItems()
        let same = NSMenuItem(title: "Same as Define", action: #selector(selectChatModel(_:)), keyEquivalent: "")
        same.target = self
        same.state = config.chatModel.isEmpty ? .on : .off
        chatMenu.addItem(same)
        for model in localModels {
            let item = NSMenuItem(title: "\(model.id) — \(model.server)",
                                  action: #selector(selectChatModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model
            item.state = (model.id == config.chatModel && model.baseURL == config.chatLocalBaseURL) ? .on : .off
            chatMenu.addItem(item)
        }
        chatModelItem.submenu = chatMenu
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? LocalModel else { return }
        config.tangentModel = model.id
        config.localBaseURL = model.baseURL
        config.save()
        rebuildModelMenu()
        engine.prewarm(config: config)  // keep the newly chosen model hot
    }

    @objc private func selectChatModel(_ sender: NSMenuItem) {
        if let model = sender.representedObject as? LocalModel {
            config.chatModel = model.id
            config.chatLocalBaseURL = model.baseURL
        } else {
            // "Same as Define"
            config.chatModel = ""
            config.chatLocalBaseURL = ""
        }
        config.save()
        rebuildModelMenu()
    }

    @objc private func testPanel() {
        let mouse = CGEvent(source: nil)?.location ?? CGPoint(x: 400, y: 300)
        panel.present(word: "tangent", sourceApp: "TangentBar", model: config.tangentModel, atCG: mouse) {}
        panel.setStatus("canned demo — click outside to dismiss")
        panel.append("A line that touches a curve at a single point without crossing it; figuratively, a sudden divergence from the main subject — exactly the kind this app exists to indulge.")
    }

    // MARK: Dev menu

    @objc private func devOpenConfig() {
        if !FileManager.default.fileExists(atPath: Config.url.path) { config.save() }
        NSWorkspace.shared.open(Config.url)
    }

    @objc private func devResetAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Reset Accessibility permission?"
        alert.informativeText = "Clears TangentBar's entry in Privacy & Security so macOS can re-prompt cleanly. TangentBar quits afterwards — relaunch it to grant again."
        alert.addButton(withTitle: "Reset & Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", "com.whorl.TangentBar"]
        try? p.run()
        p.waitUntilExit()
        NSApp.terminate(nil)
    }

    @objc private func devUninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Uninstall TangentBar?"
        alert.informativeText = "Removes the app from /Applications, deletes its config, and clears its macOS permission entries. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let bundled = Bundle.main.url(forResource: "uninstall", withExtension: "sh") else {
            let oops = NSAlert()
            oops.messageText = "No uninstall script in this build"
            oops.informativeText = "Bare `swift build` binaries don't bundle uninstall.sh — run it from the repo instead."
            oops.runModal()
            return
        }
        // The script deletes the .app it shipped in (and kills this process),
        // so it must run from OUTSIDE the bundle: copy to tmp, run detached.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tangentbar-uninstall.sh")
        try? FileManager.default.removeItem(at: tmp)
        do {
            try FileManager.default.copyItem(at: bundled, to: tmp)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [tmp.path]
            try p.run()
        } catch {
            NSLog("uninstall launch failed: %@", "\(error)")
        }
    }

    // MARK: Diagnostics (no interaction, auto-exit)

    /// `--models`: print what discovery sees and which model would be the
    /// default, then exit. Exercises the same path the menu uses.
    private func runModelProbe() {
        ModelDiscovery.discover(including: config.localBaseURL) { models in
            for model in models {
                print("\(model.id) — \(model.server) (\(model.baseURL))")
            }
            let pick = models.first(where: { $0.id == Config.load().tangentModel }) ?? models.first
            print(models.isEmpty ? "no local models — claude fallback"
                                 : "default: \(pick!.id) — \(pick!.server)")
            exit(0)
        }
    }

    /// `--tangent <word>`: run the exact engine path a panel uses, printing
    /// chunks to stdout. Isolates engine/stream bugs from UI bugs.
    private func runTangentProbe(word: String) {
        print("model: \(config.tangentModel) @ \(config.localBaseURL)")
        engine.streamTangent(word: word,
                             context: "The conversation went off on a \(word) about medieval siege engines.",
                             config: config,
                             onChunk: { print($0, terminator: ""); fflush(stdout) },
                             onDone: { status in
                                 print("\n[\(status)]")
                                 exit(0)
                             })
    }

    /// `--chat`: present the selection chat with a canned excerpt, auto-send a
    /// question through the real engine path, then exit. UI + engine composed.
    private func runChatProbe() {
        let excerpt = "The tangent line to a circle touches it at exactly one point, called the point of tangency; the radius drawn to that point is perpendicular to the line."
        let center = CGPoint(x: (NSScreen.main?.frame.width ?? 1200) / 2,
                             y: (NSScreen.main?.frame.height ?? 800) / 2)
        openChat(selection: excerpt, source: nil, app: "TangentBar", at: center)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            NSLog("chatprobe: isActive=%d keyWindow=%d frontmost=%@",
                  NSApp.isActive ? 1 : 0,
                  NSApp.keyWindow != nil ? 1 : 0,
                  NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")
            // What dictation tools see: the system-wide AX focused element.
            let focused = Extractor.extractFocused()
            NSLog("chatprobe: systemwide AX focus → app=%@ role=%@", focused.app, focused.role)
            self?.sendChatTurn("Why perpendicular?")
        }
        // Wispr-style insertion test: pasteboard + synthetic ⌘V at ourselves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let pb = NSPasteboard.general
            let saved = pb.string(forType: .string)
            pb.clearContents()
            pb.setString("DICTATED", forType: .string)
            let src = CGEventSource(stateID: .combinedSessionState)
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
               let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) {
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.postToPid(ProcessInfo.processInfo.processIdentifier)
                up.postToPid(ProcessInfo.processInfo.processIdentifier)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                NSLog("chatprobe: after synthetic ⌘V input=\"%@\"", self?.chatPanel.inputText ?? "?")
                pb.clearContents()
                if let saved { pb.setString(saved, forType: .string) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            print("chatprobe: history turns = \(self?.chatHistory.count ?? -1)")
            exit(self?.chatHistory.count == 2 ? 0 : 1)
        }
    }

    // MARK: Self-test (no interaction, auto-exits)

    private func runSelfTest() {
        let center = CGPoint(x: (NSScreen.main?.frame.width ?? 1200) / 2,
                             y: (NSScreen.main?.frame.height ?? 800) / 2)
        panel.present(word: "selftest", sourceApp: "TangentBar", model: config.tangentModel, atCG: center) {}
        panel.setStatus("self-test — auto-closing")
        // Markdown across chunk boundaries on purpose: the renderer must heal
        // a **tag split mid-stream** on the next re-render.
        let chunks = ["Panel rendered with **bo", "ld**, *italic*, and `code` spans. ",
                      "Streaming appends work. Auto-exit in 3s."]
        for (i, chunk) in chunks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) { [weak self] in
                self?.panel.append(chunk)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("selftest: panel presented, chunks appended, exiting 0")
            NSApp.terminate(nil)
        }
    }
}
