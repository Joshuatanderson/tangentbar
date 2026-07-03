// Terminal adapter (context ladder, rung "term"): GPU terminals expose no AX
// text, but cmux can dump its focused pane over its own CLI — exact text, no
// OCR, no extra permissions. The double-click that triggered us also focused
// the clicked pane, so the CLI's default (focused) surface is the right one.

import Foundation

enum TerminalContext {
    private static let cliCandidates = [
        "/Applications/cmux.app/Contents/Resources/bin/cmux",
        "/opt/homebrew/bin/cmux",
        "/usr/local/bin/cmux",
    ]

    /// Terminal apps this adapter covers. Bare ghostty has no dump CLI, but
    /// Josh's ghostty runs inside cmux, whose server answers either way.
    private static func isTerminal(_ app: String) -> Bool {
        let a = app.lowercased()
        return a.contains("cmux") || a.contains("ghostty")
    }

    /// Pane text windowed around the last occurrence of `word`, or nil when
    /// the app isn't a covered terminal / the CLI isn't reachable.
    static func forWord(_ word: String, app: String) -> String? {
        guard isTerminal(app) else { return nil }
        guard let dump = run(["capture-pane", "--lines", "80"]) ?? run(["read-screen"]),
              dump.contains(word) else { return nil }
        return Extractor.window(around: word, in: dump)
    }

    private static func run(_ args: [String]) -> String? {
        guard let bin = cliCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }

        // Read off-process before waiting so a full pipe can't wedge the CLI;
        // give it a hard 1.5 s — extraction runs pre-panel, latency is felt.
        var data = Data()
        let reader = DispatchQueue(label: "tangent.terminal.read")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning && Date() < deadline { usleep(30_000) }
        if process.isRunning { process.terminate() }
        _ = done.wait(timeout: .now() + 0.5)

        guard process.terminationStatus == 0,
              let s = String(data: data, encoding: .utf8),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
}
