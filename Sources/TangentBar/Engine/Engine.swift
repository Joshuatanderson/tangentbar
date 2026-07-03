// The brain: derives the tangent prompt and streams the answer by shelling
// out to `claude -p` (v1's primary transport). Local/remote HTTP providers
// join later behind the same interface.
//
// v0 note: plain `claude -p` output arrives mostly in one flush; true
// incremental streaming (`--output-format stream-json`) is a checklist item.

import Foundation

final class Engine {
    private var process: Process?

    /// Mirrors v1 tangent.rs: a short, constant dictionary framing; the
    /// grounding context is a snapshot, isolated from any main conversation.
    static func tangentPrompt(word: String, context: String) -> String {
        """
        Define "\(word)" as it is used in the passage below, in 2–4 short \
        sentences. If it is jargon, name the field it comes from. Answer with \
        the definition only — no preamble.

        Passage:
        \(context)
        """
    }

    func streamTangent(word: String, context: String, model: String,
                       onChunk: @escaping (String) -> Void,
                       onDone: @escaping (Int32) -> Void) {
        cancel()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "-p", Engine.tangentPrompt(word: word, context: context),
                             "--model", model]
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
            DispatchQueue.main.async { onDone(p.terminationStatus) }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            DispatchQueue.main.async {
                onChunk("[error] could not launch `claude`: \(error.localizedDescription)")
                onDone(-1)
            }
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
    }
}
