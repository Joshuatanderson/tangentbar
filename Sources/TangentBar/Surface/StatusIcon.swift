// The Tangent mark for the status item: a ring and its tangent line, touching
// at one point (assets/logo.svg, drawn natively so it stays crisp and renders
// as a template — auto-adapts to light/dark menu bars).

import AppKit

enum StatusIcon {
    /// logo.svg geometry (viewBox 64, y-down): circle c(25.4, 36.8) r 16.2,
    /// line (13.5, 9.4) → (55.2, 36.9). Stroke scaled up from the SVG's 2.8
    /// for menu-bar legibility at 18 pt.
    static func make(pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { rect in
            let s = rect.width / 64.0
            let stroke: CGFloat = 5.5 * s
            NSColor.black.setStroke()

            let circle = NSBezierPath(ovalIn: NSRect(x: (25.4 - 16.2) * s,
                                                     y: (64 - 36.8 - 16.2) * s,
                                                     width: 32.4 * s, height: 32.4 * s))
            circle.lineWidth = stroke
            circle.stroke()

            let line = NSBezierPath()
            line.move(to: NSPoint(x: 13.5 * s, y: (64 - 9.4) * s))
            line.line(to: NSPoint(x: 55.2 * s, y: (64 - 36.9) * s))
            line.lineWidth = stroke
            line.lineCapStyle = .round
            line.stroke()
            return true
        }
        image.isTemplate = true  // menu bar recolors it for light/dark/active
        return image
    }
}
