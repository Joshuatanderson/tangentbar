// The selection chat (flow B, v1 "explore"): highlight text → a small card
// seeded with the excerpt, streaming follow-ups through the configured model.
// The app genuinely ACTIVATES while the chat is open: dictation tools (Wispr
// Flow) resolve their target via the system AX focused element, which only
// points at our input when we're the active app. Focus is handed back to the
// source app on dismiss. Closes on Esc, ✕, or a click outside.

import AppKit

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ChatPanel: NSObject, NSTextFieldDelegate {
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var statusField: NSTextField?
    private var input: NSTextField?
    private var onSend: ((String) -> Void)?
    private var onClose: (() -> Void)?
    private var clickAwayMonitor: Any?
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { panel?.isVisible ?? false }

    private static let bodyFont = NSFont(name: "Charter", size: 13.5) ?? .systemFont(ofSize: 13.5)

    func present(title: String, excerpt: String, sourceApp: String, model: String,
                 atCG cgPoint: CGPoint,
                 onSend: @escaping (String) -> Void,
                 onClose: @escaping () -> Void) {
        dismiss()
        self.onSend = onSend
        self.onClose = onClose

        let width: CGFloat = 420
        let height: CGFloat = 340

        let titleField = NSTextField(labelWithString: title)
        titleField.font = NSFont(name: "Iowan Old Style", size: 16) ?? .systemFont(ofSize: 16, weight: .semibold)
        titleField.textColor = Pill.ink
        titleField.lineBreakMode = .byTruncatingTail

        let caption = NSTextField(labelWithString: "from \(sourceApp) · \(model)")
        caption.font = .systemFont(ofSize: 10.5)
        caption.textColor = NSColor(srgbRed: 0.43, green: 0.45, blue: 0.50, alpha: 1)

        let close = NSButton(title: "✕", target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.font = .systemFont(ofSize: 13)
        close.contentTintColor = NSColor(srgbRed: 0.43, green: 0.45, blue: 0.50, alpha: 1)

        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = Self.bodyFont
        text.textColor = Pill.ink
        text.textContainerInset = NSSize(width: 0, height: 4)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let inputField = NSTextField(string: "")
        inputField.placeholderString = "ask about the excerpt…"
        inputField.font = .systemFont(ofSize: 13)
        inputField.textColor = Pill.ink
        inputField.backgroundColor = NSColor.white.withAlphaComponent(0.7)
        inputField.isBezeled = true
        inputField.bezelStyle = .roundedBezel
        inputField.focusRingType = .none
        inputField.delegate = self
        inputField.target = self
        inputField.action = #selector(sendClicked)

        let status = NSTextField(labelWithString: "excerpt captured — ask away")
        status.font = .systemFont(ofSize: 10.5)
        status.textColor = Pill.accent

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = Pill.paper.cgColor
        content.layer?.cornerRadius = 14
        content.layer?.borderWidth = 1.5
        content.layer?.borderColor = Pill.accent.withAlphaComponent(0.55).cgColor

        let pad: CGFloat = 14
        titleField.frame = NSRect(x: pad, y: height - 32, width: width - pad * 2 - 24, height: 20)
        close.frame = NSRect(x: width - pad - 18, y: height - 32, width: 18, height: 20)
        caption.frame = NSRect(x: pad, y: height - 48, width: width - pad * 2, height: 14)
        scroll.frame = NSRect(x: pad, y: 58, width: width - pad * 2, height: height - 114)
        inputField.frame = NSRect(x: pad, y: 28, width: width - pad * 2, height: 24)
        status.frame = NSRect(x: pad, y: 8, width: width - pad * 2, height: 14)
        content.addSubview(titleField)
        content.addSubview(close)
        content.addSubview(caption)
        content.addSubview(scroll)
        content.addSubview(inputField)
        content.addSubview(status)

        // Deliberately NOT .nonactivatingPanel: that style forbids clicks from
        // activating the app, and dictation tools need the app active before
        // the system AX focus chain reaches our input. A click into the field
        // must be able to activate us.
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                 styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.contentView = content

        var origin = Coords.cocoaPoint(fromCG: cgPoint)
        origin.x += 12
        origin.y -= height + 12
        if let screen = NSScreen.screens.first(where: { NSPointInRect(Coords.cocoaPoint(fromCG: cgPoint), $0.frame) }) ?? NSScreen.main {
            origin.x = min(max(screen.visibleFrame.minX + 8, origin.x), screen.visibleFrame.maxX - width - 8)
            origin.y = min(max(screen.visibleFrame.minY + 8, origin.y), screen.visibleFrame.maxY - height - 8)
        }
        panel.setFrameOrigin(origin)

        // Activate for real: dictation (Wispr Flow) targets the system-wide
        // AX focused element, which requires our app to be active before it
        // sees the input as a text field. We restore the source app on dismiss.
        // Cooperative activation (macOS 14+) ignores NSApp.activate from a
        // background app — the NSRunningApplication path still forces it.
        previousApp = NSWorkspace.shared.frontmostApplication
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        self.textView = text
        self.statusField = status
        self.input = inputField

        // Show the grounding up front, muted, so the user sees what the model sees.
        appendQuote(excerpt)
        panel.makeFirstResponder(inputField)

        // Click-away dismissal: global monitors see clicks in OTHER apps —
        // any click outside while we're active lands there.
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    // MARK: Transcript

    private func appendQuote(_ s: String) {
        append("\(s)\n", color: NSColor(srgbRed: 0.43, green: 0.45, blue: 0.50, alpha: 1),
               font: NSFont(name: "Charter-Italic", size: 12.5) ?? Self.bodyFont)
    }

    func appendUser(_ s: String) {
        append("\nyou — \(s)\n", color: Pill.accent,
               font: .systemFont(ofSize: 12.5, weight: .semibold))
    }

    func appendAssistant(_ chunk: String) {
        append(chunk, color: Pill.ink, font: Self.bodyFont)
    }

    private func append(_ s: String, color: NSColor, font: NSFont) {
        guard let textView else { return }
        textView.textStorage?.append(NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color,
        ]))
        textView.scrollToEndOfDocument(nil)
    }

    func setStatus(_ s: String) {
        statusField?.stringValue = s
    }

    // MARK: Input

    @objc private func sendClicked() {
        guard let input, !input.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let question = input.stringValue
        input.stringValue = ""
        onSend?(question)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }

    @objc private func closeClicked() { dismiss() }

    func dismiss() {
        if let monitor = clickAwayMonitor { NSEvent.removeMonitor(monitor) }
        clickAwayMonitor = nil
        let wasVisible = panel?.isVisible ?? false
        panel?.orderOut(nil)
        panel = nil
        textView = nil
        statusField = nil
        input = nil
        onSend = nil
        // Hand focus back to the app the selection came from.
        if wasVisible, previousApp?.isTerminated == false {
            previousApp?.activate()
        }
        previousApp = nil
        let handler = onClose
        onClose = nil
        handler?()
    }
}
