// Ported from v1 explore.rs: the grounding excerpt for a selection chat, the
// breadcrumb title, and the stateless per-turn prompt replay. The system
// framing stays byte-identical across calls so a local server reuses its KV
// cache; only the excerpt + conversation vary.

import Foundation

enum Excerpt {
    static let system = "You are a focused assistant exploring a highlighted excerpt from a conversation. Treat the excerpt as the primary context and answer the user's questions about it directly and concisely."

    /// Characters of context kept on each side of the highlighted selection.
    static let pad = 160

    struct Turn {
        enum Role { case user, assistant }
        let role: Role
        let content: String
    }

    /// The highlighted `selection` plus up to `pad` chars each side of where it
    /// sits in `source`, ellipsized when trimmed. Falls back to the (capped)
    /// selection alone when it can't be located.
    static func focus(source: String?, selection: String) -> String {
        let selection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              let at = source.range(of: selection) else {
            return cap(selection, 2 * pad)
        }
        let start = source.index(at.lowerBound, offsetBy: -pad, limitedBy: source.startIndex) ?? source.startIndex
        let stop = source.index(at.upperBound, offsetBy: pad, limitedBy: source.endIndex) ?? source.endIndex
        var out = ""
        if start > source.startIndex { out += "… " }
        out += source[start..<stop].trimmingCharacters(in: .whitespacesAndNewlines)
        if stop < source.endIndex { out += " …" }
        return out
    }

    /// A short breadcrumb title from the selection — first line, ≤32 chars.
    static func title(of selection: String) -> String {
        let firstLine = selection.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return cap(firstLine, 32)
    }

    /// The user message for the next turn — replays the excerpt and the Q&A so
    /// far, since the transports are stateless. The latest user message is the
    /// last entry in `history`.
    static func prompt(excerpt: String, history: [Turn]) -> String {
        var prompt = "Excerpt:\n\"\"\"\n\(excerpt)\n\"\"\"\n\nConversation:\n"
        for turn in history {
            prompt += (turn.role == .assistant ? "Assistant: " : "User: ") + turn.content + "\n"
        }
        prompt += "\nAnswer the latest message concisely, grounded in the excerpt."
        return prompt
    }

    private static func cap(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }
}
