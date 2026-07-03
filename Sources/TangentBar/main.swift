// TangentBar — entry point. Accessory activation policy = menu-bar agent:
// no Dock icon, no app-switcher entry, never steals focus at launch.
//
// Dev loop: `swift build && .build/debug/TangentBar` from a terminal that has
// the Accessibility grant — the bare binary inherits it. Bundle + stable
// signing come at distribution time (TCC keys grants to the signature).

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = AppController()
app.delegate = controller
app.run()
