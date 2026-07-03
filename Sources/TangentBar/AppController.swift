// Wires the four layers: sensor → extraction → surfaces → engine.
// One controller, one flow: double-click → ladder → pill → panel → stream.

import AppKit

final class AppController: NSObject, NSApplicationDelegate {
    private var config = Config.load()
    private let eventTap = EventTap()
    private let pill = Pill()
    private let panel = TangentPanel()
    private let engine = Engine()
    private var statusItem: NSStatusItem?
    private let extractQueue = DispatchQueue(label: "tangent.extract", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        config.save()  // materialize defaults on first run
        setupStatusItem()
        engine.prewarm(config: config)  // near-instant tangents depend on a hot model

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

        let allowClipboard = config.clipboardFallback
        extractQueue.async { [weak self] in
            let extraction = Extractor.forDoubleClick(at: location,
                                                      pbCountAtClick: pbCountAtClick,
                                                      allowClipboard: allowClipboard)
            guard let self, extraction.hasText, let word = extraction.word else { return }
            if self.config.excludedApps.contains(extraction.app) { return }
            DispatchQueue.main.async {
                // ⌥-double-click skips the pill and opens the tangent directly.
                if alt {
                    self.openTangent(extraction, word: word, at: location)
                } else {
                    self.pill.show(word: word, atCG: location, timeout: self.config.pillTimeout) {
                        self.openTangent(extraction, word: word, at: location)
                    }
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
        panel.setStatus("thinking… (\(extraction.ladder))")
        engine.streamTangent(word: word, context: context, config: config,
                             onChunk: { [weak self] chunk in
                                 self?.panel.append(chunk)
                             },
                             onDone: { [weak self] status in
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

        menu.addItem(NSMenuItem(title: "Model: \(config.tangentModel)", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let test = NSMenuItem(title: "Test Panel", action: #selector(testPanel), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit TangentBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    private func setStatusTitle(_ s: String) {
        statusItem?.button?.title = s
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        config.enabled.toggle()
        sender.state = config.enabled ? .on : .off
        config.save()
    }

    @objc private func testPanel() {
        let mouse = CGEvent(source: nil)?.location ?? CGPoint(x: 400, y: 300)
        panel.present(word: "tangent", sourceApp: "TangentBar", model: config.tangentModel, atCG: mouse) {}
        panel.setStatus("canned demo — click outside to dismiss")
        panel.append("A line that touches a curve at a single point without crossing it; figuratively, a sudden divergence from the main subject — exactly the kind this app exists to indulge.")
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
