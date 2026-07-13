// Debug-gated logging. Anything that contains extracted CONTENT (words,
// selections) must go through Log.d — the unified log is readable by any
// process, so shipped builds must not record what users click. Coordinates,
// ladder names, and character counts are content-free and may use NSLog.

import Foundation

enum Log {
    static let debug = CommandLine.arguments.contains("--debug")

    static func d(_ format: String, _ args: CVarArg...) {
        guard debug else { return }
        withVaList(args) { NSLogv(format, $0) }
    }
}
