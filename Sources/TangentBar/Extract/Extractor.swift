// The extraction ladder, proven by spike/axspike.swift (see spike/FINDINGS.md):
//
//   1  full AX        — RangeForPosition/SelectedTextRange + StringForRange context
//   2  selection-only — AXSelectedText without range support (word, thin context)
//   2b value-only     — the element's whole AXValue as context
//   3a copy-on-select — the app already wrote the pasteboard when the click selected
//   3b ⌘C synthesis   — postToPid → HID-tap fallback, changeCount-verified, restored
//
// Spike lessons baked in: resolve focus via the frontmost app (system-wide
// AXFocusedUIElement is flaky); never walk trees at runtime; prefer the click's
// own selection over point lookup; suppress secure fields before any rung.

import AppKit
import ApplicationServices

struct Extraction {
    var app = "?"
    var appPid: pid_t = 0
    var role = "?"
    var ladder = "none"
    var word: String?
    var context: String?

    var hasText: Bool { word != nil || context != nil }
}

enum Extractor {
    static let contextRadius = 400
    private static let systemWide = AXUIElementCreateSystemWide()

    // MARK: AX plumbing

    private static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func paramAttr(_ el: AXUIElement, _ name: String, _ param: AnyObject) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(el, name as CFString, param, &value) == .success else { return nil }
        return value
    }

    private static func cfRange(_ value: AnyObject?) -> CFRange? {
        guard let value = value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func axValue(_ range: CFRange) -> AXValue {
        var r = range
        return AXValueCreate(.cfRange, &r)!
    }

    private static func axValue(_ point: CGPoint) -> AXValue {
        var p = point
        return AXValueCreate(.cgPoint, &p)!
    }

    private static func element(at point: CGPoint) -> AXUIElement? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &el) == .success else { return nil }
        return el
    }

    /// Chromium exposes its reduced tree until assistive tech announces itself;
    /// Electron's variant is AXManualAccessibility. Lazy, per-pid, once.
    private static var nudged = Set<pid_t>()
    private static func nudgeChromium(pid: pid_t) {
        guard !nudged.contains(pid) else { return }
        nudged.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    // MARK: The ladder

    /// Full extraction for a double-click at `point`. `pbCountAtClick` is the
    /// pasteboard changeCount snapshotted in the tap callback (rung 3a).
    /// Call off the main thread; AX calls can stall.
    static func forDoubleClick(at point: CGPoint, pbCountAtClick: Int, allowClipboard: Bool) -> Extraction {
        let byPoint = extract(at: point)
        // Own windows never trigger.
        if byPoint.appPid == ProcessInfo.processInfo.processIdentifier { return Extraction() }
        if byPoint.role == "AXSecureTextField" { return Extraction() }

        let bySelection = extractFocused()
        if bySelection.role == "AXSecureTextField" { return Extraction() }

        // Prefer the click's own selection; it reaches web areas point lookup misses.
        var best = bySelection.word != nil ? bySelection : byPoint
        // Spike fix: word can be empty while context worked — take word from the
        // other path before falling through to the clipboard rungs.
        if best.word == nil { best.word = byPoint.word ?? bySelection.word }

        if best.word == nil {
            // Rung 3a: copy-on-select apps already wrote the pasteboard.
            let pb = NSPasteboard.general
            if pb.changeCount != pbCountAtClick,
               let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty, s.count < 2000 {
                best.ladder = "3a-copy-on-select"
                best.word = s.count <= 80 ? s : nil
                best.context = best.context ?? s
            } else if allowClipboard, byPoint.appPid != 0 {
                // Rung 3b: the click selected something only the app can copy.
                if let copied = clipboardRescue(pid: byPoint.appPid)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !copied.isEmpty {
                    best.ladder = "3b-clipboard-synth"
                    best.word = copied.count <= 80 ? copied : nil
                    best.context = best.context ?? copied
                }
            }
        }
        return best
    }

    static func extract(at point: CGPoint, retried: Bool = false) -> Extraction {
        var out = Extraction()
        guard let el = element(at: point) else { return out }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        out.appPid = pid
        out.app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        out.role = (attr(el, "AXRole") as? String) ?? "?"
        if out.role == "AXSecureTextField" { return out }

        // Rung 1: char range at point + a context window around it.
        if let hit = cfRange(paramAttr(el, "AXRangeForPosition", axValue(point))) {
            let total = (attr(el, "AXNumberOfCharacters") as? Int) ?? Int.max
            let start = max(0, hit.location - contextRadius)
            let end = min(total, hit.location + hit.length + contextRadius)
            if end > start,
               let text = paramAttr(el, "AXStringForRange", axValue(CFRange(location: start, length: end - start))) as? String,
               !text.isEmpty {
                out.ladder = "1-full-ax"
                out.context = text
                out.word = wordAround(text, offset: hit.location - start)
                return out
            }
        }

        // Rung 2: the click's own selection.
        if let sel = attr(el, "AXSelectedText") as? String, !sel.isEmpty {
            out.ladder = "2-selection-only"
            out.word = sel
            if let full = attr(el, "AXValue") as? String, full.count < 20_000, let r = full.range(of: sel) {
                let lo = full.index(r.lowerBound, offsetBy: -contextRadius, limitedBy: full.startIndex) ?? full.startIndex
                let hi = full.index(r.upperBound, offsetBy: contextRadius, limitedBy: full.endIndex) ?? full.endIndex
                out.context = String(full[lo..<hi])
                out.ladder = "2-selection+value"
            }
            return out
        }

        // Rung 2b: whole value as context (word comes from selection or clipboard).
        if let full = attr(el, "AXValue") as? String, !full.isEmpty {
            out.ladder = "2b-value-only"
            out.context = String(full.prefix(2 * contextRadius))
            return out
        }

        if !retried {
            nudgeChromium(pid: pid)
            usleep(150_000)
            return extract(at: point, retried: true)
        }
        return out
    }

    static func extractFocused() -> Extraction {
        var out = Extraction()
        // Spike lesson: system-wide focused element is flaky; go via frontmost app.
        var focusedObj = attr(systemWide, "AXFocusedUIElement")
        if focusedObj == nil, let app = NSWorkspace.shared.frontmostApplication {
            focusedObj = attr(AXUIElementCreateApplication(app.processIdentifier), "AXFocusedUIElement")
        }
        guard let focusedObj = focusedObj else { return out }
        let el = focusedObj as! AXUIElement
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        out.appPid = pid
        out.app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        out.role = (attr(el, "AXRole") as? String) ?? "?"
        if out.role == "AXSecureTextField" { return out }

        out.word = attr(el, "AXSelectedText") as? String
        if out.word?.isEmpty == true { out.word = nil }
        if let selRange = cfRange(attr(el, "AXSelectedTextRange")) {
            let total = (attr(el, "AXNumberOfCharacters") as? Int) ?? Int.max
            let start = max(0, selRange.location - contextRadius)
            let end = min(total, selRange.location + selRange.length + contextRadius)
            if end > start,
               let text = paramAttr(el, "AXStringForRange", axValue(CFRange(location: start, length: end - start))) as? String,
               !text.isEmpty {
                out.context = text
                out.ladder = "1-full-ax"
                return out
            }
        }
        out.ladder = out.word != nil ? "2-selection-only" : "none"
        return out
    }

    private static func wordAround(_ text: String, offset: Int) -> String? {
        let chars = Array(text)
        guard offset >= 0, offset < chars.count else { return nil }
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" }
        guard isWord(chars[offset]) else { return nil }
        var lo = offset, hi = offset
        while lo > 0, isWord(chars[lo - 1]) { lo -= 1 }
        while hi < chars.count - 1, isWord(chars[hi + 1]) { hi += 1 }
        return String(chars[lo...hi])
    }

    // MARK: Rung 3b

    /// Synthesize ⌘C at the clicked app, read the pasteboard, restore it.
    /// TODO(engine): restore all pasteboard flavors, not just plain string.
    private static func clipboardRescue(pid: pid_t) -> String? {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)

        func attempt(_ post: (CGEvent, CGEvent) -> Void) -> String? {
            let before = pb.changeCount
            guard let src = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false) else { return nil }
            down.flags = .maskCommand
            up.flags = .maskCommand
            post(down, up)
            for _ in 0..<16 { usleep(25_000); if pb.changeCount != before { break } }
            guard pb.changeCount != before else { return nil }
            return pb.string(forType: .string)
        }

        var copied = attempt { d, u in d.postToPid(pid); u.postToPid(pid) }
        if copied == nil {
            copied = attempt { d, u in d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap) }
        }
        if copied != nil {
            pb.clearContents()
            if let saved = saved { pb.setString(saved, forType: .string) }
        }
        return copied
    }
}
