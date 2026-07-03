// axspike — Tangent v2 extraction-feasibility spike.
//
// Proves (or disproves) the core bet: that the Accessibility API can hand us
// "the word under the cursor plus surrounding context" from arbitrary apps.
// Throwaway by design; findings feed the real app's fallback ladder.
//
// Subcommands:
//   check            print whether this process is AX-trusted (never prompts)
//   here             one-shot: extract at the current mouse position
//   at <x> <y>       one-shot: extract at global top-left-origin coordinates
//   focused          read the focused element's selection + context (flow B probe)
//   watch            event-tap loop: extract on every double-click until Ctrl-C
//
// Build:  swiftc -O -o axspike axspike.swift
// None of the one-shot modes create windows, move the pointer, or change focus.

import AppKit
import ApplicationServices

// MARK: - AX plumbing

let systemWide = AXUIElementCreateSystemWide()

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
    return value
}

func paramAttr(_ el: AXUIElement, _ name: String, _ param: AnyObject) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyParameterizedAttributeValue(el, name as CFString, param, &value) == .success else { return nil }
    return value
}

func cfRange(_ value: AnyObject?) -> CFRange? {
    guard let value = value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = value as! AXValue
    var range = CFRange()
    guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
    return range
}

func axValue(_ range: CFRange) -> AXValue {
    var r = range
    return AXValueCreate(.cfRange, &r)!
}

func axValue(_ point: CGPoint) -> AXValue {
    var p = point
    return AXValueCreate(.cgPoint, &p)!
}

func element(at point: CGPoint) -> AXUIElement? {
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &el) == .success else { return nil }
    return el
}

func appName(of el: AXUIElement) -> (pid: pid_t, name: String) {
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    return (pid, name)
}

/// Chromium-family apps ship a reduced AX tree until assistive tech announces
/// itself. AXEnhancedUserInterface is the browser switch (what VoiceOver sets);
/// AXManualAccessibility is the Electron variant. Harmless elsewhere.
func nudgeChromium(pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
}

// MARK: - Extraction (the actual experiment)

struct Extraction {
    var app = "?"
    var role = "?"
    var ladder = "none"       // which fallback rung produced the text
    var word: String?         // word at point (or selected text)
    var context: String?      // surrounding excerpt
    var note: String?
}

let contextRadius = 400  // chars each side

func extract(at point: CGPoint, retried: Bool = false) -> Extraction {
    var out = Extraction()
    guard let el = element(at: point) else {
        out.note = "no AX element at point"
        return out
    }
    let (pid, name) = appName(of: el)
    out.app = name
    out.role = (attr(el, "AXRole") as? String) ?? "?"

    // Never read secure fields — and never fall back around them either.
    if out.role == "AXSecureTextField" {
        out.note = "secure field — suppressed by design"
        return out
    }

    // Rung 1: parameterized attributes — char range at point, then a window around it.
    if let hit = cfRange(paramAttr(el, "AXRangeForPosition", axValue(point))) {
        let total = (attr(el, "AXNumberOfCharacters") as? Int) ?? Int.max
        let start = max(0, hit.location - contextRadius)
        let end = min(total, hit.location + hit.length + contextRadius)
        let window = CFRange(location: start, length: end - start)
        if let text = paramAttr(el, "AXStringForRange", axValue(window)) as? String, !text.isEmpty {
            out.ladder = "1-full-ax"
            out.context = text
            out.word = wordAround(text, offset: hit.location - start)
            return out
        }
    }

    // Rung 2: selected text only (double-click already selected the word natively).
    if let sel = attr(el, "AXSelectedText") as? String, !sel.isEmpty {
        out.ladder = "2-selection-only"
        out.word = sel
        // Some apps still give a value string even without parameterized support.
        if let full = attr(el, "AXValue") as? String, full.count < 20_000,
           let r = full.range(of: sel) {
            let lo = full.index(r.lowerBound, offsetBy: -contextRadius, limitedBy: full.startIndex) ?? full.startIndex
            let hi = full.index(r.upperBound, offsetBy: contextRadius, limitedBy: full.endIndex) ?? full.endIndex
            out.context = String(full[lo..<hi])
            out.ladder = "2-selection+value"
        }
        return out
    }

    // Rung 2b: the element's whole value (no position mapping — the caller's
    // double-click selection supplies the word; this at least supplies context).
    if let full = attr(el, "AXValue") as? String, !full.isEmpty {
        out.ladder = "2b-value-only"
        out.context = full.count > 2 * contextRadius ? String(full.prefix(2 * contextRadius)) : full
        return out
    }

    // Chromium/Electron nudge, then retry the whole ladder once.
    if !retried {
        nudgeChromium(pid: pid)
        usleep(150_000)
        var second = extract(at: point, retried: true)
        if second.ladder != "none" {
            second.note = (second.note.map { $0 + "; " } ?? "") + "needed AXManualAccessibility nudge"
        }
        return second
    }

    out.note = "no text via AX (rung 3 clipboard-synth not implemented in spike)"
    return out
}

/// Expand alphanumerics around `offset` in `text` to recover the word at point.
func wordAround(_ text: String, offset: Int) -> String? {
    let chars = Array(text)
    guard offset >= 0, offset < chars.count else { return nil }
    let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" }
    var lo = offset, hi = offset
    if !isWord(chars[lo]) { return nil }
    while lo > 0, isWord(chars[lo - 1]) { lo -= 1 }
    while hi < chars.count - 1, isWord(chars[hi + 1]) { hi += 1 }
    return String(chars[lo...hi])
}

/// Flow-B probe: the focused element's selection + context around the selection range.
func extractFocused() -> Extraction {
    var out = Extraction()
    // System-wide AXFocusedUIElement is flaky; go via the focused application.
    var focusedObj = attr(systemWide, "AXFocusedUIElement")
    if focusedObj == nil,
       let app = NSWorkspace.shared.frontmostApplication {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        focusedObj = attr(appEl, "AXFocusedUIElement")
    }
    guard let focusedObj = focusedObj else {
        out.note = "no focused element"
        return out
    }
    let el = focusedObj as! AXUIElement
    let (_, name) = appName(of: el)
    out.app = name
    out.role = (attr(el, "AXRole") as? String) ?? "?"
    if out.role == "AXSecureTextField" { out.note = "secure field — suppressed"; return out }

    out.word = attr(el, "AXSelectedText") as? String
    if let selRange = cfRange(attr(el, "AXSelectedTextRange")) {
        let total = (attr(el, "AXNumberOfCharacters") as? Int) ?? Int.max
        let start = max(0, selRange.location - contextRadius)
        let end = min(total, selRange.location + selRange.length + contextRadius)
        let window = CFRange(location: start, length: end - start)
        if let text = paramAttr(el, "AXStringForRange", axValue(window)) as? String {
            out.context = text
            out.ladder = "1-full-ax"
            return out
        }
    }
    out.ladder = out.word != nil ? "2-selection-only" : "none"
    return out
}

// MARK: - App-tree probe (support matrix without touching the pointer or focus)

/// Walk an app's AX tree looking for text-bearing elements, then test the exact
/// attributes the tangent flow needs on each: char count, StringForRange, and
/// RangeForPosition at the element's own center (works even when occluded).
func probe(appNamed query: String) {
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    let app = apps.first(where: { ($0.localizedName ?? "").caseInsensitiveCompare(query) == .orderedSame })
        ?? apps.first(where: { ($0.localizedName ?? "").localizedCaseInsensitiveContains(query) })
    guard let app = app else {
        print("no running app matching \"\(query)\""); exit(1)
    }
    let name = app.localizedName ?? query
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(appEl, 0.5)
    nudgeChromium(pid: app.processIdentifier)
    usleep(200_000)

    let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXStaticText", "AXWebArea"]
    // Walk windows, not the app element — the app's children are dominated by
    // menu-bar items, and AX only exposes windows on the current Space anyway.
    let windows = (attr(appEl, "AXWindows") as? [AXUIElement]) ?? []
    var found: [(el: AXUIElement, role: String)] = []
    var roleCounts: [String: Int] = [:]
    var queue: [AXUIElement] = windows
    var visited = 0
    while !queue.isEmpty, visited < 6000, found.count < 10 {
        let el = queue.removeFirst()
        visited += 1
        let role = (attr(el, "AXRole") as? String) ?? "?"
        roleCounts[role, default: 0] += 1
        if textRoles.contains(role), role != "AXSecureTextField" {
            let chars = (attr(el, "AXNumberOfCharacters") as? Int) ?? -1
            let hasValue = (attr(el, "AXValue") as? String)?.isEmpty == false
            // Prefer substantive text over tab labels and buttons.
            if chars > 30 || (hasValue && chars < 0) { found.append((el, role)) }
        }
        if let kids = attr(el, "AXChildren") as? [AXUIElement] { queue.append(contentsOf: kids) }
    }
    print("── probe \(name)  (\(windows.count) windows on this Space, visited \(visited) nodes, \(found.count) text elements)")
    let top = roleCounts.sorted { $0.value > $1.value }.prefix(10)
        .map { "\($0.key)×\($0.value)" }.joined(separator: "  ")
    print("   roles: \(top)")
    if windows.isEmpty { print("   no windows on the current Space — nothing to probe"); return }
    if found.isEmpty {
        let top = roleCounts.sorted { $0.value > $1.value }.prefix(8)
            .map { "\($0.key)×\($0.value)" }.joined(separator: "  ")
        print("   NO text elements found — clipboard rung or OCR territory")
        print("   roles seen: \(top)")
    }

    for (el, role) in found {
        let chars = (attr(el, "AXNumberOfCharacters") as? Int) ?? -1
        var sample = "—"
        if let s = paramAttr(el, "AXStringForRange", axValue(CFRange(location: 0, length: min(60, max(chars, 0))))) as? String {
            sample = s.replacingOccurrences(of: "\n", with: "⏎")
        } else if let v = attr(el, "AXValue") as? String {
            sample = "(value-only) " + String(v.prefix(60)).replacingOccurrences(of: "\n", with: "⏎")
        }
        var posTest = "RangeForPosition: unsupported"
        if let posVal = attr(el, "AXPosition"), let sizeVal = attr(el, "AXSize"),
           CFGetTypeID(posVal) == AXValueGetTypeID(), CFGetTypeID(sizeVal) == AXValueGetTypeID() {
            var p = CGPoint.zero; var s = CGSize.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &p)
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &s)
            let center = CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
            if let hit = cfRange(paramAttr(el, "AXRangeForPosition", axValue(center))) {
                let lo = max(0, hit.location - 20)
                let len = chars > 0 ? min(40, chars - lo) : 40
                let ctx = paramAttr(el, "AXStringForRange", axValue(CFRange(location: lo, length: max(0, len)))) as? String
                posTest = "RangeForPosition: OK @\(hit.location) → “\((ctx ?? "").replacingOccurrences(of: "\n", with: "⏎"))”"
            }
        }
        print("   [\(role)] chars=\(chars)  sample: \(sample.prefix(70))")
        print("      \(posTest)")
    }
}

// MARK: - Output

func report(_ e: Extraction, header: String) {
    print("── \(header)")
    print("   app: \(e.app)   role: \(e.role)   ladder: \(e.ladder)")
    if let w = e.word { print("   word: \(w)") }
    if let c = e.context {
        let flat = c.replacingOccurrences(of: "\n", with: "⏎")
        print("   context(\(c.count)): \(flat.prefix(240))\(flat.count > 240 ? "…" : "")")
    }
    if let n = e.note { print("   note: \(n)") }
}

// MARK: - Rung 3: clipboard synthesis
//
// Only valid right after a real user double-click (which made a selection).
// Synthesizes ⌘C at the clicked app, reads the pasteboard, restores it.
// Spike caveat: restores the plain-string flavor only.

func clipboardRescue(pid: pid_t) -> (text: String?, diag: String) {
    let pb = NSPasteboard.general
    let saved = pb.string(forType: .string)
    var diag: [String] = []

    func attempt(_ label: String, _ post: (CGEvent, CGEvent) -> Void) -> String? {
        let before = pb.changeCount
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false) else {
            diag.append("\(label): event creation failed"); return nil
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        post(down, up)
        // Wait up to 400 ms for the app to service the copy.
        for _ in 0..<16 { usleep(25_000); if pb.changeCount != before { break } }
        if pb.changeCount != before { diag.append("\(label): copied"); return pb.string(forType: .string) }
        diag.append("\(label): pasteboard unchanged")
        return nil
    }

    var copied = attempt("postToPid") { d, u in d.postToPid(pid); u.postToPid(pid) }
    if copied == nil {
        // The clicked app is frontmost anyway — HID-level posting reaches apps
        // that ignore pid-targeted events.
        copied = attempt("hidTap") { d, u in d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap) }
    }
    if copied != nil {
        pb.clearContents()
        if let saved = saved { pb.setString(saved, forType: .string) }
    }
    return (copied, diag.joined(separator: "; "))
}

// MARK: - Watch mode (double-click tap)

var gTap: CFMachPort?
var gPbCountAtClick = 0

func watch() {
    let mask = CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = gTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseUp, event.getIntegerValueField(.mouseEventClickState) == 2 {
            let loc = event.location
            let alt = event.flags.contains(.maskAlternate)
            gPbCountAtClick = NSPasteboard.general.changeCount
            // Never do slow work in the tap callback — the OS kills laggy taps.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                // The double-click natively selected the word: the selection path
                // is often richer than point lookup. Prefer whichever found a word.
                let byPoint = extract(at: loc)
                let bySelection = extractFocused()
                var best = bySelection.word != nil ? bySelection : byPoint
                // Rung 3: AX came up dry, but the click still made a selection the
                // app itself can copy. Never on secure fields.
                if best.word == nil, byPoint.role != "AXSecureTextField", bySelection.role != "AXSecureTextField" {
                    let pb = NSPasteboard.general
                    // 3a: copy-on-select terminals (ghostty et al.) already put the
                    // word on the pasteboard when the double-click selected it.
                    if pb.changeCount != gPbCountAtClick,
                       let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !s.isEmpty, s.count < 2000 {
                        best.ladder = "3a-copy-on-select"
                        best.word = s.count <= 80 ? s : nil
                        best.context = s
                        best.note = "app copied on select; pasteboard read directly"
                    } else {
                        var pid: pid_t = 0
                        if let el = element(at: loc) { AXUIElementGetPid(el, &pid) }
                        if pid != 0 {
                            let (copied, diag) = clipboardRescue(pid: pid)
                            if let copied = copied?.trimmingCharacters(in: .whitespacesAndNewlines), !copied.isEmpty {
                                best.ladder = "3b-clipboard-synth"
                                best.word = copied.count <= 80 ? copied : nil
                                best.context = copied
                                best.note = "⌘C synthesis (\(diag)); pasteboard restored (string flavor only in spike)"
                            } else {
                                best.note = "rung 3 attempted — \(diag)"
                            }
                        }
                    }
                }
                report(best, header: "double-click\(alt ? " (⌥ held)" : "") at \(Int(loc.x)),\(Int(loc.y))")
            }
        }
        return Unmanaged.passUnretained(event)
    }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .listenOnly, eventsOfInterest: mask,
                                      callback: callback, userInfo: nil) else {
        print("FAIL: could not create event tap — is Accessibility granted?")
        exit(1)
    }
    gTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("watching — double-click words anywhere (Ctrl-C to stop)…")
    CFRunLoopRun()
}

// MARK: - Main

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "check"

switch cmd {
case "check":
    let trusted = AXIsProcessTrusted()
    print(trusted ? "trusted: yes" : "trusted: NO — grant in System Settings → Privacy & Security → Accessibility")
    exit(trusted ? 0 : 2)

case "here":
    // CGEvent's location is already in AX's top-left-origin global coordinates.
    let loc = CGEvent(source: nil)?.location ?? .zero
    report(extract(at: loc), header: "mouse at \(Int(loc.x)),\(Int(loc.y))")

case "at":
    guard args.count == 4, let x = Double(args[2]), let y = Double(args[3]) else {
        print("usage: axspike at <x> <y>   (global, top-left origin)"); exit(64)
    }
    report(extract(at: CGPoint(x: x, y: y)), header: "point \(Int(x)),\(Int(y))")

case "focused":
    report(extractFocused(), header: "focused element")

case "watch":
    watch()

case "probe":
    guard args.count >= 3 else { print("usage: axspike probe <app name>"); exit(64) }
    probe(appNamed: args[2])

default:
    print("usage: axspike check|here|at <x> <y>|focused|watch|probe <app>")
    exit(64)
}
