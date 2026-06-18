import XCTest
@testable import ProsperApp

/// Covers `QuicklinkStore.resolve`: `{query}` substitution must URL-encode the
/// argument for URL targets, pass it through verbatim for file paths/deeplinks,
/// and handle case variants / missing placeholders.
final class QuicklinkStoreTests: XCTestCase {

    func testURLTargetEncodesQuery() {
        XCTAssertEqual(
            QuicklinkStore.resolve(target: "https://github.com/search?q={query}", query: "a b&c"),
            "https://github.com/search?q=a%20b%26c"
        )
    }

    func testSlashStaysLiteralInPathStyleTargets() {
        // "ql github owner/repo" → github.com/owner/repo, not owner%2Frepo (404).
        XCTAssertEqual(
            QuicklinkStore.resolve(target: "https://github.com/{query}", query: "ventsislav-georgiev/prosper"),
            "https://github.com/ventsislav-georgiev/prosper"
        )
    }

    func testCaseInsensitivePlaceholder() {
        XCTAssertEqual(
            QuicklinkStore.resolve(target: "https://x.com/{Query}", query: "hi"),
            "https://x.com/hi"
        )
    }

    func testArgumentPlaceholder() {
        XCTAssertEqual(
            QuicklinkStore.resolve(target: "https://x.com/{argument}", query: "hi"),
            "https://x.com/hi"
        )
    }

    func testFilePathDoesNotEncode() {
        // No "://" → not a URL → spaces stay literal (the opener handles the path).
        XCTAssertEqual(
            QuicklinkStore.resolve(target: "~/Notes/{query}.md", query: "my note"),
            "~/Notes/my note.md"
        )
    }

    func testNoPlaceholderLeavesTargetUnchanged() {
        XCTAssertEqual(
            QuicklinkStore.resolve(target: "https://example.com", query: "ignored"),
            "https://example.com"
        )
    }

    func testEmptyQuerySubstitutesEmpty() {
        XCTAssertEqual(
            QuicklinkStore.resolve(target: "https://x.com/{query}", query: ""),
            "https://x.com/"
        )
    }

    func testNameMatchesEmptyReturnsNone() {
        // Bare-name launcher must not flood results when the query is empty.
        XCTAssertTrue(QuicklinkStore.nameMatches("").isEmpty)
        XCTAssertTrue(QuicklinkStore.nameMatches("   ").isEmpty)
    }
}
