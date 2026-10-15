import CoreGraphics
import os
import Vision
import XCTest
@testable import ProsperApp

/// #335: the screen tools' `.accurate` pass is bounded, then falls back to `.fast`.
/// The recognizer is injected; nothing here runs Vision.
final class ScreenToolsOCRBoundTests: XCTestCase {

    private let image = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    private let line = OCRLine(text: "fast", boundingBox: .zero)

    func testHungAccurateFallsBackToFastAfterDeadline() async {
        let fast = line
        let start = ContinuousClock.now
        let lines = await ScreenTools.boundedRecognizeLines(in: image, deadline: 0.5) { _, level in
            // Never resumes: the stalled `.accurate` pass.
            if level == .accurate { await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } }
            return [fast]
        }
        XCTAssertEqual(lines.map(\.text), ["fast"])
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1.5))
    }

    func testAccurateWithTextIsUsedAndFastNeverRuns() async {
        let fastCalls = OSAllocatedUnfairLock(initialState: 0)
        let lines = await ScreenTools.boundedRecognizeLines(in: image, deadline: 5) { _, level in
            if level == .fast { fastCalls.withLock { $0 += 1 } }
            return [OCRLine(text: level == .accurate ? "accurate" : "fast", boundingBox: .zero)]
        }
        XCTAssertEqual(lines.map(\.text), ["accurate"])
        XCTAssertEqual(fastCalls.withLock { $0 }, 0)
    }

    func testEmptyAccurateFallsBackToFast() async {
        let fast = line
        let lines = await ScreenTools.boundedRecognizeLines(in: image, deadline: 5) { _, level in
            level == .accurate ? [] : [fast]
        }
        XCTAssertEqual(lines.map(\.text), ["fast"])
    }
}
