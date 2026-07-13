// Unit tests for the pure logic: think-tag filtering, word sanitizing,
// word-boundary expansion, prompt derivation, and excerpt focusing.
// No UI, no permissions, no focus stealing — safe to run any time.

import XCTest
@testable import TangentBar

final class FilterThinkTests: XCTestCase {
    private func makeStream() -> SSEStream {
        SSEStream(onChunk: { _ in }, onDone: { _, _ in })
    }

    func testPassesPlainText() {
        let s = makeStream()
        XCTAssertEqual(s.filterThink("hello world"), "hello world")
    }

    func testStripsWholeThinkBlock() {
        let s = makeStream()
        XCTAssertEqual(s.filterThink("<think>secret</think>answer"), "answer")
    }

    func testStripsThinkSplitAcrossChunks() {
        let s = makeStream()
        XCTAssertEqual(s.filterThink("before<thi"), "before")
        XCTAssertEqual(s.filterThink("nk>hidden</th"), "")
        XCTAssertEqual(s.filterThink("ink>after"), "after")
    }

    /// The carry-flush regression (P1 fix): a "<" near a chunk end is held
    /// back as a possible tag opener; when it proves not to be one, it must
    /// still reach the reader.
    func testMathNearEndOfChunkSurvives() {
        let s = makeStream()
        let first = s.filterThink("x <")
        let second = s.filterThink(" y is true")
        XCTAssertEqual(first + second, "x < y is true")
    }
}

final class CleanWordTests: XCTestCase {
    func testObjectReplacementOnlyIsNil() {
        XCTAssertNil(Extractor.cleanWord("\u{FFFC}"))
        XCTAssertNil(Extractor.cleanWord("\u{FFFC}\u{200B}"))
    }

    func testPunctuationOnlyIsNil() {
        XCTAssertNil(Extractor.cleanWord("—…"))
        XCTAssertNil(Extractor.cleanWord("   "))
        XCTAssertNil(Extractor.cleanWord(nil))
    }

    func testStripsInvisiblesButKeepsWord() {
        XCTAssertEqual(Extractor.cleanWord("na\u{200B}tive\u{FFFC}"), "native")
        XCTAssertEqual(Extractor.cleanWord("  tangent  "), "tangent")
    }
}

final class WordAroundTests: XCTestCase {
    func testExpandsToWordBoundaries() {
        let text = "the quick brown fox"
        XCTAssertEqual(Extractor.wordAround(text, offset: 5), "quick")
    }

    func testIncludesApostropheAndHyphen() {
        XCTAssertEqual(Extractor.wordAround("it's self-evident here", offset: 1), "it's")
        XCTAssertEqual(Extractor.wordAround("it's self-evident here", offset: 7), "self-evident")
    }

    func testNonWordOffsetIsNil() {
        XCTAssertNil(Extractor.wordAround("a b", offset: 1))
        XCTAssertNil(Extractor.wordAround("ab", offset: 99))
    }
}

final class TangentPromptTests: XCTestCase {
    func testNoContextIsHonest() {
        let p = Engine.tangentPrompt(word: "tangent", context: "tangent")
        XCTAssertTrue(p.contains("No surrounding context is available"))
        XCTAssertFalse(p.contains("Passage:"))
    }

    func testRealContextBecomesPassage() {
        let ctx = "The conversation drifted onto a tangent about medieval siege engines."
        let p = Engine.tangentPrompt(word: "tangent", context: ctx)
        XCTAssertTrue(p.contains("Passage:"))
        XCTAssertTrue(p.contains(ctx))
    }
}

final class ExcerptTests: XCTestCase {
    func testFocusPadsAndEllipsizes() {
        let source = String(repeating: "a", count: 500) + " NEEDLE " + String(repeating: "b", count: 500)
        let focused = Excerpt.focus(source: source, selection: "NEEDLE")
        XCTAssertTrue(focused.contains("NEEDLE"))
        XCTAssertTrue(focused.hasPrefix("… "))
        XCTAssertTrue(focused.hasSuffix(" …"))
        XCTAssertLessThan(focused.count, source.count)
    }

    func testFocusFallsBackToSelection() {
        let focused = Excerpt.focus(source: nil, selection: "just this")
        XCTAssertEqual(focused, "just this")
    }

    func testTitleCapsAtFirstLine() {
        XCTAssertEqual(Excerpt.title(of: "short line\nsecond"), "short line")
        XCTAssertEqual(Excerpt.title(of: String(repeating: "x", count: 40)).count, 33) // 32 + ellipsis
    }
}

final class ContextWindowTests: XCTestCase {
    func testWindowsAroundLastOccurrence() {
        let text = "first tangent " + String(repeating: "z", count: 1000) + " last tangent tail"
        let window = Extractor.window(around: "tangent", in: text)
        XCTAssertTrue(window.contains("last tangent tail"))
        XCTAssertLessThanOrEqual(window.count, 2 * Extractor.contextRadius + "tangent".count)
    }
}
