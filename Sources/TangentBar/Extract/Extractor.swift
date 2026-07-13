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
    /// Password fields: native ones report role AXSecureTextField, but web
    /// password inputs are AXTextField with subrole AXSecureTextField.
    var secure = false
    var ladder = "none"
    var word: String?
    var context: String?
    /// The AX element the text came from — kept for context enrichment.
    var element: AXUIElement?

    var hasText: Bool { word != nil || context != nil }
    /// Context that adds nothing over the word itself doesn't ground a definition.
    var hasUsefulContext: Bool {
        guard let c = context, let w = word else { return context != nil }
        return c.count > w.count + 40
    }
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
        // Apps report junk ranges — location can be NSNotFound (Int.max), and
        // adding contextRadius to that traps with arithmetic overflow (crashed
        // the app twice from a double-click). Reject anything a real text
        // buffer couldn't hold.
        let maxSane = 100_000_000
        guard range.location >= 0, range.length >= 0,
              range.location < maxSane, range.length < maxSane else { return nil }
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

    /// Secure text: native fields wear the role; web password inputs are plain
    /// AXTextField carrying the subrole (Chromium and WebKit both). Either one
    /// suppresses every rung — including 3b, which would ⌘C the password.
    private static func isSecure(_ el: AXUIElement, role: String) -> Bool {
        if role == "AXSecureTextField" { return true }
        return (attr(el, "AXSubrole") as? String) == "AXSecureTextField"
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
    static func forDoubleClick(at point: CGPoint, pbCountAtClick: Int, allowClipboard: Bool,
                               excludedApps: [String] = []) -> Extraction {
        var byPoint = extract(at: point)
        // Own windows never trigger.
        if byPoint.appPid == ProcessInfo.processInfo.processIdentifier { return Extraction() }
        if byPoint.secure { return Extraction() }
        // Excluded apps bail BEFORE the invasive rungs — 3b would synthesize
        // ⌘C into them (games interpret keystrokes).
        if excludedApps.contains(byPoint.app) { return Extraction() }

        var bySelection = extractFocused()
        if bySelection.secure { return Extraction() }

        // Chromium's AXSelectedText can be pure U+FFFC (object replacement) —
        // a garbage "word" that would otherwise win the ladder. Clean both
        // paths first so junk selections fall through to the clipboard rungs.
        byPoint.word = cleanWord(byPoint.word)
        bySelection.word = cleanWord(bySelection.word)

        // Prefer the click's own selection; it reaches web areas point lookup misses.
        var best = bySelection.word != nil ? bySelection : byPoint
        // Spike fix: word can be empty while context worked — take word from the
        // other path before falling through to the clipboard rungs.
        if best.word == nil { best.word = byPoint.word ?? bySelection.word }
        // Cross-merge context: the losing path may have grounded better (Brave:
        // selection path wins the word with context==word; point path has the text).
        let altContext = [byPoint.context, bySelection.context].compactMap { $0 }
            .max(by: { $0.count < $1.count })
        if let alt = altContext, alt.count > (best.context?.count ?? 0) {
            best.context = alt
            best.ladder += "+x"
        }

        if best.word == nil {
            // Rung 3a: copy-on-select apps already wrote the pasteboard.
            let pb = NSPasteboard.general
            if pb.changeCount != pbCountAtClick,
               let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty, s.count < 2000 {
                best.ladder = "3a-copy-on-select"
                best.word = s.count <= 80 ? cleanWord(s) : nil
                best.context = best.context ?? s
            } else if allowClipboard, byPoint.appPid != 0 {
                // Rung 3b: the click selected something only the app can copy.
                if let copied = clipboardRescue(pid: byPoint.appPid)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !copied.isEmpty {
                    best.ladder = "3b-clipboard-synth"
                    best.word = copied.count <= 80 ? cleanWord(copied) : nil
                    best.context = best.context ?? copied
                }
            }
        }

        // Context ladder (D-record 2026-07-03): the word rungs above may win a
        // word with no grounding. Enrich in fidelity order per app class: a
        // terminal's own buffer is exact (and its AX tree is junk-prone), so
        // it outranks AX kin text there; everywhere else kin is the rung.
        if !best.hasUsefulContext, let word = best.word {
            if let term = TerminalContext.forWord(word, app: best.app) {
                best.context = term
                best.ladder += "+term"
            } else if let el = best.element ?? bySelection.element ?? byPoint.element,
                      let kin = kinText(around: el), kin.count > (best.context?.count ?? 0) {
                best.context = window(around: word, in: kin)
                best.ladder += "+kin"
            }
        }
        // Object-replacement chars pepper Chromium AX text (inline images etc).
        best.context = best.context?.replacingOccurrences(of: "\u{FFFC}", with: " ")
        return best
    }

    /// A usable word has at least one letter or digit once invisible junk
    /// (U+FFFC object replacement, zero-width space) is stripped.
    /// Internal (not private) for the unit tests.
    static func cleanWord(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              cleaned.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return cleaned
    }

    /// Extraction for a drag-selection (flow B): the full selected text plus
    /// the surrounding source for excerpt padding. Terminals cover us via
    /// copy-on-select — the drag itself wrote the pasteboard.
    static func forSelection(pbCountAtDragStart: Int) -> (selection: String, source: String?, app: String)? {
        let focused = extractFocused()
        if focused.appPid == ProcessInfo.processInfo.processIdentifier { return nil }
        if focused.secure { return nil }

        var selection = focused.word?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        selection = selection.replacingOccurrences(of: "\u{FFFC}", with: " ")
        var app = focused.app
        if selection.isEmpty {
            let pb = NSPasteboard.general
            // Copy-on-select (ghostty/cmux) lands a beat AFTER mouse-up — a
            // single immediate check loses the race (measured: our check ran
            // 1–27 ms post-drag and always saw "unchanged"). Poll up to 360 ms.
            var attempts = 0
            while pb.changeCount == pbCountAtDragStart && attempts < 12 {
                usleep(30_000)
                attempts += 1
            }
            guard pb.changeCount != pbCountAtDragStart,
                  let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty, s.count < 20_000 else {
                NSLog("forSelection: nothing — app=%@ AX selection empty, pasteboard unchanged after %dms",
                      app, attempts * 30)
                return nil
            }
            selection = s
            if app == "?" {
                app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            }
        }
        guard selection.count >= 4 else {
            NSLog("forSelection: too short (%d chars) — app=%@", selection.count, app)
            return nil
        }
        return (selection, focused.context, app)
    }

    // MARK: Context enrichment

    /// Centered window (±contextRadius) around the last occurrence of `word`.
    static func window(around word: String, in text: String) -> String {
        guard let r = text.range(of: word, options: .backwards) else {
            return String(text.prefix(2 * contextRadius))
        }
        let lo = text.index(r.lowerBound, offsetBy: -contextRadius, limitedBy: text.startIndex) ?? text.startIndex
        let hi = text.index(r.upperBound, offsetBy: contextRadius, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[lo..<hi])
    }

    /// Kin gathering: when the hit element's own text is thin (Discord message
    /// bubbles, web table cells), stitch the text of nearby elements — walk up
    /// a few ancestors collecting children's values. Bounded: 3 levels, 60
    /// children per level, 400 chars per piece, 800 total.
    private static func kinText(around el: AXUIElement, minChars: Int = 120) -> String? {
        var node = el
        for _ in 0..<3 {
            guard let parentObj = attr(node, "AXParent") else { break }
            let parent = parentObj as! AXUIElement
            var pieces: [String] = []
            var total = 0
            if let children = attr(parent, "AXChildren") as? [AnyObject] {
                for childObj in children.prefix(60) {
                    let child = childObj as! AXUIElement
                    let text = (attr(child, "AXValue") as? String)
                        ?? (attr(child, "AXTitle") as? String)
                    guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !t.isEmpty else { continue }
                    let piece = String(t.prefix(400))
                    pieces.append(piece)
                    total += piece.count
                    if total >= 2 * contextRadius { break }
                }
            }
            let joined = pieces.joined(separator: " ")
            if joined.count >= minChars { return joined }
            node = parent
        }
        return nil
    }

    static func extract(at point: CGPoint, retried: Bool = false) -> Extraction {
        var out = Extraction()
        guard let el = element(at: point) else { return out }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        out.appPid = pid
        out.app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        out.role = (attr(el, "AXRole") as? String) ?? "?"
        out.secure = isSecure(el, role: out.role)
        out.element = el
        if out.secure { return out }

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
        out.secure = isSecure(el, role: out.role)
        out.element = el
        if out.secure { return out }

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

    /// Internal (not private) for the unit tests.
    static func wordAround(_ text: String, offset: Int) -> String? {
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
    /// The snapshot keeps EVERY flavor — restoring only the string flavor
    /// would silently destroy an image or file the user had copied.
    private static func clipboardRescue(pid: pid_t) -> String? {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

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
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        return copied
    }
}
