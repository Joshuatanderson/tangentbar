// The pill affordance: a tiny non-activating capsule that appears near the
// cursor after a double-click that yielded text. Click it → tangent panel;
// ignore it → it fades on its own. Never takes focus.

import AppKit

final class Pill: NSObject {
    private var panel: NSPanel?
    private var timer: Timer?
    private var onClick: (() -> Void)?

    /// Warm-paper palette carried from v1 (ui/theme.rs INK_CSS).
    static let paper = NSColor(srgbRed: 0.980, green: 0.965, blue: 0.925, alpha: 1)  // #faf6ec
    static let ink   = NSColor(srgbRed: 0.114, green: 0.141, blue: 0.200, alpha: 1)  // #1d2433
    static let accent = NSColor(srgbRed: 0.227, green: 0.302, blue: 0.561, alpha: 1) // #3a4d8f

    func show(word: String, atCG cgPoint: CGPoint, timeout: TimeInterval, onClick: @escaping () -> Void) {
        dismiss()
        self.onClick = onClick

        // Read as a button, not as output: "define" is the affordance.
        let label = word.count > 24 ? String(word.prefix(24)) + "…" : word
        let field = NSTextField(labelWithString: "⌁ define “\(label)”")
        field.font = NSFont(name: "Iowan Old Style", size: 12) ?? .systemFont(ofSize: 12, weight: .medium)
        field.textColor = Pill.ink
        field.sizeToFit()

        let pad: CGFloat = 10
        let size = NSSize(width: field.frame.width + pad * 2, height: field.frame.height + 10)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = Pill.paper.cgColor
        content.layer?.cornerRadius = size.height / 2
        content.layer?.borderWidth = 1.5
        content.layer?.borderColor = Pill.accent.cgColor
        field.frame.origin = NSPoint(x: pad, y: 5)
        content.addSubview(field)
        content.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
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

        // CG events are top-left origin; Cocoa windows are bottom-left origin.
        let cocoa = Coords.cocoaPoint(fromCG: cgPoint)
        panel.setFrameOrigin(NSPoint(x: cocoa.x + 12, y: cocoa.y + 16))
        panel.orderFrontRegardless()
        self.panel = panel

        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            NSLog("pill timed out unclicked")
            self?.dismiss()
        }
    }

    @objc private func clicked() {
        NSLog("pill clicked")
        let action = onClick
        dismiss()
        action?()
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        onClick = nil
    }
}

enum Coords {
    /// Convert CGEvent/AX global coords (top-left origin, y down) to Cocoa
    /// screen coords (bottom-left of the primary screen, y up).
    static func cocoaPoint(fromCG p: CGPoint) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSPoint(x: p.x, y: primaryHeight - p.y)
    }
}
