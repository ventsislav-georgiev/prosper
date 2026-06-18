import XCTest
@testable import ProsperApp

/// Covers `SnippetMatcher`: immediate suffix matching, longest-match on overlap,
/// and word-boundary mode (trailing delimiter + preceding boundary).
final class SnippetMatcherTests: XCTestCase {

    func testImmediateSuffixMatch() {
        let kws = [(trigger: ";;addr", id: "A")]
        let m = SnippetMatcher.match(buffer: "my ;;addr", keywords: kws, wordBoundaryMode: false)
        XCTAssertEqual(m, SnippetMatchResult(id: "A", keywordLength: 6, consumedDelimiter: false))
    }

    func testImmediateNoMatch() {
        let kws = [(trigger: ";;addr", id: "A")]
        XCTAssertNil(SnippetMatcher.match(buffer: "nothing here", keywords: kws, wordBoundaryMode: false))
    }

    func testImmediateLongestWins() {
        let kws = [(trigger: "sig", id: "S"), (trigger: "bigsig", id: "B")]
        let m = SnippetMatcher.match(buffer: "x bigsig", keywords: kws, wordBoundaryMode: false)
        XCTAssertEqual(m?.id, "B")
        XCTAssertEqual(m?.keywordLength, 6)
    }

    func testWordBoundaryFiresAfterDelimiter() {
        let kws = [(trigger: "sig", id: "S")]
        let m = SnippetMatcher.match(buffer: "sig ", keywords: kws, wordBoundaryMode: true)
        XCTAssertEqual(m, SnippetMatchResult(id: "S", keywordLength: 3, consumedDelimiter: true))
    }

    func testWordBoundaryRequiresDelimiter() {
        let kws = [(trigger: "sig", id: "S")]
        XCTAssertNil(SnippetMatcher.match(buffer: "sig", keywords: kws, wordBoundaryMode: true))
    }

    func testWordBoundaryRejectsMidWord() {
        // "essig " ends with "sig " but the char before the keyword ('s') is a word
        // character, so it must not fire.
        let kws = [(trigger: "sig", id: "S")]
        XCTAssertNil(SnippetMatcher.match(buffer: "essig ", keywords: kws, wordBoundaryMode: true))
    }

    func testWordBoundaryAfterBoundaryChar() {
        let kws = [(trigger: "sig", id: "S")]
        XCTAssertEqual(
            SnippetMatcher.match(buffer: "(sig ", keywords: kws, wordBoundaryMode: true)?.id, "S")
        XCTAssertEqual(
            SnippetMatcher.match(buffer: "a sig\n", keywords: kws, wordBoundaryMode: true)?.id, "S")
    }

    func testEmptyInputs() {
        XCTAssertNil(SnippetMatcher.match(buffer: "", keywords: [(";;a", "A")], wordBoundaryMode: false))
        XCTAssertNil(SnippetMatcher.match(buffer: "abc", keywords: [], wordBoundaryMode: false))
    }
}
