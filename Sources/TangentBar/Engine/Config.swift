// Persisted settings. Configure once, never re-ask — lives in
// ~/Library/Application Support/TangentBar/config.json.

import Foundation

struct Config: Codable {
    var enabled = true
    /// Transport for tangents: "lmstudio" (local, prewarmed, ~0.16 s warm) with
    /// `claude -p` as automatic fallback when the local server is unreachable.
    var provider = "lmstudio"
    var localBaseURL = "http://localhost:1234/v1"
    /// Model answering tangents — small local qwen by default (v1's
    /// resolve_model lesson, taken further: cheap AND instant).
    var tangentModel = "qwen3.5-0.8b-mlx"
    /// Model used when falling back to the claude CLI.
    var claudeModel = "haiku"
    /// Seconds the pill affordance lingers after a double-click.
    var pillTimeout = 1.6
    /// Allow the ⌘C-synthesis rung (rung 3b) where AX has no text.
    var clipboardFallback = true
    /// Bundle IDs / app names where the trigger is suppressed entirely.
    var excludedApps: [String] = []

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TangentBar/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Config.url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: Config.url)
    }
}
