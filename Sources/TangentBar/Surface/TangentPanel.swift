// The tangent panel: a floating, non-activating card at the cursor that
// streams the definition. Focus never leaves the app being read. Click
// anywhere outside to dismiss (v1 semantics: tangents are disposable).

import AppKit

final class TangentPanel {
    private var panel: NSPanel?
    private var textView: NSTextView?
    private var statusField: NSTextField?
    private var clickAwayMonitor: Any?
    private(set) var onDismiss: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func present(word: String, sourceApp: String, model: String, atCG cgPoint: CGPoint,
                 onDismiss: @escaping () -> Void) {
        dismiss()
        self.onDismiss = onDismiss

        let width: CGFloat = 380
        let height: CGFloat = 240

        // Header: the word, then a muted caption naming source + model.
        let title = NSTextField(labelWithString: word)
        title.font = NSFont(name: "Iowan Old Style", size: 17) ?? .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = Pill.ink
        title.lineBreakMode = .byTruncatingTail

        let caption = NSTextField(labelWithString: "from \(sourceApp) · \(model)")
        caption.font = .systemFont(ofSize: 10.5)
        caption.textColor = NSColor(srgbRed: 0.43, green: 0.45, blue: 0.50, alpha: 1)

        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = NSFont(name: "Charter", size: 13.5) ?? .systemFont(ofSize: 13.5)
        text.textColor = Pill.ink
        text.textContainerInset = NSSize(width: 0, height: 4)

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let status = NSTextField(labelWithString: "thinking…")
        status.font = .systemFont(ofSize: 10.5)
        status.textColor = Pill.accent

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = Pill.paper.cgColor
        content.layer?.cornerRadius = 14
        content.layer?.borderWidth = 1.5
        content.layer?.borderColor = Pill.accent.withAlphaComponent(0.55).cgColor

        let pad: CGFloat = 14
        title.frame = NSRect(x: pad, y: height - 34, width: width - pad * 2, height: 22)
        caption.frame = NSRect(x: pad, y: height - 50, width: width - pad * 2, height: 14)
        scroll.frame = NSRect(x: pad, y: 28, width: width - pad * 2, height: height - 86)
        status.frame = NSRect(x: pad, y: 8, width: width - pad * 2, height: 14)
        content.addSubview(title)
        content.addSubview(caption)
        content.addSubview(scroll)
        content.addSubview(status)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.nonactivatingPanel, .borderless],
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
        // Keep it on screen.
        if let screen = NSScreen.screens.first(where: { NSPointInRect(Coords.cocoaPoint(fromCG: cgPoint), $0.frame) }) ?? NSScreen.main {
            origin.x = min(max(screen.visibleFrame.minX + 8, origin.x), screen.visibleFrame.maxX - width - 8)
            origin.y = min(max(screen.visibleFrame.minY + 8, origin.y), screen.visibleFrame.maxY - height - 8)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()

        self.panel = panel
        self.textView = text
        self.statusField = status

        // Click-away dismissal: global monitors only see events in OTHER apps,
        // which is exactly the "outside" we want (clicks on the panel are ours).
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    func append(_ chunk: String) {
        guard let textView = textView else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textView.font ?? .systemFont(ofSize: 13.5),
            .foregroundColor: Pill.ink,
        ]
        textView.textStorage?.append(NSAttributedString(string: chunk, attributes: attrs))
        textView.scrollToEndOfDocument(nil)
    }

    func setStatus(_ s: String) {
        statusField?.stringValue = s
    }

    func dismiss() {
        if let monitor = clickAwayMonitor { NSEvent.removeMonitor(monitor) }
        clickAwayMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        textView = nil
        statusField = nil
        let handler = onDismiss
        onDismiss = nil
        handler?()
    }
}
