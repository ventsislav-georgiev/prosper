import XCTest
@testable import ProsperApp

/// QA 268: the dictionary parser behind Lexicon.loadFromBundle, on fixture files
/// (xctest's Bundle.main carries no lexicon, so the bundle path never runs here).
final class LexiconLoaderTests: XCTestCase {
    private func write(_ text: String, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testUnigramsAreLowercasedAndMalformedLinesSkipped() throws {
        let dir = tempDir()
        let uni = try write("The 500\nCat 20\nnospace\n 7\ndog x\n", "uni.txt", in: dir)
        let lex = Lexicon.load(unigramURL: uni, bigramURL: nil)
        XCTAssertEqual(lex.frequency, ["the": 500, "cat": 20, "dog": 0])
        XCTAssertEqual(lex.nextWords(after: "the"), [])
    }

    func testBigramsOrderByCountThenWordAndTrimToTheCap() throws {
        let dir = tempDir()
        let uni = try write("the 500\n", "uni.txt", in: dir)
        let bi = try write("""
            The cat 10
            the dog 30
            the ant 10
            the bee 5
            the end
            """, "bi.txt", in: dir)
        let lex = Lexicon.load(unigramURL: uni, bigramURL: bi, maxNextPerHead: 3)
        XCTAssertEqual(lex.nextWords(after: "the"), ["dog", "ant", "cat"])
        let wide = Lexicon.load(unigramURL: uni, bigramURL: bi)
        XCTAssertEqual(wide.nextWords(after: "the"), ["dog", "ant", "cat", "bee"], "the 2-field line is not a bigram")
    }

    /// #1679: the spell classes install this in setUp; it is the real bundled
    /// dictionary, not a fixture, so their verdicts match the shipped app.
    func testBundledLexiconParsesFromTheSourceTree() {
        let lex = Lexicon.bundledFromSources
        XCTAssertGreaterThan(lex.frequency.count, 80_000)
        XCTAssertTrue(lex.isKnownWord("the") && lex.isKnownWord("brown"))
        XCTAssertFalse(lex.isKnownWord("brownfox"))
        XCTAssertEqual(lex.nextWords(after: "the").count, 8)
    }

    func testMissingFilesGiveAnEmptyLexicon() {
        let dir = tempDir()
        let lex = Lexicon.load(unigramURL: dir.appendingPathComponent("none.txt"),
                               bigramURL: dir.appendingPathComponent("none2.txt"))
        XCTAssertEqual(lex.frequency, [:])
        XCTAssertEqual(lex.nextWords(after: "the"), [])
    }
}

/// #1679: xctest's Bundle.main has no lexicon, so the spell classes read the
/// bundled dictionaries from the source tree (parsed once per test process) and
/// install them with Lexicon.store in setUp, restoring the previous one in tearDown.
extension Lexicon {
    static let bundledFromSources: Lexicon = {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/lexicon")
        return load(unigramURL: dir.appendingPathComponent("frequency_dictionary_en_82_765.txt"),
                    bigramURL: dir.appendingPathComponent("frequency_bigramdictionary_en_243_342.txt"))
    }()
}
