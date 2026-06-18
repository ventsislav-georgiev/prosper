import XCTest
@testable import ProsperApp

/// Content typing + backward-compatible decode for the clipboard store
/// (Raycast-parity: link / email / color detection, pin/title fields).
@MainActor
final class ClipboardClassificationTests: XCTestCase {

    func testClassifyLinks() {
        XCTAssertEqual(ClipboardStore.classify("https://example.com"), .link)
        XCTAssertEqual(ClipboardStore.classify("http://a.b/c?d=1#x"), .link)
        XCTAssertEqual(ClipboardStore.classify("  https://example.com  "), .link) // trimmed
        XCTAssertEqual(ClipboardStore.classify("example.com"), .link)
    }

    func testClassifyEmail() {
        XCTAssertEqual(ClipboardStore.classify("user@example.com"), .email)
        XCTAssertEqual(ClipboardStore.classify("first.last+tag@sub.domain.io"), .email)
    }

    func testClassifyColor() {
        XCTAssertEqual(ClipboardStore.classify("#fff"), .color)
        XCTAssertEqual(ClipboardStore.classify("#ff0000"), .color)
        XCTAssertEqual(ClipboardStore.classify("#11223344"), .color)
        XCTAssertEqual(ClipboardStore.classify("#abcd"), .color)
        XCTAssertEqual(ClipboardStore.classify("rgb(255,0,0)"), .color)
        XCTAssertEqual(ClipboardStore.classify("rgba(0,0,0,0.5)"), .color)
        XCTAssertEqual(ClipboardStore.classify("hsl(120, 50%, 50%)"), .color)
    }

    func testClassifyPlainText() {
        XCTAssertEqual(ClipboardStore.classify("hello world"), .text)
        XCTAssertEqual(ClipboardStore.classify(""), .text)
        XCTAssertEqual(ClipboardStore.classify("see https://x.com here"), .text) // not full-span
        XCTAssertEqual(ClipboardStore.classify("#zzz"), .text)                   // not hex
        XCTAssertEqual(ClipboardStore.classify("#ff00f"), .text)                 // wrong hex length (5)
    }

    func testIsColorRejectsBadInput() {
        XCTAssertFalse(ClipboardStore.isColor("#12"))
        XCTAssertFalse(ClipboardStore.isColor("#1234567"))
        XCTAssertFalse(ClipboardStore.isColor("rgb(1,2,3"))   // unclosed
        XCTAssertFalse(ClipboardStore.isColor("notacolor"))
    }

    /// Old `index.json` records predate `pinned`/`title`; decoding must default
    /// them rather than dropping the whole history.
    func testBackwardCompatibleDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","kind":"text","createdAt":0,
         "preview":"hi","byteCount":2,"blobFile":"x.txt"}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(ClipboardItem.self, from: json)
        XCTAssertEqual(item.kind, .text)
        XCTAssertFalse(item.pinned)
        XCTAssertNil(item.title)
        XCTAssertEqual(item.displayTitle, "hi")
    }

    func testDisplayTitlePrefersUserTitle() {
        var item = ClipboardItem(id: UUID(), kind: .text, createdAt: Date(), preview: "raw",
                                 byteCount: 3, blobFile: nil, sourcePath: nil, fileName: nil)
        XCTAssertEqual(item.displayTitle, "raw")
        item.title = "My title"
        XCTAssertEqual(item.displayTitle, "My title")
    }

    /// New text sub-kinds must round-trip and report as textual.
    func testTextualKinds() {
        XCTAssertTrue(ClipboardKind.link.isTextual)
        XCTAssertTrue(ClipboardKind.email.isTextual)
        XCTAssertTrue(ClipboardKind.color.isTextual)
        XCTAssertTrue(ClipboardKind.text.isTextual)
        XCTAssertFalse(ClipboardKind.image.isTextual)
        XCTAssertFalse(ClipboardKind.file.isTextual)
    }
}
