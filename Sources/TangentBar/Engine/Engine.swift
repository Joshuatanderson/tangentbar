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
        guard let url = URL(string: config.localBaseURL + "/chat/completions") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": config.tangentModel,
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

    func streamTangent(word: String, context: String, config: Config,
                       onChunk: @escaping (String) -> Void,
                       onStatus: ((String) -> Void)? = nil,
                       onDone: @escaping (String) -> Void) {
        stream(system: nil, user: Engine.tangentPrompt(word: word, context: context),
               maxTokens: 300, model: config.tangentModel, baseURL: config.localBaseURL,
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
               config: config, onChunk: onChunk, onStatus: onStatus, onDone: onDone)
    }

    private func stream(system: String?, user: String, maxTokens: Int,
                        model: String, baseURL: String, config: Config,
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
            streamViaClaude(prompt: flatPrompt, model: config.claudeModel, onChunk: onChunk, onDone: onDone)
            return
        }
        let stream = SSEStream(onChunk: onChunk) { [weak self] ok, receivedAny in
            if ok && receivedAny {
                onDone("done · \(model)")
            } else if !receivedAny {
                // A user dismissal also lands here (cancel kills the stream
                // before data) — don't burn a claude call on a closed panel.
                guard let self, !self.cancelled else { return }
                // Local server down or empty — fall back to claude. Say so:
                // claude takes ~16 s and a silent panel reads as a hang.
                NSLog("local model gave nothing (%@ @ %@) — claude fallback", model, baseURL)
                onStatus?("\(model) unreachable — asking claude (\(config.claudeModel))…")
                self.streamViaClaude(prompt: flatPrompt, model: config.claudeModel,
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "-p", prompt, "--model", model]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { onChunk(s) }
        }
        process.terminationHandler = { p in
            stdout.fileHandleForReading.readabilityHandler = nil
            let status = p.terminationStatus
            DispatchQueue.main.async {
                onDone(status == 0 ? "done · \(model) (fallback)" : "model error (exit \(status))")
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
