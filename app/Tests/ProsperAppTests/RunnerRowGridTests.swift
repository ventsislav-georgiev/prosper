import XCTest
@testable import ProsperApp

/// Covers `RunnerRowGrid.visibleSlots` — the fixed ⌘-digit badge ladder mapping.
/// Correctness (cell→row band, bounds, caps) + the hot-path budget pinned in the
/// `visibleSlots` doc comment (< 20 µs/call for a full viewport).
final class RunnerRowGridTests: XCTestCase {

    /// Build N stacked rows at the real pitch, id == index, center in each cell.
    private func stackedRows(_ n: Int) -> [Int: RowSpan] {
        let pitch = RunnerRowGrid.rowPitch
        var frames: [Int: RowSpan] = [:]
        for i in 0..<n {
            let minY = CGFloat(i) * pitch
            frames[i] = RowSpan(minY: minY, maxY: minY + pitch)
        }
        return frames
    }

    func test_emptyOrZeroHeight_returnsNoSlots() {
        XCTAssertTrue(RunnerRowGrid.visibleSlots([:], height: 400).isEmpty)
        XCTAssertTrue(RunnerRowGrid.visibleSlots(stackedRows(5), height: 0).isEmpty)
        XCTAssertTrue(RunnerRowGrid.visibleSlots(stackedRows(5), height: -10).isEmpty)
    }

    func test_cellsMapToRowsInOrder() {
        let pitch = RunnerRowGrid.rowPitch
        let rows = stackedRows(5)
        let slots = RunnerRowGrid.visibleSlots(rows, height: pitch * 5)
        XCTAssertEqual(slots.count, 5)
        for (cell, slot) in slots.enumerated() {
            XCTAssertEqual(slot.id, cell, "cell \(cell) should own row \(cell)")
            XCTAssertEqual(slot.centerY, pitch / 2 + CGFloat(cell) * pitch, accuracy: 0.01)
        }
    }

    /// A cell whose center clears `height - 4` is not emitted — guarantees we never
    /// label a partially-clipped row (issue 3's exact-rows contract).
    func test_partialTrailingCellExcluded() {
        let pitch = RunnerRowGrid.rowPitch
        let rows = stackedRows(5)
        // Room for 2 full cells + a sliver: third cell center (pitch*2.5) must drop.
        let slots = RunnerRowGrid.visibleSlots(rows, height: pitch * 2 + pitch / 2)
        XCTAssertEqual(slots.count, 2)
    }

    /// Scrolling shifts row centers; badges hold their cell Y and re-label to the
    /// row that scrolled into each band.
    func test_scrolledRowsRelabelSameSlots() {
        let pitch = RunnerRowGrid.rowPitch
        var rows = stackedRows(8)
        // Scroll up by one pitch: row 0 leaves the top, row 1 now sits in cell 0.
        rows = rows.mapValues { RowSpan(minY: $0.minY - pitch, maxY: $0.maxY - pitch) }
        let slots = RunnerRowGrid.visibleSlots(rows, height: pitch * 3)
        XCTAssertEqual(slots.first?.centerY ?? -1, pitch / 2, accuracy: 0.01, "cell 0 Y fixed")
        XCTAssertEqual(slots.first?.id, 1, "row 1 scrolled into cell 0")
    }

    /// A cell with no row in its band yields no slot (gap, not a phantom badge).
    func test_cellWithNoRowInBandSkipped() {
        let pitch = RunnerRowGrid.rowPitch
        // Single row parked in cell 0 only.
        let rows: [Int: RowSpan] = [7: RowSpan(minY: 0, maxY: pitch)]
        let slots = RunnerRowGrid.visibleSlots(rows, height: pitch * 4)
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots.first?.id, 7)
        XCTAssertEqual(slots.first?.centerY ?? -1, pitch / 2, accuracy: 0.01)
    }

    /// Hardware digit row caps the ladder at ten even on a tall viewport.
    func test_cappedAtMaxSlots() {
        let pitch = RunnerRowGrid.rowPitch
        let rows = stackedRows(40)
        let slots = RunnerRowGrid.visibleSlots(rows, height: pitch * 40)
        XCTAssertEqual(slots.count, RunnerRowGrid.maxSlots)
    }

    // MARK: - Performance (hot path)

    /// `visibleSlots` runs in the badge overlay's GeometryReader body — once per
    /// scroll frame. Budget: < 20 µs/call for a full viewport. Loose enough for a
    /// slow CI box in an unoptimized `swift test` build, tight enough that an
    /// allocation or O(n²) regression trips it.
    func test_visibleSlots_perf() {
        let pitch = RunnerRowGrid.rowPitch
        let rows = stackedRows(RunnerRowGrid.maxSlots)   // full viewport
        let height = pitch * CGFloat(RunnerRowGrid.maxSlots)
        let iterations = 100_000
        var sink = 0
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            sink &+= RunnerRowGrid.visibleSlots(rows, height: height).count
        }
        let usPerCall = (CFAbsoluteTimeGetCurrent() - start) / Double(iterations) * 1e6
        XCTAssertGreaterThan(sink, 0)  // defeat dead-code elimination
        XCTAssertLessThan(usPerCall, 20, "visibleSlots took \(usPerCall) µs/call (budget 20 µs)")
    }
}
