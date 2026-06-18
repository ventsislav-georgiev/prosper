import XCTest
@testable import ProsperApp

/// Covers `SnippetStore`'s pure helpers (no UserDefaults side effects): keyword
/// sanitation (delimiter rules) and collection-affix trigger composition.
final class SnippetStoreTests: XCTestCase {

    func testSanitizeKeywordStripsWhitespaceAndQuotes() {
        XCTAssertEqual(SnippetStore.sanitizeKeyword("  ;;addr  "), ";;addr")
        XCTAssertEqual(SnippetStore.sanitizeKeyword("my email"), "myemail")     // space is a delimiter
        XCTAssertEqual(SnippetStore.sanitizeKeyword("it's"), "its")             // apostrophe stripped
        XCTAssertEqual(SnippetStore.sanitizeKeyword("a\"b"), "ab")              // quote stripped
        XCTAssertEqual(SnippetStore.sanitizeKeyword("   "), "")
    }

    func testEffectiveTriggerAppliesAffixes() {
        let collections = ["Personal": (prefix: ";;", suffix: "")]
        XCTAssertEqual(
            SnippetStore.effectiveTrigger(keyword: "addr", collection: "Personal", collections: collections),
            ";;addr")
    }

    func testEffectiveTriggerPrefixAndSuffix() {
        let collections = ["Tag": (prefix: "<", suffix: ">")]
        XCTAssertEqual(
            SnippetStore.effectiveTrigger(keyword: "br", collection: "Tag", collections: collections),
            "<br>")
    }

    func testEffectiveTriggerUnknownCollectionIsBareKeyword() {
        XCTAssertEqual(
            SnippetStore.effectiveTrigger(keyword: "sig", collection: "Nope", collections: [:]),
            "sig")
    }
}
