// Wires the four layers: sensor → extraction → surfaces → engine.
// One controller, one flow: double-click → ladder → pill → panel → stream.

import AppKit

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()
    private let eventTap = EventTap()
    private let pill = Pill()
    private let panel = TangentPanel()
    private let engine = Engine()
    private var statusItem: NSStatusItem?
    private let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
    private var localModels: [LocalModel] = []
    private let extractQueue = DispatchQueue(label: "tangent.extract", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        config.save()  // materialize defaults on first run

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

        if CommandLine.arguments.contains("--selftest") {
            runSelfTest()
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
            setStatusTitle("⌁!")
            // Poll until granted, then arm. (Real onboarding flow replaces this.)
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.setStatusTitle("⌁")
                self?.armTap()
            }
        }
        return trusted
    }

    private func armTap() {
        eventTap.onDoubleClick = { [weak self] location, alt, pbCount in
            self?.handleDoubleClick(at: location, alt: alt, pbCountAtClick: pbCount)
        }
        if !eventTap.start() {
            setStatusTitle("⌁!")
        }
    }

    // MARK: The flow

    private func handleDoubleClick(at location: CGPoint, alt: Bool, pbCountAtClick: Int) {
        guard config.enabled else { return }
        guard !panel.isVisible else { return }  // a tangent is already open

        NSLog("double-click at (%.0f, %.0f) alt=%d", location.x, location.y, alt ? 1 : 0)
        let allowClipboard = config.clipboardFallback
        extractQueue.async { [weak self] in
            let extraction = Extractor.forDoubleClick(at: location,
                                                      pbCountAtClick: pbCountAtClick,
                                                      allowClipboard: allowClipboard)
            NSLog("extraction: app=%@ ladder=%@ word=%@ hasText=%d",
                  extraction.app, extraction.ladder, extraction.word ?? "∅",
                  extraction.hasText ? 1 : 0)
            guard let self, extraction.hasText, let word = extraction.word else { return }
            if self.config.excludedApps.contains(extraction.app) { return }
            DispatchQueue.main.async {
                // Default: double-click just defines. The pill interposes only
                // when configured; ⌥ always bypasses it.
                if self.config.usePill && !alt {
                    self.pill.show(word: word, atCG: location, timeout: self.config.pillTimeout) {
                        self.openTangent(extraction, word: word, at: location)
                    }
                } else {
                    self.openTangent(extraction, word: word, at: location)
                }
            }
        }
    }

    private func openTangent(_ extraction: Extraction, word: String, at location: CGPoint) {
        panel.present(word: word, sourceApp: extraction.app, model: config.tangentModel,
                      atCG: location) { [weak self] in
            self?.engine.cancel()
        }
        let context = extraction.context ?? word
        NSLog("openTangent: word=%@ model=%@ context=%d chars", word, config.tangentModel, context.count)
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
                             onDone: { [weak self] status in
                                 NSLog("stream done: %@", status)
                                 self?.panel.setStatus("\(status) — click outside to dismiss")
                             })
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "⌁"
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = config.enabled ? .on : .off
        menu.addItem(toggle)

        let pillToggle = NSMenuItem(title: "Ask First (pill)", action: #selector(togglePill(_:)), keyEquivalent: "")
        pillToggle.target = self
        pillToggle.state = config.usePill ? .on : .off
        menu.addItem(pillToggle)

        modelItem.submenu = NSMenu()
        menu.addItem(modelItem)
        rebuildModelMenu()
        menu.addItem(.separator())

        let test = NSMenuItem(title: "Test Panel", action: #selector(testPanel), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit TangentBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        menu.delegate = self  // refresh the model list each time the menu opens
        item.menu = menu
        statusItem = item
    }

    private func setStatusTitle(_ s: String) {
        statusItem?.button?.title = s
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLocalModels(autoSelect: false)
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

    // MARK: Model selection

    /// Probe the local servers. With `autoSelect`, adopt the best available
    /// model when the configured one isn't served anymore, then prewarm.
    private func refreshLocalModels(autoSelect: Bool) {
        ModelDiscovery.discover(including: config.localBaseURL) { [weak self] models in
            guard let self else { return }
            self.localModels = models
            let before = (self.config.tangentModel, self.config.localBaseURL)
            if let current = models.first(where: { $0.id == self.config.tangentModel }) {
                // Model still served — track its base URL in case it moved servers.
                if self.config.localBaseURL != current.baseURL {
                    self.config.localBaseURL = current.baseURL
                    self.config.save()
                }
            } else if autoSelect, let best = models.first {
                self.config.tangentModel = best.id
                self.config.localBaseURL = best.baseURL
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
        modelItem.title = "Model: \(config.tangentModel)"
        let submenu = modelItem.submenu ?? NSMenu()
        submenu.removeAllItems()
        if localModels.isEmpty {
            let none = NSMenuItem(title: "No local models found (claude fallback)",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        for model in localModels {
            let item = NSMenuItem(title: "\(model.id) — \(model.server)",
                                  action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model
            item.state = (model.id == config.tangentModel && model.baseURL == config.localBaseURL) ? .on : .off
            submenu.addItem(item)
        }
        modelItem.submenu = submenu
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? LocalModel else { return }
        config.tangentModel = model.id
        config.localBaseURL = model.baseURL
        config.save()
        rebuildModelMenu()
        engine.prewarm(config: config)  // keep the newly chosen model hot
    }

    @objc private func testPanel() {
        let mouse = CGEvent(source: nil)?.location ?? CGPoint(x: 400, y: 300)
        panel.present(word: "tangent", sourceApp: "TangentBar", model: config.tangentModel, atCG: mouse) {}
        panel.setStatus("canned demo — click outside to dismiss")
        panel.append("A line that touches a curve at a single point without crossing it; figuratively, a sudden divergence from the main subject — exactly the kind this app exists to indulge.")
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

    // MARK: Self-test (no interaction, auto-exits)

    private func runSelfTest() {
        let center = CGPoint(x: (NSScreen.main?.frame.width ?? 1200) / 2,
                             y: (NSScreen.main?.frame.height ?? 800) / 2)
        panel.present(word: "selftest", sourceApp: "TangentBar", model: config.tangentModel, atCG: center) {}
        panel.setStatus("self-test — auto-closing")
        let chunks = ["Panel rendered. ", "Streaming appends work. ", "Auto-exit in 3s."]
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
