import CoreGraphics
import XCTest
@testable import ProsperApp

/// A3 tier-4 OCR anchoring: the pure line-match picker and the Vision-normalized →
/// AppKit-screen coordinate transform. The Vision request itself and its live pixel
/// accuracy are exercised end-to-end only with Screen Recording + a real capture.
final class OCRCaretAnchorTests: XCTestCase {

    func testBestMatchPicksLongestCommonPrefix() {
        let lines = ["unrelated banner", "let me know", "let me tell you now"]
        // Target shares the longest leading run with index 2.
        XCTAssertEqual(
            VisionOCR.bestMatchIndex(candidates: lines, target: "let me tell y"), 2)
    }

    func testBestMatchRejectsWhenNoOverlap() {
        XCTAssertNil(VisionOCR.bestMatchIndex(
            candidates: ["quarterly report", "attachments"], target: "здравей"))
    }

    func testBestMatchRequiresMinimumOverlap() {
        // Only 2 shared leading chars (< 3) → no confident match.
        XCTAssertNil(VisionOCR.bestMatchIndex(candidates: ["heptagon"], target: "help me"))
    }

    func testNormalizedToAppKitMapsRegionCorners() {
        // Captured region: 100pt-wide, 50pt-tall, top-left at global CG (200, 300).
        // Single display 1000pt tall → globalTop = 1000 (assuming primary at origin).
        // We only assert self-consistency of the transform's geometry, not pixels.
        let cg = CGRect(x: 200, y: 300, width: 100, height: 50)
        // A box hugging the region's TOP-LEFT in Vision space (y near 1).
        let topLeft = CGRect(x: 0, y: 0.9, width: 0, height: 0.1)
        let r = VisionContext.normalizedToAppKit(topLeft, capturedCGRect: cg)
        // x maps to the region's left edge.
        XCTAssertEqual(r.minX, 200, accuracy: 0.001)
        // Height is the normalized fraction of the region height.
        XCTAssertEqual(r.height, 5, accuracy: 0.001)
        // A box at the region BOTTOM (y near 0) sits lower in AppKit (smaller y).
        let bottom = CGRect(x: 0, y: 0.0, width: 0, height: 0.1)
        let rb = VisionContext.normalizedToAppKit(bottom, capturedCGRect: cg)
        XCTAssertLessThan(rb.minY, r.minY)
    }
}
