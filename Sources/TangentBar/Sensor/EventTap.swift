// The sensor layer: a listen-only, mouse-only CGEventTap watching for
// double-clicks. Mouse-only keeps us inside the Accessibility grant
// (keyboard taps would require Input Monitoring on top).
//
// Hard rule: the tap callback only filters and forwards — any slow work here
// and the OS disables the tap.

import AppKit

final class EventTap {
    /// (global top-left-origin point, ⌥ held, pasteboard changeCount at click)
    var onDoubleClick: ((CGPoint, Bool, Int) -> Void)?
    private var tap: CFMachPort?

    @discardableResult
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .leftMouseUp, event.getIntegerValueField(.mouseEventClickState) == 2 {
                let location = event.location
                let alt = event.flags.contains(.maskAlternate)
                // Snapshot now: copy-on-select apps (ghostty) write the pasteboard
                // as part of the selection this click just made.
                let pbCount = NSPasteboard.general.changeCount
                DispatchQueue.main.async { me.onDoubleClick?(location, alt, pbCount) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
    }
}
