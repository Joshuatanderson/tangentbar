// Finds what's actually loadable locally instead of trusting a hardcoded id.
// Probes every known OpenAI-compatible local server (LM Studio, Ollama) via
// GET /models; results feed the status-item Model submenu and the launch-time
// default (qwen preferred, then gemma — per the "local by default" decision).

import Foundation

struct LocalModel: Equatable {
    let id: String
    let baseURL: String

    /// Sentinel baseURL routing this model through the claude CLI instead of
    /// a local HTTP server. Claude models are offered as first-class picks
    /// whenever the CLI is installed — not just as the automatic fallback.
    static let claudeBaseURL = "claude"
    var isClaude: Bool { baseURL == LocalModel.claudeBaseURL }

    var server: String {
        if isClaude { return "claude CLI" }
        return baseURL.contains(":11434") ? "Ollama" : "LM Studio"
    }
}

enum ModelDiscovery {
    /// The two local servers this machine runs; the configured base URL is
    /// probed too in case it points elsewhere.
    static let knownBaseURLs = ["http://localhost:1234/v1", "http://localhost:11434/v1"]

    /// Default-pick preference: qwen beats gemma beats anything else.
    static func rank(_ id: String) -> Int {
        let lower = id.lowercased()
        if lower.contains("qwen") { return 0 }
        if lower.contains("gemma") { return 1 }
        return 2
    }

    /// Probe all candidate servers concurrently; completion fires on the main
    /// queue with chat-capable models sorted by preference. Servers that are
    /// down simply contribute nothing (2 s timeout).
    static func discover(including configuredBaseURL: String,
                         completion: @escaping ([LocalModel]) -> Void) {
        var bases = knownBaseURLs
        if !bases.contains(configuredBaseURL) { bases.insert(configuredBaseURL, at: 0) }

        let group = DispatchGroup()
        let lock = NSLock()
        var found: [LocalModel] = []

        for base in bases {
            guard let url = URL(string: base + "/models") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            group.enter()
            URLSession.shared.dataTask(with: request) { data, _, _ in
                defer { group.leave() }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let list = json["data"] as? [[String: Any]] else { return }
                // The servers also list embedding / image / speech models.
                let nonChat = ["embed", "diffusion", "whisper", "clip"]
                let models = list.compactMap { $0["id"] as? String }
                    .filter { id in !nonChat.contains { id.lowercased().contains($0) } }
                    .map { LocalModel(id: $0, baseURL: base) }
                lock.lock()
                found.append(contentsOf: models)
                lock.unlock()
            }.resume()
        }

        group.notify(queue: .main) {
            var models = found.sorted { (rank($0.id), $0.id) < (rank($1.id), $1.id) }
            // The claude CLI's models, listed after the local ones: pickable
            // any time, but never the auto-selected default — local-first (D7).
            if Engine.claudePath != nil {
                models += ["haiku", "sonnet", "opus", "fable"].map {
                    LocalModel(id: $0, baseURL: LocalModel.claudeBaseURL)
                }
            }
            completion(models)
        }
    }
}
