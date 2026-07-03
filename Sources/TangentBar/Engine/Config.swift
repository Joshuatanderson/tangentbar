// Persisted settings. Configure once, never re-ask — lives in
// ~/Library/Application Support/TangentBar/config.json.

import Foundation

struct Config: Codable {
    var enabled = true
    /// Transport for tangents: "lmstudio" (local, prewarmed, ~0.16 s warm) with
    /// `claude -p` as automatic fallback when the local server is unreachable.
    var provider = "lmstudio"
    var localBaseURL = "http://localhost:1234/v1"
    /// Model answering tangents. At launch the local servers (LM Studio,
    /// Ollama) are probed; if this model isn't served, the best available one
    /// is adopted (qwen preferred, then gemma). Switchable from the status
    /// menu's Model submenu.
    var tangentModel = "qwen3.5-0.8b-mlx"
    /// Model used when falling back to the claude CLI.
    var claudeModel = "haiku"
    /// Interpose the pill affordance (click it to open) instead of defining
    /// immediately on double-click. Off by default: double-click just defines.
    var usePill = false
    /// Seconds the pill affordance lingers after a double-click.
    var pillTimeout = 1.6
    /// Allow the ⌘C-synthesis rung (rung 3b) where AX has no text.
    var clipboardFallback = true
    /// Bundle IDs / app names where the trigger is suppressed entirely.
    var excludedApps: [String] = []

    // Tolerant decoding: a config.json written by an older build (missing
    // newer keys) must load with defaults filled in, not reset wholesale.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
        localBaseURL = try c.decodeIfPresent(String.self, forKey: .localBaseURL) ?? d.localBaseURL
        tangentModel = try c.decodeIfPresent(String.self, forKey: .tangentModel) ?? d.tangentModel
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        usePill = try c.decodeIfPresent(Bool.self, forKey: .usePill) ?? d.usePill
        pillTimeout = try c.decodeIfPresent(Double.self, forKey: .pillTimeout) ?? d.pillTimeout
        clipboardFallback = try c.decodeIfPresent(Bool.self, forKey: .clipboardFallback) ?? d.clipboardFallback
        excludedApps = try c.decodeIfPresent([String].self, forKey: .excludedApps) ?? d.excludedApps
    }

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
