// Minimal SSE client for OpenAI-compatible /chat/completions streaming
// (LM Studio, Ollama's OpenAI shim). Parses `data:` lines, surfaces content
// deltas, and defensively strips <think>…</think> reasoning blocks that some
// qwen builds emit inline.

import Foundation

final class SSEStream: NSObject, URLSessionDataDelegate {
    private var buffer = Data()
    private let onChunk: (String) -> Void
    private let onDone: (Bool, Bool) -> Void  // (success, receivedAnything)
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var receivedAny = false
    private var insideThink = false
    private var carry = ""  // partial tag straddling a chunk boundary

    init(onChunk: @escaping (String) -> Void, onDone: @escaping (Bool, Bool) -> Void) {
        self.onChunk = onChunk
        self.onDone = onDone
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start(url: URL, body: [String: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        task = session.dataTask(with: request)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newline)
            buffer = Data(buffer.suffix(from: buffer.index(after: newline)))
            guard let line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespaces), line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let json = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String, !content.isEmpty else { continue }
            let visible = filterThink(content)
            guard !visible.isEmpty else { continue }
            receivedAny = true
            DispatchQueue.main.async { self.onChunk(visible) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let ok = error == nil
        let got = receivedAny
        DispatchQueue.main.async { self.onDone(ok, got) }
    }

    /// Stateful strip of <think>…</think>; tolerates tags split across chunks.
    private func filterThink(_ chunk: String) -> String {
        var text = carry + chunk
        carry = ""
        var out = ""
        while !text.isEmpty {
            if insideThink {
                if let end = text.range(of: "</think>") {
                    text = String(text[end.upperBound...])
                    insideThink = false
                } else {
                    return out  // still thinking; drop the rest
                }
            } else if let start = text.range(of: "<think>") {
                out += text[..<start.lowerBound]
                text = String(text[start.upperBound...])
                insideThink = true
            } else {
                // Hold back a possible partial tag at the tail.
                if let lt = text.lastIndex(of: "<"), text.distance(from: lt, to: text.endIndex) < 8 {
                    out += text[..<lt]
                    carry = String(text[lt...])
                } else {
                    out += text
                }
                text = ""
            }
        }
        return out
    }
}
