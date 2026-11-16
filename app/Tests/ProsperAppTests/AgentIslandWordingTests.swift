import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1069 (OQ-97 picks): the History X says a pinned older record stays (QA #743 INFO-2), and the row's two resume
/// icons differ in shape and in words (QA #742 INFO-1). Pure functions and offscreen renders only: no window is
/// shown, no event is posted, no dch runs.
final class AgentIslandWordingTests: XCTestCase {
    private let notched = AgentIslandGeometry.make(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
        safeTop: 32)
    private static let v1281 = DchCommand.Binary(path: "/fake/dch", version: [1, 28, 1])

    private func rec(_ file: String, ended: TimeInterval, pinned: Bool = false) -> DchHistoryRecord {
        DchHistoryRecord(key: AgentSessionKey(dir: "/d", name: "work"), cwd: "/src", updated: ended, ended: ended,
                         end: "stopped", pinned: pinned, file: file)
    }

    /// The X removes the unpinned records; the label names the pinned older ones that stay (the row then shows one).
    func testRemoveLabelSaysThePinnedOlderRecordStays() {
        XCTAssertEqual(AgentIsland.removeEditLabel(older: 0, unpinned: 0), "Remove from History")
        XCTAssertEqual(AgentIsland.removeEditLabel(older: 2, unpinned: 2), "Remove from History (also 2 older records of this name)")
        XCTAssertEqual(AgentIsland.removeEditLabel(older: 1, unpinned: 0), "Remove from History (1 pinned older record stays)")
        XCTAssertEqual(AgentIsland.removeEditLabel(older: 2, unpinned: 0), "Remove from History (2 pinned older records stay)")
        XCTAssertEqual(AgentIsland.removeEditLabel(older: 3, unpinned: 1),
                       "Remove from History (also 1 older record of this name; 2 pinned older records stay)")
    }

    /// The drawn row's menu item and its X (and VoiceOver action) read the same label.
    @MainActor
    func testDrawnRowsXSaysThePinnedOlderRecordStays() throws {
        let store = AgentIslandStore(geometry: notched)
        store.controlDch = Self.v1281
        store.history = [rec("work", ended: 300), rec("work.1762000000", ended: 200, pinned: true), rec("work.1761000000", ended: 100)]
        store.historyTab = true
        let d = try XCTUnwrap(AgentIslandView(store: store, onRemove: { _ in }).historyDrawn.first)
        XCTAssertEqual(AgentIslandView(store: store).historyDrawn.count, 1)
        let want = "Remove from History (also 1 older record of this name; 1 pinned older record stays)"
        XCTAssertEqual(d.menu.last?.title, want)
        let row = AgentIslandHistoryRow(record: d.record, now: 0, status: nil, enabled: true, action: {}, pin: {}, remove: {},
                                        older: d.older, olderUnpinned: d.olderUnpinned)
        XCTAssertEqual(row.removeLabel, want)
        store.history = [rec("work", ended: 300), rec("work.1762000000", ended: 200, pinned: true)]
        let only = try XCTUnwrap(AgentIslandView(store: store, onRemove: { _ in }).historyDrawn.first)
        XCTAssertEqual(only.menu.last?.title, "Remove from History (1 pinned older record stays)")
    }

    /// Two shapes (not one triangle filled and hollow), both real symbols that draw at 9 pt at backing 1 and 2,
    /// and two labels that differ in words.
    @MainActor
    func testResumeIconsDifferInShapeAndInWords() throws {
        let with = AgentIsland.resumeWithMessageSymbol, quiet = AgentIsland.resumeNoMessageSymbol
        XCTAssertEqual(with, "play.fill")
        XCTAssertEqual(quiet, "forward.end")
        func shape(_ s: String) -> String { s.hasSuffix(".fill") ? String(s.dropLast(5)) : s }
        XCTAssertNotEqual(shape(with), shape(quiet), "not only filled versus hollow")
        XCTAssertEqual(AgentIsland.resumeWithMessageHelp, "Resume with dch's carry-on message")
        XCTAssertEqual(AgentIsland.resumeNoMessageLabel, "Resume (no message)")
        func words(_ s: String) -> Set<String> { Set(s.lowercased().split { !$0.isLetter }.map(String.init)) }
        XCTAssertFalse(words(AgentIsland.resumeNoMessageLabel).isSubset(of: words(AgentIsland.resumeWithMessageHelp)))
        XCTAssertFalse(words(AgentIsland.resumeWithMessageHelp).isSubset(of: words(AgentIsland.resumeNoMessageLabel)))
        for s in [with, quiet] {
            XCTAssertTrue(NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil, s)
        }
        func lit(_ symbol: String, scale: CGFloat) throws -> [Bool] {
            let ir = ImageRenderer(content: Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white).frame(width: 14, height: 14).background(Color.black))
            ir.scale = scale
            let cg = try XCTUnwrap(ir.cgImage)
            let data = try XCTUnwrap(cg.dataProvider?.data) as Data, bpp = cg.bitsPerPixel / 8
            XCTAssertEqual(cg.bitsPerComponent, 8)
            XCTAssertEqual(cg.width, Int(14 * scale))
            var out: [Bool] = []
            for y in 0..<cg.height { for x in 0..<cg.width {
                let o = y * cg.bytesPerRow + x * bpp
                out.append((0..<3).map { data[o + $0] }.max()! > 100)
            } }
            return out
        }
        for scale: CGFloat in [1, 2] {
            let a = try lit(with, scale: scale), b = try lit(quiet, scale: scale)
            XCTAssertGreaterThan(a.filter { $0 }.count, 5, "\(with) draws at \(scale)x")
            XCTAssertGreaterThan(b.filter { $0 }.count, 5, "\(quiet) draws at \(scale)x")
            XCTAssertGreaterThan(zip(a, b).filter { $0 != $1 }.count, 3, "the two differ in ink at \(scale)x")
        }
    }
}
