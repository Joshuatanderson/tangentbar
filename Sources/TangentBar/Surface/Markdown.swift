// Inline markdown for streamed model output: **bold**, *italic*, `code`.
// Parsed with inlineOnlyPreservingWhitespace so newlines survive verbatim —
// full block parsing turns paragraphs into PresentationIntents that need
// manual mapping (D4) and buys little for 2–4 sentence answers.
//
// Streaming strategy (callers): accumulate the raw markdown and re-render the
// whole answer on every chunk — at panel sizes (≤700 tokens) this is cheap,
// and it means a tag split across chunks heals on the next render.

import AppKit

enum Markdown {
    static func render(_ md: String, baseFont: NSFont, color: NSColor) -> NSAttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard let parsed = try? AttributedString(markdown: md, options: options) else {
            return NSAttributedString(string: md, attributes: [.font: baseFont, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var font = baseFont
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
                }
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            }
            out.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        return out
    }
}
