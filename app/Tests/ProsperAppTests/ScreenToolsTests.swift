import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Vision
import XCTest
@testable import ProsperApp

/// Screen tools helpers: barcode decode, reading order, the flipped-view →
/// CoreGraphics-global conversion, URL safety and selection geometry.
///
/// Vision is headless-testable: a `CGImage` built in memory needs no Screen
/// Recording grant, no window-server session and no checked-in fixture binaries.
final class ScreenToolsTests: XCTestCase {

    // MARK: - 1. QR round-trip, no fixture file

    func testBarcodeDetectorReadsGeneratedQRCode() throws {
        let payload = "https://prosper.test/x"
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        let output = try XCTUnwrap(filter.outputImage)
        // The generator emits one pixel per module; Vision needs something bigger.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let image = try XCTUnwrap(CIContext().createCGImage(scaled, from: scaled.extent))

        let reading = try XCTUnwrap(BarcodeDetector.read(image))
        XCTAssertEqual(reading.payload, payload)
        XCTAssertEqual(reading.url?.absoluteString, payload)
    }

    func testBarcodeDetectorReturnsNilOnBlankImage() throws {
        let context = try XCTUnwrap(CGContext(data: nil,
                                              width: 200,
                                              height: 200,
                                              bitsPerComponent: 8,
                                              bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertNil(BarcodeDetector.read(image))
    }

    // MARK: - 2. OCR round-trip, no fixture file

    /// Draws text with CoreText into an in-memory bitmap and reads it back through
    /// Vision. No permission, no window server, no fixture on disk.
    private func textImage(_ string: String) throws -> CGImage {
        let width = 900
        let height = 240
        let context = try XCTUnwrap(CGContext(data: nil,
                                              width: width,
                                              height: height,
                                              bitsPerComponent: 8,
                                              bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // CoreText draws in the context's fill color when the string carries no
        // foreground-color attribute — so set black AFTER painting the page white.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let font = CTFontCreateWithName("Helvetica" as CFString, 120, nil)
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: 70)
        CTLineDraw(line, context)

        return try XCTUnwrap(context.makeImage())
    }

    func testVisionOCRReadsTextDrawnIntoABitmap() async throws {
        let image = try textImage("HELLO 42")
        let lines = await VisionOCR.recognizeLines(in: image)
        let text = ScreenToolsSupport.joinedRecognizedText(lines)
        XCTAssertTrue(text.contains("HELLO"), "OCR read \(text.debugDescription)")
    }

    /// The `.fast` retry the screen-tools pipeline falls back to. Same bitmap, so this
    /// pins the defaulted `level:` parameter against a signature change.
    func testVisionOCRFastLevelReadsTheSameBitmap() async throws {
        let image = try textImage("HELLO 42")
        let lines = await VisionOCR.recognizeLines(in: image, level: .fast)
        let text = ScreenToolsSupport.joinedRecognizedText(lines)
        XCTAssertTrue(text.contains("HELLO"), "OCR read \(text.debugDescription)")
    }

    // MARK: - 3. Reading order

    func testJoinedRecognizedTextSortsTopDownThenLeftToRight() {
        // Vision's own order is deliberately scrambled here; y is bottom-left
        // origin, so the LARGEST midY is the topmost row.
        let lines = [
            OCRLine(text: "second-right", boundingBox: CGRect(x: 0.60, y: 0.50, width: 0.2, height: 0.04)),
            OCRLine(text: "top", boundingBox: CGRect(x: 0.10, y: 0.90, width: 0.2, height: 0.04)),
            OCRLine(text: "second-left", boundingBox: CGRect(x: 0.10, y: 0.50, width: 0.2, height: 0.04)),
            OCRLine(text: "   ", boundingBox: CGRect(x: 0.10, y: 0.30, width: 0.2, height: 0.04)),
            OCRLine(text: "bottom", boundingBox: CGRect(x: 0.10, y: 0.10, width: 0.2, height: 0.04)),
        ]
        XCTAssertEqual(ScreenToolsSupport.joinedRecognizedText(lines),
                       "top\nsecond-left\nsecond-right\nbottom")
    }

    func testJoinedRecognizedTextIsEmptyForBlankLines() {
        let lines = [OCRLine(text: "", boundingBox: CGRect(x: 0, y: 0.5, width: 0.1, height: 0.1)),
                     OCRLine(text: "\n  ", boundingBox: CGRect(x: 0, y: 0.4, width: 0.1, height: 0.1))]
        XCTAssertEqual(ScreenToolsSupport.joinedRecognizedText(lines), "")
    }

    // MARK: - 4. Flipped view → CoreGraphics global

    func testGlobalCGRectOnPrimaryDisplay() {
        // Primary: 1920x1080 at the Cocoa origin, so primaryTop == 1080.
        let rect = ScreenToolsSupport.globalCGRect(
            fromViewRect: CGRect(x: 100, y: 200, width: 300, height: 150),
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            primaryTop: 1080)
        XCTAssertEqual(rect, CGRect(x: 100, y: 200, width: 300, height: 150))
    }

    func testGlobalCGRectOnDisplayBelowAndRightOfPrimary() {
        // Secondary hangs below-right: Cocoa frame (1920, -900, 1600, 900).
        let rect = ScreenToolsSupport.globalCGRect(
            fromViewRect: CGRect(x: 10, y: 20, width: 100, height: 50),
            screenFrame: CGRect(x: 1920, y: -900, width: 1600, height: 900),
            primaryTop: 1080)
        // x: 1920 + 10. y: (1080 - 0) + 20 — the secondary's top edge sits exactly
        // at the primary's bottom, i.e. 1080 points below the CG origin.
        XCTAssertEqual(rect, CGRect(x: 1930, y: 1100, width: 100, height: 50))
    }

    /// The regression that motivates the whole helper: a display arranged ABOVE
    /// the primary. `primaryTop` must be `NSScreen.screens[0].frame.maxY` (1080),
    /// NOT `screens.map(\.frame.maxY).max()` (2160) — the `max` form yields
    /// y == 20 here, placing the capture on the primary instead of above it.
    func testGlobalCGRectOnDisplayAbovePrimaryUsesPrimaryTopNotMaxTop() {
        let screenFrame = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let viewRect = CGRect(x: 10, y: 20, width: 100, height: 50)

        let correct = ScreenToolsSupport.globalCGRect(fromViewRect: viewRect,
                                                      screenFrame: screenFrame,
                                                      primaryTop: 1080)
        XCTAssertEqual(correct, CGRect(x: 10, y: -1060, width: 100, height: 50))

        // What the max(maxY) form would have produced, kept as the counter-example.
        let buggyPrimaryTop = [CGRect(x: 0, y: 0, width: 1920, height: 1080), screenFrame]
            .map(\.maxY).max() ?? 0
        let buggy = ScreenToolsSupport.globalCGRect(fromViewRect: viewRect,
                                                    screenFrame: screenFrame,
                                                    primaryTop: buggyPrimaryTop)
        XCTAssertEqual(buggy.minY, 20)
        XCTAssertNotEqual(buggy, correct)
    }

    // MARK: - 5. cgRegion / cgRegionAbove screen layouts

    /// `VisionContext.cgRegion` / `cgRegionAbove` are private, thin NSScreen
    /// wrappers around `ScreenToolsSupport.cgRegion` / `cgRegionAbove` — the same
    /// pad+flip math with `primaryTop` injected, so every screen arrangement is
    /// exercised here without a real NSScreen. Frames are Cocoa (bottom-left
    /// origin, y up); the primary is always 1920x1080 at the Cocoa origin
    /// (primaryTop == 1080) — AppKit guarantees `screens[0]` is the primary
    /// regardless of how many/which secondaries exist or where they sit.
    private let primaryFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// A caret on the primary produces the identical region in every layout
    /// below — secondaries elsewhere must never perturb a primary-side capture.
    private let primaryCaretRegion = CGRect(x: 460, y: 552, width: 82, height: 40)

    private func cgRegionOnPrimary(primaryTop: CGFloat = 1080) -> CGRect {
        // padX 40 / padY 12 matches `averageColorAroundCaret`'s real call.
        ScreenToolsSupport.cgRegion(around: CGRect(x: 500, y: 500, width: 2, height: 16),
                                    padX: 40, padY: 12, primaryTop: primaryTop)
    }

    func testCgRegionPrimaryOnlyLayout() {
        XCTAssertEqual(cgRegionOnPrimary(), primaryCaretRegion)
    }

    /// The bug case: a secondary display arranged directly ABOVE the primary.
    /// The old `screens.map(\.frame.maxY).max()` form (2160) puts the captured
    /// region on the PRIMARY; the fixed, primary-anchored form (1080) puts it
    /// on the secondary, where the caret actually is.
    func testCgRegionSecondaryAbovePrimaryLandsOnSecondaryNotPrimary() {
        let secondary = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let primaryTop = primaryFrame.maxY // == NSScreen.screens[0].frame.maxY == 1080

        XCTAssertEqual(cgRegionOnPrimary(primaryTop: primaryTop), primaryCaretRegion)

        let caretOnSecondary = CGRect(x: 500, y: 1600, width: 2, height: 16)
        let region = ScreenToolsSupport.cgRegion(around: caretOnSecondary, padX: 40, padY: 12,
                                                 primaryTop: primaryTop)
        XCTAssertEqual(region, CGRect(x: 460, y: -548, width: 82, height: 40))

        // CG bounds of each display, derived the same primary-anchored way.
        let primaryCGBounds = CGRect(x: primaryFrame.minX,
                                     y: ScreenToolsSupport.flippedY(primaryFrame.maxY, primaryTop: primaryTop),
                                     width: primaryFrame.width, height: primaryFrame.height)
        let secondaryCGBounds = CGRect(x: secondary.minX,
                                       y: ScreenToolsSupport.flippedY(secondary.maxY, primaryTop: primaryTop),
                                       width: secondary.width, height: secondary.height)
        XCTAssertTrue(secondaryCGBounds.contains(region), "expected \(region) inside secondary \(secondaryCGBounds)")
        XCTAssertFalse(primaryCGBounds.contains(region), "region must not land back on the primary")

        // What the buggy `max` form would have produced, kept as the counter-example.
        let buggyTop = [primaryFrame, secondary].map(\.maxY).max() ?? 0
        XCTAssertEqual(buggyTop, 2160)
        let buggyRegion = ScreenToolsSupport.cgRegion(around: caretOnSecondary, padX: 40, padY: 12,
                                                       primaryTop: buggyTop)
        XCTAssertEqual(buggyRegion, CGRect(x: 460, y: 532, width: 82, height: 40))
        XCTAssertTrue(primaryCGBounds.contains(buggyRegion), "the bug: region lands on the primary instead")
        XCTAssertNotEqual(buggyRegion, region)
    }

    func testCgRegionSecondaryBelowPrimaryLandsOnSecondary() {
        let secondary = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        let primaryTop = primaryFrame.maxY

        XCTAssertEqual(cgRegionOnPrimary(primaryTop: primaryTop), primaryCaretRegion)

        let caretOnSecondary = CGRect(x: 500, y: -500, width: 2, height: 16)
        let region = ScreenToolsSupport.cgRegion(around: caretOnSecondary, padX: 40, padY: 12,
                                                 primaryTop: primaryTop)
        XCTAssertEqual(region, CGRect(x: 460, y: 1552, width: 82, height: 40))

        let secondaryCGBounds = CGRect(x: secondary.minX,
                                       y: ScreenToolsSupport.flippedY(secondary.maxY, primaryTop: primaryTop),
                                       width: secondary.width, height: secondary.height)
        XCTAssertTrue(secondaryCGBounds.contains(region))

        // "Below" never made the old `max` form diverge — a screen below the
        // primary can't out-max the primary's own top edge.
        let oldTop = [primaryFrame, secondary].map(\.maxY).max() ?? 0
        XCTAssertEqual(oldTop, primaryTop)
    }

    func testCgRegionSecondaryLeftOfPrimaryLandsOnSecondary() {
        let secondary = CGRect(x: -1920, y: 0, width: 1920, height: 1080) // same top edge as primary
        let primaryTop = primaryFrame.maxY

        XCTAssertEqual(cgRegionOnPrimary(primaryTop: primaryTop), primaryCaretRegion)

        let caretOnSecondary = CGRect(x: -1000, y: 500, width: 2, height: 16)
        let region = ScreenToolsSupport.cgRegion(around: caretOnSecondary, padX: 40, padY: 12,
                                                 primaryTop: primaryTop)
        XCTAssertEqual(region, CGRect(x: -1040, y: 552, width: 82, height: 40))

        let secondaryCGBounds = CGRect(x: secondary.minX,
                                       y: ScreenToolsSupport.flippedY(secondary.maxY, primaryTop: primaryTop),
                                       width: secondary.width, height: secondary.height)
        XCTAssertTrue(secondaryCGBounds.contains(region))

        let oldTop = [primaryFrame, secondary].map(\.maxY).max() ?? 0
        XCTAssertEqual(oldTop, primaryTop) // same top edge: old and new coincide
    }

    func testCgRegionSecondaryRightOfPrimaryLandsOnSecondary() {
        let secondary = CGRect(x: 1920, y: 0, width: 1600, height: 900) // shorter, same bottom edge
        let primaryTop = primaryFrame.maxY

        XCTAssertEqual(cgRegionOnPrimary(primaryTop: primaryTop), primaryCaretRegion)

        let caretOnSecondary = CGRect(x: 2500, y: 400, width: 2, height: 16)
        let region = ScreenToolsSupport.cgRegion(around: caretOnSecondary, padX: 40, padY: 12,
                                                 primaryTop: primaryTop)
        XCTAssertEqual(region, CGRect(x: 2460, y: 652, width: 82, height: 40))

        let secondaryCGBounds = CGRect(x: secondary.minX,
                                       y: ScreenToolsSupport.flippedY(secondary.maxY, primaryTop: primaryTop),
                                       width: secondary.width, height: secondary.height)
        XCTAssertTrue(secondaryCGBounds.contains(region))

        let oldTop = [primaryFrame, secondary].map(\.maxY).max() ?? 0
        XCTAssertEqual(oldTop, primaryTop) // shorter than primary: old and new coincide
    }

    /// Mixed layout: one secondary above (the bug trigger) plus one to the
    /// right. `primaryTop` must still come from `screens[0]` alone — an extra,
    /// unrelated secondary must not change the flip for either display.
    func testCgRegionMixedAboveAndRightLayout() {
        let above = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 1600, height: 900)
        let primaryTop = primaryFrame.maxY

        XCTAssertEqual(cgRegionOnPrimary(primaryTop: primaryTop), primaryCaretRegion)

        let caretOnAbove = CGRect(x: 500, y: 1600, width: 2, height: 16)
        let regionOnAbove = ScreenToolsSupport.cgRegion(around: caretOnAbove, padX: 40, padY: 12,
                                                        primaryTop: primaryTop)
        // Identical to the pure "secondary above" layout — the extra "right"
        // display is irrelevant to this flip.
        XCTAssertEqual(regionOnAbove, CGRect(x: 460, y: -548, width: 82, height: 40))

        let buggyTop = [primaryFrame, above, right].map(\.maxY).max() ?? 0
        XCTAssertEqual(buggyTop, 2160) // still wrong, and still the "above" display's maxY
    }

    /// NO REGRESSION: with exactly one display the old `screens.map(\.frame.maxY).max()`
    /// constant and the new primary-anchored one are numerically identical, so
    /// both codepaths must produce byte-identical regions.
    func testCgRegionSingleDisplayMatchesOldMaxYFormByteIdentical() {
        let caret = CGRect(x: 500, y: 500, width: 2, height: 16)
        let newTop = primaryFrame.maxY
        let oldTop = [primaryFrame].map(\.maxY).max() ?? 0
        XCTAssertEqual(newTop, oldTop)

        let usingNew = ScreenToolsSupport.cgRegion(around: caret, padX: 40, padY: 12, primaryTop: newTop)
        let usingOld = ScreenToolsSupport.cgRegion(around: caret, padX: 40, padY: 12, primaryTop: oldTop)
        XCTAssertEqual(usingNew, usingOld)
    }

    /// Same NO-REGRESSION guarantee for `cgRegionAbove` (the `conversationText`
    /// caller), whose pad shape (`padUp`/`padDown`) differs from `cgRegion` but
    /// shares the same `flippedY` flip.
    func testCgRegionAboveSingleDisplayMatchesOldMaxYFormByteIdentical() {
        let caret = CGRect(x: 500, y: 500, width: 2, height: 16)
        let newTop = primaryFrame.maxY
        let oldTop = [primaryFrame].map(\.maxY).max() ?? 0

        // padX/padUp/padDown match `conversationText`'s real call.
        let usingNew = ScreenToolsSupport.cgRegionAbove(caret, padX: 420, padUp: 1100, padDown: 60, primaryTop: newTop)
        let usingOld = ScreenToolsSupport.cgRegionAbove(caret, padX: 420, padUp: 1100, padDown: 60, primaryTop: oldTop)
        XCTAssertEqual(usingNew, usingOld)
    }

    /// `cgRegionAbove` reaches far above the caret — exactly the shape that hits
    /// this bug hardest, since a display arranged above the primary is precisely
    /// where that upward reach needs to land. The old `max` form under-shifts
    /// the region by the secondary's full height (1080pt here).
    func testCgRegionAboveSecondaryAbovePrimaryUsesPrimaryTopNotMaxTop() {
        let secondary = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let primaryTop = primaryFrame.maxY

        let caretOnSecondary = CGRect(x: 500, y: 1600, width: 2, height: 16)
        let region = ScreenToolsSupport.cgRegionAbove(caretOnSecondary, padX: 420, padUp: 1100, padDown: 60,
                                                       primaryTop: primaryTop)
        XCTAssertEqual(region, CGRect(x: 80, y: -1636, width: 842, height: 1176))

        let buggyTop = [primaryFrame, secondary].map(\.maxY).max() ?? 0
        let buggyRegion = ScreenToolsSupport.cgRegionAbove(caretOnSecondary, padX: 420, padUp: 1100, padDown: 60,
                                                            primaryTop: buggyTop)
        XCTAssertEqual(buggyRegion, CGRect(x: 80, y: -556, width: 842, height: 1176))

        // The old form is off by exactly the secondary's height (2160 - 1080).
        XCTAssertEqual(buggyRegion.minY - region.minY, secondary.height)
        XCTAssertNotEqual(buggyRegion, region)
    }

    // MARK: - 6. openableURL safety matrix

    func testOpenableURLAcceptsOnlyHTTPAndHTTPS() {
        XCTAssertEqual(ScreenToolsSupport.openableURL(from: "http://example.com")?.absoluteString,
                       "http://example.com")
        XCTAssertEqual(ScreenToolsSupport.openableURL(from: " https://example.com/a?b=c ")?.absoluteString,
                       "https://example.com/a?b=c")
        XCTAssertEqual(ScreenToolsSupport.openableURL(from: "HTTPS://Example.com")?.absoluteString,
                       "HTTPS://Example.com")
    }

    func testOpenableURLRejectsEverythingElse() {
        for payload in ["javascript:alert(1)",
                        "file:///etc/passwd",
                        "prosper://x",
                        "mailto:a@b.c",
                        "tel:+123456",
                        "has space",
                        "https://",
                        "example.com",
                        "",
                        "   "] {
            XCTAssertNil(ScreenToolsSupport.openableURL(from: payload),
                         "\(payload) must not be openable")
        }
    }

    func testMultipleBarcodesAreJoinedWithNoOpenAction() {
        // Two codes in one region: payloads joined, never an Open action —
        // otherwise a second code decides where the first one takes you.
        let codes = [BarcodeDetector.DecodedBarcode(payload: "https://b.test", x: 0.1, y: 0.2),
                     BarcodeDetector.DecodedBarcode(payload: "https://a.test", x: 0.1, y: 0.8)]
        let joined = ScreenToolsSupport.joinedInReadingOrder(
            codes.map { (text: $0.payload, x: $0.x, y: $0.y) })
        XCTAssertEqual(joined, "https://a.test\nhttps://b.test")
    }

    // MARK: - 7. selectionRect / isClick / hexString

    func testSelectionRectNormalizesNegativeDrag() {
        XCTAssertEqual(ScreenToolsSupport.selectionRect(from: CGPoint(x: 100, y: 100),
                                                        to: CGPoint(x: 40, y: 70)),
                       CGRect(x: 40, y: 70, width: 60, height: 30))
    }

    func testSelectionRectSquareUsesLongestSideAndKeepsDirection() {
        XCTAssertEqual(ScreenToolsSupport.selectionRect(from: CGPoint(x: 10, y: 10),
                                                        to: CGPoint(x: 110, y: 40),
                                                        square: true),
                       CGRect(x: 10, y: 10, width: 100, height: 100))
        XCTAssertEqual(ScreenToolsSupport.selectionRect(from: CGPoint(x: 200, y: 200),
                                                        to: CGPoint(x: 150, y: 100),
                                                        square: true),
                       CGRect(x: 100, y: 100, width: 100, height: 100))
    }

    func testSelectionRectFromCenterGrowsBothWays() {
        XCTAssertEqual(ScreenToolsSupport.selectionRect(from: CGPoint(x: 100, y: 100),
                                                        to: CGPoint(x: 60, y: 130),
                                                        fromCenter: true),
                       CGRect(x: 60, y: 70, width: 80, height: 60))
        XCTAssertEqual(ScreenToolsSupport.selectionRect(from: CGPoint(x: 100, y: 100),
                                                        to: CGPoint(x: 60, y: 130),
                                                        square: true,
                                                        fromCenter: true),
                       CGRect(x: 60, y: 60, width: 80, height: 80))
    }

    func testClampIntersectsAndZeroesOnMiss() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(ScreenToolsSupport.clamp(CGRect(x: 80, y: 80, width: 40, height: 40), to: bounds),
                       CGRect(x: 80, y: 80, width: 20, height: 20))
        XCTAssertEqual(ScreenToolsSupport.clamp(CGRect(x: 500, y: 500, width: 10, height: 10), to: bounds),
                       .zero)
    }

    func testIsClickHonoursFourPointThreshold() {
        let origin = CGPoint(x: 50, y: 50)
        XCTAssertEqual(ScreenToolsSupport.clickDragThreshold, 4)
        XCTAssertTrue(ScreenToolsSupport.isClick(from: origin, to: CGPoint(x: 53, y: 47)))
        XCTAssertFalse(ScreenToolsSupport.isClick(from: origin, to: CGPoint(x: 54, y: 50)))
        XCTAssertFalse(ScreenToolsSupport.isClick(from: origin, to: CGPoint(x: 50, y: 46)))
    }

    func testHexStringIsUppercaseSRGB() {
        XCTAssertEqual(ScreenToolsSupport.hexString(for: NSColor(srgbRed: 0, green: 0.6, blue: 1, alpha: 1)),
                       "#0099FF")
        XCTAssertEqual(ScreenToolsSupport.hexString(for: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
                       "#FFFFFF")
    }

    func testHexStringClampsOutOfGamutComponents() {
        let wide = NSColor(colorSpace: .extendedSRGB, components: [1.5, -0.2, 0.5, 1], count: 4)
        let hex = ScreenToolsSupport.hexString(for: wide)
        XCTAssertEqual(hex.count, 7)
        XCTAssertTrue(hex.hasPrefix("#FF00"), "expected clamped red/green, got \(hex)")
        XCTAssertEqual(hex, hex.uppercased())
    }
}
