// The brain: derives the tangent prompt and streams the answer.
//
// Default transport: the local LM Studio server (OpenAI-compatible SSE) with a
// small qwen — measured 0.16 s warm vs ~16 s for `claude -p`, hence prewarming
// at launch + keepalive. `claude -p` is the fallback when local is unreachable.

import Foundation

final class Engine {
    private var process: Process?
    private var sse: SSEStream?
    private var keepAliveTimer: Timer?
    private var cancelled = false

    /// Mirrors v1 tangent.rs: a short, constant dictionary framing; the
    /// grounding context is a snapshot, isolated from any main conversation.
    /// Honesty rule: when extraction produced no real context, say so instead
    /// of presenting the bare word as a passage — the model then gives its
    /// most common meaning rather than hallucinating a situational one.
    static func tangentPrompt(word: String, context: String) -> String {
        let passage = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard passage.count > word.count + 10 else {
            return """
            Define "\(word)" in 2–4 short sentences. No surrounding context is \
            available, so give the most common meaning; if it is primarily \
            jargon, name the field it comes from. Answer with the definition \
            only — no preamble.
            """
        }
        return """
        Define "\(word)" as it is used in the passage below, in 2–4 short \
        sentences. If it is jargon, name the field it comes from. Answer with \
        the definition only — no preamble.

        Passage:
        \(passage)
        """
    }

    // MARK: Prewarm

    /// Load the local model now and keep it hot. Near-instant tangents depend
    /// on this: cold JIT load measured at ~7.6 s, warm at ~0.16 s.
    func prewarm(config: Config) {
        guard config.provider == "lmstudio" else { return }
        ping(config: config)
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { [weak self] _ in
            self?.ping(config: config)
        }
    }

    private func ping(config: Config) {
        ping(model: config.tangentModel, baseURL: config.localBaseURL)
        // A separate chat model gets the same treatment — otherwise the first
        // chat turn eats the ~7.6 s cold load.
        if config.resolvedChatModel != config.tangentModel {
            ping(model: config.resolvedChatModel, baseURL: config.resolvedChatBaseURL)
        }
    }

    private func ping(model: String, baseURL: String) {
        guard let url = URL(string: baseURL + "/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1, "stream": false,
            // LM Studio: keep the JIT model loaded 2 h past the last request,
            // so app relaunches within that window skip the ~7.6 s cold load.
            // Ollama ignores the field (verified).
            "ttl": 7200,
        ])
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: Streaming

    /// The claude CLI, if this machine has it. GUI apps launch with a bare
    /// PATH (/usr/bin:/bin:…), so Homebrew and user installs must be probed
    /// explicitly; `env claude` only works from a terminal.
    static let claudePath: String? = {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            home + "/.local/bin/claude", home + "/.claude/local/claude",
            home + "/.bun/bin/claude", home + "/.volta/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    func streamTangent(word: String, context: String, config: Config,
                       onChunk: @escaping (String) -> Void,
                       onStatus: ((String) -> Void)? = nil,
                       onDone: @escaping (String) -> Void) {
        stream(system: nil, user: Engine.tangentPrompt(word: word, context: context),
               maxTokens: 300, model: config.tangentModel, baseURL: config.localBaseURL,
               claudeModel: config.claudeModel, timeout: 20,
               config: config, onChunk: onChunk, onStatus: onStatus, onDone: onDone)
    }

    /// A selection-chat turn (v1 explore semantics): constant system framing +
    /// a user message replaying excerpt and conversation. Chats get their own
    /// model — definitions want tiny-and-instant, conversations want smarter.
    func streamChat(excerpt: String, history: [Excerpt.Turn], config: Config,
                    onChunk: @escaping (String) -> Void,
                    onStatus: ((String) -> Void)? = nil,
                    onDone: @escaping (String) -> Void) {
        stream(system: Excerpt.system,
               user: Excerpt.prompt(excerpt: excerpt, history: history),
               maxTokens: 700, model: config.resolvedChatModel, baseURL: config.resolvedChatBaseURL,
               // Chat models are bigger and may take >20 s to first token.
               claudeModel: config.claudeChatModel, timeout: 60,
               config: config, onChunk: onChunk, onStatus: onStatus, onDone: onDone)
    }

    private func stream(system: String?, user: String, maxTokens: Int,
                        model: String, baseURL: String, claudeModel: String,
                        timeout: TimeInterval, config: Config,
                        onChunk: @escaping (String) -> Void,
                        onStatus: ((String) -> Void)?,
                        onDone: @escaping (String) -> Void) {
        cancel()
        cancelled = false  // cancel() above was housekeeping, not a user dismissal
        var messages: [[String: String]] = []
        if let system { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": user])
        // The claude fallback takes one flat prompt; fold the system in.
        let flatPrompt = system.map { $0 + "\n\n" + user } ?? user

        guard config.provider == "lmstudio",
              let url = URL(string: baseURL + "/chat/completions") else {
            streamViaClaude(prompt: flatPrompt, model: claudeModel, onChunk: onChunk, onDone: onDone)
            return
        }
        let stream = SSEStream(timeout: timeout, onChunk: onChunk) { [weak self] ok, gotVisible, gotRaw in
            if ok && gotVisible {
                onDone("done · \(model)")
            } else if gotRaw && !gotVisible {
                // The server DID answer — the model just burned its whole
                // budget inside <think>. A claude fallback would be a lie
                // ("unreachable") and a 16 s wait; say what happened instead.
                onChunk("(the model spent its entire answer thinking — try again, or pick a different model from the menu)")
                onDone("only reasoning · \(model)")
            } else if !gotRaw {
                // A user dismissal also lands here (cancel kills the stream
                // before data) — don't burn a claude call on a closed panel.
                guard let self, !self.cancelled else { return }
                guard Engine.claudePath != nil else {
                    // No local server AND no claude CLI: the honest state,
                    // not a mystery spawn failure.
                    onChunk("No model is available. Install Ollama (ollama.com) and pull a model — TangentBar will find it automatically.")
                    onDone("no model available")
                    return
                }
                // Local server down or empty — fall back to claude. Say so:
                // claude takes ~16 s and a silent panel reads as a hang.
                NSLog("local model gave nothing (%@ @ %@) — claude fallback", model, baseURL)
                onStatus?("\(model) unreachable — asking claude (\(claudeModel))…")
                self.streamViaClaude(prompt: flatPrompt, model: claudeModel,
                                     onChunk: onChunk, onDone: onDone)
            } else {
                onDone("stream interrupted")
            }
        }
        stream.start(url: url, body: [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens,
            "stream": true,
            "ttl": 7200,
        ])
        sse = stream
    }

    private func streamViaClaude(prompt: String, model: String,
                                 onChunk: @escaping (String) -> Void,
                                 onDone: @escaping (String) -> Void) {
        guard let claude = Engine.claudePath else {
            onChunk("No model is available. Install Ollama (ollama.com) and pull a model — TangentBar will find it automatically.")
            onDone("no model available")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        // stream-json + partial messages = true streaming (plain -p flushes
        // mostly at once). --verbose is required with -p + stream-json.
        process.arguments = ["-p", prompt, "--model", model,
                             "--output-format", "stream-json",
                             "--include-partial-messages", "--verbose"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // JSONL parser: text deltas stream as stream_event lines; the final
        // `result` line carries the whole answer — used only if no deltas
        // arrived (older CLI without --include-partial-messages).
        var lineBuffer = Data()
        var sawDelta = false
        func handleLine(_ data: Data) {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { return }
            if type == "stream_event",
               let event = obj["event"] as? [String: Any],
               let delta = event["delta"] as? [String: Any],
               (delta["type"] as? String) == "text_delta",
               let text = delta["text"] as? String, !text.isEmpty {
                sawDelta = true
                DispatchQueue.main.async { onChunk(text) }
            } else if type == "result", !sawDelta,
                      let text = obj["result"] as? String, !text.isEmpty {
                DispatchQueue.main.async { onChunk(text) }
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lineBuffer.append(data)
            while let nl = lineBuffer.firstIndex(of: 0x0A) {
                handleLine(lineBuffer.prefix(upTo: nl))
                lineBuffer = Data(lineBuffer.suffix(from: lineBuffer.index(after: nl)))
            }
        }
        // Drain stderr or a chatty failure (auth errors) fills the 64 KB pipe
        // and wedges the process — the panel would hang on "asking claude…"
        // forever. Keep a short tail so a non-zero exit can say why.
        var errTail = ""
        let errLock = NSLock()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            errLock.lock()
            errTail = String((errTail + s).suffix(300))
            errLock.unlock()
        }
        process.terminationHandler = { p in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            if let tail = try? stdout.fileHandleForReading.readToEnd() ?? Data() {
                lineBuffer.append(tail)
            }
            if !lineBuffer.isEmpty { handleLine(lineBuffer) }  // no trailing \n
            let status = p.terminationStatus
            errLock.lock()
            let err = errTail.trimmingCharacters(in: .whitespacesAndNewlines)
            errLock.unlock()
            DispatchQueue.main.async {
                if status == 0 {
                    onDone("done · \(model) (fallback)")
                } else {
                    if !err.isEmpty { onChunk("[claude error] \(err)") }
                    onDone("model error (exit \(status))")
                }
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            DispatchQueue.main.async {
                onChunk("[error] no local model and could not launch `claude`: \(error.localizedDescription)")
                onDone("transport error")
            }
        }
    }

    func cancel() {
        cancelled = true
        sse?.cancel()
        sse = nil
        process?.terminate()
        process = nil
    }
}
