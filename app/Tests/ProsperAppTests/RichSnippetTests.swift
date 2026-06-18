import XCTest
import AppKit
@testable import ProsperApp

/// Covers `RichSnippet` placeholder resolution in RTF: caret positioning when a
/// preceding placeholder changes length, and the plain-text fallback for a body
/// that isn't valid RTF yet.
final class RichSnippetTests: XCTestCase {

    /// Encodes a plain string as an RTF document string (braces survive as escaped
    /// `\{`/`\}`, decoding back to literal braces — i.e. live placeholder tokens).
    private func rtf(_ string: String) -> String {
        let attr = NSAttributedString(string: string,
                                      attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let data = attr.rtf(from: NSRange(location: 0, length: attr.length),
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func testCursorOffsetAccountsForPrecedingPlaceholderLength() {
        var ctx = PlaceholderContext()
        ctx.custom = { name, _ in name == "long" ? "LONGVALUE" : nil }   // 9 chars

        let resolved = RichSnippet.resolve(rtf: rtf("X{long}Y{cursor}Z"), context: ctx)
        XCTAssertNotNil(resolved)
        // "X" + "LONGVALUE" + "Y" + "Z" with the caret between Y and Z.
        XCTAssertEqual(resolved?.plain, "XLONGVALUEYZ")
        // Only "Z" follows the caret → 1 from the end (would be 4 with the old,
        // original-index bug).
        XCTAssertEqual(resolved?.cursorOffsetFromEnd, 1)
    }

    func testPlainBodyFallbackStillExpands() {
        // A snippet flagged rich but whose body isn't valid RTF must still expand.
        let resolved = RichSnippet.resolve(rtf: "Hello {cursor}", context: PlaceholderContext())
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.plain, "Hello ")
        XCTAssertEqual(resolved?.cursorOffsetFromEnd, 0)
        XCTAssertFalse(resolved?.rtfData.isEmpty ?? true, "should re-encode plain body as RTF")
    }

    func testPlainTextProjectionFallsBackToRawString() {
        XCTAssertEqual(RichSnippet.plainText(rtf: "not rtf {date}"), "not rtf {date}")
    }
}
