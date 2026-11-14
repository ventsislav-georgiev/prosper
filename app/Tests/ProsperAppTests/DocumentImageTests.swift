import AppKit
import XCTest
@testable import ProsperApp

/// #1107 (design #1105 D15). Offscreen only: every view drawn is unwindowed, nothing is shown, ordered
/// or posted, and the only clipboard is Pasteboard.general, the private XCTest pasteboard. The bitmap's
/// bytes (width px x height px x 4) are written beside each drawing; no row draws near the product
/// ceilings: those are exercised through the planner with numbers, or with small ceilings passed in.
@MainActor
final class DocumentImageTests: XCTestCase {

    private struct NotDrawn: Error {}

    /// `count` lines of made-up text, each one paragraph exactly 20 pt high (a fixed line height), short
    /// enough never to wrap in a 200 pt column, no final newline: the laid-out height is count x 20.
    private func fixture(_ count: Int, color: NSColor = .white) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = 20
        para.maximumLineHeight = 20
        return NSAttributedString(string: (1...count).map { "Line \($0) sample" }.joined(separator: "\n"),
                                  attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: para])
    }

    private func render(_ text: NSAttributedString, backing: CGFloat, background: NSColor = .black,
                        appearance: NSAppearance? = nil, maxHeight: Int = DocumentImage.maxHeightPixels,
                        maxArea: Int = DocumentImage.maxAreaPixels, strip: Int = DocumentImage.stripPoints,
                        file: StaticString = #filePath, line: UInt = #line) throws -> (DocumentImage.Image, NSBitmapImageRep) {
        let outcome = DocumentImage.render(text, column: 200, appearance: appearance, background: background, backing: backing,
                                           maxHeight: maxHeight, maxArea: maxArea, strip: strip)
        guard case .image(let image) = outcome else { XCTFail("not drawn: \(outcome)", file: file, line: line); throw NotDrawn() }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: image.png), file: file, line: line)
        XCTAssertEqual(rep.pixelsWide, image.width, file: file, line: line)
        XCTAssertEqual(rep.pixelsHigh, image.height, file: file, line: line)
        return (image, rep)
    }

    private func luminance(_ c: NSColor?) -> CGFloat {
        guard let c = c?.usingColorSpace(.sRGB) else { return -1 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    /// Pixels in rows [from, to) that stand out from the top-left corner (the background).
    private func ink(_ rep: NSBitmapImageRep, rows from: Int, _ to: Int) -> Int {
        let bg = luminance(rep.colorAt(x: 1, y: 1))
        var n = 0
        for y in stride(from: max(0, from), to: min(to, rep.pixelsHigh), by: 1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where abs(luminance(rep.colorAt(x: x, y: y)) - bg) > 0.25 { n += 1 }
        }
        return n
    }

    /// D15 test list 1, and the entry's done-condition: a fixture taller than the window (2,832 pt; the
    /// window is 640 pt) at backing 2 gives exactly the column plus margins times 2 by the laid-out height
    /// plus margins times 2. Bytes: 464 x 5,664 x 4 = 10,512,384 (10.0 MiB), two strips (7.1 and 2.9 MiB).
    func testPixelSizeAtBacking2IsTwiceTheLaidOutSize() throws {
        let (image, _) = try render(fixture(140), backing: 2)
        XCTAssertEqual(image.width, (200 + 2 * 16) * 2)
        XCTAssertEqual(image.height, (140 * 20 + 2 * 16) * 2)
        XCTAssertGreaterThan(140 * 20, 640, "taller than the window")
        XCTAssertNil(image.lines)
        XCTAssertEqual(image.total, 140)
    }

    /// D15 past the ceiling, with small ceilings passed in: 2x when it fits, else 1x, else the top part cut
    /// at a line boundary with the exact words. The fixture is 40 lines, 832 pt with the margins.
    func testFallsBackTo1xThenCutsAtALineBoundary() throws {
        // 2x fits under 2,000 rows. Bytes: 464 x 1,664 x 4 = 3,088,384.
        var (image, rep) = try render(fixture(40), backing: 2, maxHeight: 2_000)
        XCTAssertEqual([image.width, image.height], [464, 1_664])
        // 1,664 rows at 2x are past 1,000: 1x. Bytes: 232 x 832 x 4 = 772,096.
        (image, rep) = try render(fixture(40), backing: 2, maxHeight: 1_000)
        XCTAssertEqual([image.width, image.height], [232, 832])
        XCTAssertNil(image.lines)
        // 832 rows at 1x are past 300: the room for text is 300 - 32 = 268 pt, 13 whole lines (260 pt);
        // the image ends 16 pt below line 13. Bytes: 232 x 292 x 4 = 270,976.
        (image, rep) = try render(fixture(40), backing: 2, maxHeight: 300)
        XCTAssertEqual([image.width, image.height], [232, 292])
        XCTAssertEqual(image.lines, 13)
        XCTAssertEqual(image.total, 40)
        XCTAssertEqual(DocumentImage.cutNotice(lines: 13, of: 40), "Copied lines 1-13 of 40 (image height limit)")
        XCTAssertGreaterThan(ink(rep, rows: 256, 276), 20, "line 13 is drawn")
        XCTAssertEqual(ink(rep, rows: 277, 292), 0, "nothing of line 14 in the bottom margin")
        // The area ceiling alone: 116,000 px at 232 wide is 500 rows: 468 pt of room, 23 lines.
        // Bytes: 232 x 492 x 4 = 456,576.
        (image, rep) = try render(fixture(40), backing: 2, maxHeight: 10_000, maxArea: 232 * 500)
        XCTAssertEqual([image.width, image.height], [232, 492])
        XCTAssertEqual(image.lines, 23)
        // One line taller than the room: cut at the line fragment, and said so. "word " x 300 wraps into
        // about 50 fragments. Bytes: 232 x 292 x 4 = 270,976.
        let long = NSAttributedString(string: String(repeating: "word ", count: 300), attributes: fixture(1).attributes(at: 0, effectiveRange: nil))
        (image, rep) = try render(long, backing: 1, maxHeight: 300)
        XCTAssertEqual(image.lines, 0)
        XCTAssertEqual(image.height, 292)
        XCTAssertEqual(DocumentImage.cutNotice(lines: 0, of: 1), "Copied part of line 1 of 1 (image height limit)")
        // D15's own numbers, grouped by thousands.
        XCTAssertEqual(DocumentImage.cutNotice(lines: 1_475, of: 5_000), "Copied lines 1-1,475 of 5,000 (image height limit)")
        XCTAssertEqual(DocumentImage.copiedNotice(width: 1_520, height: 24_800), "Copied image (1,520 × 24,800 px)")
        XCTAssertEqual(DocumentImage.copiedNotice(width: 760, height: 1_000_000), "Copied image (760 × 1,000,000 px)")
    }

    /// D15 strips: the first and last strips both hold text pixels, and the strips drawn 100 pt at a time
    /// (boundaries through lines 5, 10, ...) give the same pixels as one pass: no blank strip, none drawn
    /// twice or out of place. Bytes: 464 x 1,664 x 4 = 3,088,384, twice.
    func testStripsMatchOnePassDrawing() throws {
        let (_, strips) = try render(fixture(40), backing: 2, strip: 100)
        let (_, whole) = try render(fixture(40), backing: 2, strip: 10_000)
        XCTAssertEqual([strips.pixelsWide, strips.pixelsHigh], [whole.pixelsWide, whole.pixelsHigh])
        XCTAssertGreaterThan(ink(strips, rows: 0, 200), 50, "first strip")
        XCTAssertGreaterThan(ink(strips, rows: 1_600, 1_664), 50, "last strip")
        XCTAssertEqual(strips.bytesPerRow, whole.bytesPerRow)
        // R1107-4: the same guard: never read past the shorter buffer.
        guard strips.bytesPerRow == whole.bytesPerRow, strips.pixelsHigh == whole.pixelsHigh else { return }
        let a = try XCTUnwrap(strips.bitmapData), b = try XCTUnwrap(whole.bitmapData)
        let count = strips.bytesPerRow * strips.pixelsHigh
        var differ = 0
        for i in 0..<count where abs(Int(a[i]) - Int(b[i])) > 8 { differ += 1 }
        XCTAssertLessThanOrEqual(differ, count / 1_000, "\(differ) of \(count) bytes differ from one pass")
    }

    /// D15: the appearance and the window's Neon surface colour, light and dark; the background is filled
    /// and opaque. Bytes: 232 x 232 x 4 = 215,296, twice.
    func testDarkAppearanceGivesDarkBackground() throws {
        _ = ThemeStore.shared   // its first use publishes the stored theme; touch it before pinning ours
        let saved = ThemeRuntime.palette
        defer { ThemeRuntime.palette = saved }
        for dark in [true, false] {
            ThemeRuntime.palette = dark ? saved : AgentWindowD1Tests.lightPalette
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let (_, rep) = try render(fixture(10, color: MarkdownRenderer.Style.current.text.color), backing: 1,
                                      background: DocumentImage.surface, appearance: appearance)
            let corner = rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB)
            XCTAssertEqual(luminance(corner) < 0.5, dark, "\(dark ? "dark" : "light"): \(luminance(corner))")
            XCTAssertEqual(corner?.alphaComponent ?? 0, 1, accuracy: 0.01, "the background is filled, opaque")
            XCTAssertGreaterThan(ink(rep, rows: 16, 216), 50, "text drawn on it")
        }
    }

    /// R1107-1: a link is drawn as the renderer styled it (as in the window), not in AppKit's default link blue
    /// and underline: the same text with and without a .link ("#top", never followed: nothing here opens a
    /// link) over a range with the same colour gives the same pixels. Bytes: 232 x 92 x 4 = 85,376, twice.
    func testLinksDrawAsTheirOwnAttributes() throws {
        let plain = NSMutableAttributedString(attributedString: fixture(3))
        let linked = NSMutableAttributedString(attributedString: plain)
        linked.addAttribute(.link, value: "#top", range: NSRange(location: 0, length: 6))
        let (_, a) = try render(plain, backing: 1)
        let (_, b) = try render(linked, backing: 1)
        XCTAssertEqual([a.pixelsWide, a.pixelsHigh], [232, 92])
        XCTAssertEqual([b.pixelsWide, b.pixelsHigh], [a.pixelsWide, a.pixelsHigh])
        XCTAssertEqual(a.bytesPerRow, b.bytesPerRow)
        // R1107-4: the asserts above do not stop the row; the loop below must never read past b's buffer.
        guard a.bytesPerRow == b.bytesPerRow, a.pixelsHigh == b.pixelsHigh else { return }
        let pa = try XCTUnwrap(a.bitmapData), pb = try XCTUnwrap(b.bitmapData)
        let count = a.bytesPerRow * a.pixelsHigh
        var differ = 0
        for i in 0..<count where abs(Int(pa[i]) - Int(pb[i])) > 8 { differ += 1 }
        XCTAssertLessThanOrEqual(differ, count / 1_000, "\(differ) of \(count) bytes differ: a link style was drawn")
        XCTAssertGreaterThan(ink(a, rows: 16, 36), 20, "line 1 is drawn")
    }

    /// R1107-3: an image in the text (an 8 x 8 solid red NSImage made here, shown at 64 x 64 pt; no file, nothing
    /// fetched) is drawn where it is laid out, and the image height includes it: line 1, the image, line 3.
    /// Bytes: 232 x about 140 (16 + 20 + about 68 + 20 + 16) x 4 = about 130,000; under 232 x 1,000 x 4 = 928,000.
    func testAttachmentIsDrawnAndCounted() throws {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let square = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            red.setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = square
        attachment.bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        let attrs = fixture(1).attributes(at: 0, effectiveRange: nil)
        let text = NSMutableAttributedString(string: "Above the image\n", attributes: attrs)
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: "\nBelow the image", attributes: attrs))
        let (image, rep) = try render(text, backing: 1)
        XCTAssertEqual(image.width, 232)
        XCTAssertGreaterThanOrEqual(image.height, 20 + 64 + 20 + 32, "the image's line is counted")
        var reds = 0, top = Int.max, bottom = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.redComponent > 0.8, c.greenComponent < 0.2, c.blueComponent < 0.2 else { continue }
                reds += 1
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        XCTAssertGreaterThan(reds, 64 * 64 * 8 / 10, "the attachment is drawn (\(reds) red pixels)")
        guard reds > 0 else { return }   // top/bottom unset: their difference would overflow
        XCTAssertGreaterThanOrEqual(top, 16 + 20, "below line 1")
        XCTAssertEqual(bottom - top + 1, 64, accuracy: 2, "64 pt tall at 1x")
        XCTAssertLessThanOrEqual(bottom, image.height - 16 - 20, "above line 3")
    }

    /// D15 ceilings through the planner alone (pure: it allocates nothing, so "before allocation" is the
    /// planner's answer itself; the renderer creates its bitmap only from a plan). D15's numbers and the
    /// edges of both ceilings, as a literal table.
    func testPlannerChecksTheCeilingsBeforeAllocation() {
        typealias P = DocumentImage.Plan
        let rows: [(Double, Double, Double, P?)] = [
            (760, 12_400, 2, P(scale: 2, width: 1_520, height: 24_800, cut: false)),     // D15's notice example
            (760, 111_018, 2, P(scale: 1, width: 760, height: 32_767, cut: true)),       // the probe's 5,000 lines
            (760, 16_383.5, 2, P(scale: 2, width: 1_520, height: 32_767, cut: false)),   // height exactly at 2x
            (760, 16_384, 2, P(scale: 1, width: 760, height: 16_384, cut: false)),       // one row over at 2x
            (760, 32_767, 1, P(scale: 1, width: 760, height: 32_767, cut: false)),
            (760, 32_768, 1, P(scale: 1, width: 760, height: 32_767, cut: true)),
            (2_000, 15_000, 2, P(scale: 1, width: 2_000, height: 15_000, cut: false)),   // 120 MP at 2x, 30 at 1x
            (5_000, 10_000, 1, P(scale: 1, width: 5_000, height: 10_000, cut: false)),   // area exactly 50 MP
            (5_000, 10_001, 1, P(scale: 1, width: 5_000, height: 10_000, cut: true)),    // area one row over
            (5_000, 10_000, 2, P(scale: 1, width: 5_000, height: 10_000, cut: false)),
            (100.5, 10.25, 2, P(scale: 2, width: 201, height: 21, cut: false)),          // rounded up, whole pixels
            (100, 100, 3, P(scale: 3, width: 300, height: 300, cut: false)),
            (60_000_000, 10, 1, nil),                                                    // not one row within 50 MP
        ]
        for (w, h, backing, expected) in rows {
            XCTAssertEqual(DocumentImage.plan(width: w, height: h, backing: backing), expected, "\(w) x \(h) @\(backing)")
        }
        // Small ceilings passed in.
        XCTAssertEqual(DocumentImage.plan(width: 10, height: 30, backing: 2, maxHeight: 50, maxArea: 1_000),
                       P(scale: 1, width: 10, height: 30, cut: false))
        XCTAssertEqual(DocumentImage.plan(width: 10, height: 300, backing: 2, maxHeight: 50, maxArea: 1_000),
                       P(scale: 1, width: 10, height: 50, cut: true))
        XCTAssertEqual(DocumentImage.plan(width: 10, height: 300, backing: 1, maxHeight: 500, maxArea: 1_000),
                       P(scale: 1, width: 10, height: 100, cut: true))
    }

    /// Item 2: hostile layout sizes are "nothing to copy", checked before any Int conversion or product;
    /// a hostile backing scale is 1; hostile ceilings refuse. A literal table.
    func testHostileSizesGiveNothingToCopy() {
        let sizes: [(Double, Double)] = [
            (.nan, 100), (100, .nan), (.infinity, 100), (100, .infinity), (-.infinity, 100), (100, -.infinity),
            (0, 100), (100, 0), (-0.0, 100), (-1, 100), (100, -5), (1e12, 100), (100, 1e12), (1_000_000_001, 1),
            (.greatestFiniteMagnitude, 100), (100, .greatestFiniteMagnitude), (.signalingNaN, 100),
        ]
        for (w, h) in sizes {
            XCTAssertTrue(DocumentImage.plan(width: w, height: h, backing: 2) == nil, "\(w) x \(h)")
        }
        let one = DocumentImage.Plan(scale: 1, width: 100, height: 100, cut: false)
        for backing: Double in [.nan, .infinity, -.infinity, 0, -2, 0.5, 5, 1e9] {
            XCTAssertEqual(DocumentImage.plan(width: 100, height: 100, backing: backing), one, "backing \(backing)")
        }
        for (maxHeight, maxArea) in [(0, 1_000), (-1, 1_000), (Int.min, 1_000), (100, 0), (100, -1), (100, Int.min)] {
            XCTAssertTrue(DocumentImage.plan(width: 10, height: 10, backing: 1, maxHeight: maxHeight, maxArea: maxArea) == nil,
                          "\(maxHeight), \(maxArea)")
        }
        for column: CGFloat in [.nan, .infinity, -.infinity, 0, -5, 1e12] {
            guard case .failed = DocumentImage.render(fixture(2), column: column, appearance: nil, background: .black, backing: 2)
            else { XCTFail("column \(column) was drawn"); continue }
        }
    }

    /// D15 clipboard: ONE item, public.png only, on Pasteboard.general (the private test pasteboard); an
    /// empty document or a failure leaves the clipboard as it was. Bytes: 464 x 464 x 4 = 861,184.
    func testWriteIsOnePNGItemOnTheTestPasteboard() throws {
        let pb = Pasteboard.general
        XCTAssertTrue(pb.name.rawValue.hasPrefix("eu.illegible.prosper.xctest"), "the private test pasteboard")
        pb.clearContents()
        pb.setString("before", forType: .string)
        let said = DocumentImage.copy(fixture(10), column: 200, appearance: nil, background: .black, backing: 2, to: pb)
        XCTAssertEqual(said, "Copied image (464 × 464 px)")
        // The item holds PNG data only. pb.types also lists what the pasteboard server can translate it to on a
        // reader's request (Apple PNG, public.tiff, NeXT TIFF: ticket 1), which this code does not write.
        XCTAssertEqual(pb.pasteboardItems?.count, 1)
        XCTAssertEqual(pb.pasteboardItems?.first?.types, [.png])
        XCTAssertEqual(pb.types?.first, .png)
        let rep = try XCTUnwrap(pb.data(forType: .png).flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual([rep.pixelsWide, rep.pixelsHigh], [464, 464])

        // Nothing written: the empty document, a hostile column, ceilings that refuse every row.
        let refused: [(NSAttributedString, CGFloat, Int, String)] = [
            (NSAttributedString(string: ""), 200, DocumentImage.maxAreaPixels, DocumentImage.emptyNotice),
            (fixture(10), .nan, DocumentImage.maxAreaPixels, DocumentImage.failedNotice),
            (fixture(10), 200, 100, DocumentImage.failedNotice),
        ]
        for (text, column, maxArea, notice) in refused {
            pb.clearContents()
            pb.setString("before", forType: .string)
            XCTAssertEqual(DocumentImage.copy(text, column: column, appearance: nil, background: .black, backing: 2, to: pb,
                                              maxArea: maxArea), notice)
            XCTAssertEqual(pb.pasteboardItems?.count, 1, notice)
            XCTAssertEqual(pb.pasteboardItems?.first?.types, [.string], notice)
            XCTAssertEqual(pb.string(forType: .string), "before", notice)
        }
    }
}
