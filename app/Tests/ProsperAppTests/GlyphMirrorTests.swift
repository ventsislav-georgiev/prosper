import AppKit
import XCTest
@testable import ProsperApp

/// A1 tier-3 glyph-mirror caret geometry. `currentLine` extraction is pure string
/// logic; `caretRect` is exercised for its structural invariants (a real caret
/// origin inside the field, advancing with more text) without asserting pixel
/// values, which depend on the font metrics of the test host.
@MainActor
final class GlyphMirrorTests: XCTestCase {

    func testCurrentLineTakesTextAfterLastNewline() {
        XCTAssertEqual(GlyphMirror.currentLine(of: "first line\nsecond line"), "second line")
        XCTAssertEqual(GlyphMirror.currentLine(of: "no newline here"), "no newline here")
        XCTAssertEqual(GlyphMirror.currentLine(of: "trailing\n"), "")
    }

    func testCurrentLineCaps() {
        let long = String(repeating: "a", count: 5000)
        XCTAssertEqual(GlyphMirror.currentLine(of: long, maxChars: 100).count, 100)
    }

    func testCaretRectAdvancesWithText() {
        let font = NSFont.systemFont(ofSize: 14)
        let field = CGRect(x: 100, y: 200, width: 400, height: 30)
        guard let shortR = GlyphMirror.caretRect(lineBefore: "hi", font: font, fieldRect: field),
              let longR = GlyphMirror.caretRect(lineBefore: "hi there friend", font: font, fieldRect: field)
        else { return XCTFail("expected caret rects") }
        // Caret x sits at/after the field origin and advances as the line grows.
        XCTAssertGreaterThanOrEqual(shortR.minX, field.minX)
        XCTAssertGreaterThan(longR.minX, shortR.minX)
        // Clamped to the field's right edge.
        XCTAssertLessThanOrEqual(longR.minX, field.maxX)
    }

    /// Guards the reused TextKit scratch stack: a short line measured AFTER a long
    /// one must not retain the long line's glyphs (stale-state regression).
    func testCaretRectShrinksAfterLongerLine() {
        let font = NSFont.systemFont(ofSize: 14)
        let field = CGRect(x: 100, y: 200, width: 400, height: 30)
        guard let longR = GlyphMirror.caretRect(lineBefore: "hi there friend", font: font, fieldRect: field),
              let shortR = GlyphMirror.caretRect(lineBefore: "hi", font: font, fieldRect: field)
        else { return XCTFail("expected caret rects") }
        XCTAssertLessThan(shortR.minX, longR.minX)
    }

    /// Reuse must be deterministic: identical input yields an identical rect.
    func testCaretRectIsIdempotent() {
        let font = NSFont.systemFont(ofSize: 14)
        let field = CGRect(x: 100, y: 200, width: 400, height: 30)
        guard let a = GlyphMirror.caretRect(lineBefore: "sample text", font: font, fieldRect: field),
              let b = GlyphMirror.caretRect(lineBefore: "sample text", font: font, fieldRect: field)
        else { return XCTFail("expected caret rects") }
        XCTAssertEqual(a.minX, b.minX, accuracy: 0.01)
        XCTAssertEqual(a.minY, b.minY, accuracy: 0.01)
    }

    func testCaretRectEmptyLineAtLeadingEdge() {
        let font = NSFont.systemFont(ofSize: 14)
        let field = CGRect(x: 100, y: 200, width: 400, height: 30)
        guard let r = GlyphMirror.caretRect(lineBefore: "", font: font, fieldRect: field)
        else { return XCTFail("expected caret rect for empty line") }
        XCTAssertEqual(r.minX, field.minX, accuracy: 0.5)
    }

    func testCaretRectRejectsDegenerateField() {
        let font = NSFont.systemFont(ofSize: 14)
        XCTAssertNil(GlyphMirror.caretRect(lineBefore: "x", font: font, fieldRect: .zero))
    }
}
