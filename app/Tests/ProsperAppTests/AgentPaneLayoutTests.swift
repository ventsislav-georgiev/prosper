import CoreGraphics
import XCTest
@testable import ProsperApp

/// #831 Phase A (spec v3.1 §14.1): the pure pane tree. No window, no view, no defaults: values only.
enum PaneFixtures {
    static let dir = "/Users/example/dch-sockets"
    static let minimum = PaneLayout.minimumPane
    static func s(_ name: String) -> PaneTarget { .session(dir: dir, name: name) }
    static func h(_ id: String, seen: TimeInterval? = nil) -> PaneTarget { .history(dir: dir, id: id, seen: seen) }
    static func pane(_ t: PaneTarget? = nil) -> Pane { Pane(id: UUID(), target: t) }
    static func layout(_ tree: PaneNode, focused: UUID? = nil) -> PaneLayout {
        PaneLayout(id: UUID(), name: nil, tree: tree, focused: focused ?? tree.panes.first?.id ?? UUID(), zoomed: nil)
    }
    static func ratios(_ n: PaneNode) -> [Double] {
        guard case let .split(_, r, a, b) = n else { return [] }
        return [r] + ratios(a) + ratios(b)
    }
    static func splitPaths(_ n: PaneNode, _ p: [Int] = []) -> [[Int]] {
        guard case let .split(_, _, a, b) = n else { return [] }
        return [p] + splitPaths(a, p + [0]) + splitPaths(b, p + [1])
    }
    static func rootRatio(_ l: PaneLayout) -> Double? {
        guard case let .split(_, r, _, _) = l.tree else { return nil }
        return r
    }
}

/// A seeded generator (SplitMix64), so a failing property run reproduces from its printed seed.
struct PaneSplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class AgentPaneLayoutTests: XCTestCase {
    typealias F = PaneFixtures
    let big = CGRect(x: 0, y: 0, width: 3000, height: 2000)
    let area = CGRect(x: 0, y: 0, width: 1200, height: 800)

    /// [A | (B / C)]: one tall pane left, two stacked right.
    func lShape() -> (PaneLayout, UUID, UUID, UUID) {
        let (a, b, c) = (F.pane(F.s("api")), F.pane(F.s("docs")), F.pane())
        let l = F.layout(.split(.columns, ratio: 0.5, .leaf(a), .split(.rows, ratio: 0.5, .leaf(b), .leaf(c))))
        return (l, a.id, b.id, c.id)
    }

    func tiled(_ l: PaneLayout, _ r: CGRect) -> [UUID: CGRect] {
        if case let .tiled(f) = l.frames(in: r, minimum: F.minimum, splitsEnabled: true) { return f }
        return [:]
    }

    func refusal(_ r: Result<PaneLayout, PaneRefusal>) -> PaneRefusal? {
        if case let .failure(e) = r { return e }
        return nil
    }

    // MARK: Tree operations

    func testSplitAtEveryPositionPutsTheNewEmptyPaneAfterTheFocusedOneAndFocusesIt() throws {
        let (l, a, b, c) = lShape()
        for p in [a, b, c] {
            for axis in [PaneNode.Axis.columns, .rows] {
                let out = try l.focus(p).get().split(axis: axis, minimum: F.minimum, in: big).get()
                var expected = l.order
                expected.insert(out.focused, at: (expected.firstIndex(of: p) ?? -1) + 1)
                XCTAssertEqual(out.order, expected, "\(axis) at \(p)")
                XCTAssertFalse(l.order.contains(out.focused))
                XCTAssertTrue(out.panes.contains { $0.id == out.focused && $0.target == nil })
                XCTAssertTrue(out.validate())
                XCTAssertEqual(F.ratios(out.tree).count, 3)
            }
        }
        let one = try PaneLayout.single(F.s("api")).split(axis: .columns, minimum: F.minimum, in: area).get()
        XCTAssertEqual(F.rootRatio(one), 0.5)
        guard case .split(.columns, _, _, _) = one.tree else { return XCTFail("a columns split") }
    }

    func testCloseGivesTheSpaceAndTheFocusToTheSibling() throws {
        let (l0, a, b, c) = lShape()
        let l = try l0.focus(b).get().focus(c).get().focus(a).get()
        let closed = try l.close(a).get()
        XCTAssertEqual(closed.order, [b, c])
        XCTAssertEqual(closed.focused, c, "the sibling's most recently focused pane")
        guard case .split(.rows, _, _, _) = closed.tree else { return XCTFail("the sibling took the root") }
        let last = try closed.close(c).get()
        XCTAssertEqual(last.order, [b])
        XCTAssertEqual(last.focused, b)
        XCTAssertEqual(refusal(last.close(b)), .lastPane, "the window closes instead")
        // Never focused: the sibling's first pane in tree order.
        XCTAssertEqual(try l0.close(a).get().focused, b)
        // An unfocused pane closes without moving the focus.
        let other = try l0.close(c).get()
        XCTAssertEqual(other.order, [a, b])
        XCTAssertEqual(other.focused, a)
        XCTAssertEqual(refusal(l0.close(UUID())), .noSuchPane)
    }

    func testSplitOrCloseWhileZoomedUnzoomsFirst() throws {
        let (l, _, b, _) = lShape()
        let zoomed = l.toggleZoom()
        XCTAssertEqual(zoomed.zoomed, l.focused)
        XCTAssertTrue(try zoomed.split(axis: .columns, minimum: F.minimum, in: big).get().zoomed == nil)
        XCTAssertTrue(try zoomed.close(b).get().zoomed == nil)
    }

    func testEqualizeUsesTheLeafCountRatio() throws {
        let (l, _, _, _) = lShape()
        let skewed = try l.setRatio(path: [1], 0.7, minimum: .zero, in: big).get()
        XCTAssertEqual(F.ratios(skewed.tree), [0.5, 0.7])
        let one = try skewed.equalize(path: []).get()
        XCTAssertEqual(F.rootRatio(one) ?? 0, 1.0 / 3, accuracy: 1e-9, "leaves(first) / leaves(both)")
        XCTAssertEqual(F.ratios(one.tree).last, 0.7, "only that split")
        let deep = try skewed.equalize(path: [], deep: true).get()
        XCTAssertEqual(F.ratios(deep.tree).last, 0.5)
        XCTAssertEqual(F.ratios(try skewed.equalize(path: [1]).get().tree), [0.5, 0.5])
        XCTAssertEqual(refusal(l.equalize(path: [0])), .noSuchSplit)
        // Six panes in a row of columns, built by splitting the last: every split shares by leaf count.
        var row = PaneLayout.single()
        for _ in 1..<6 { row = try row.split(axis: .columns, minimum: .zero, in: big).get() }
        let even = try row.equalize(path: [], deep: true).get()
        let widths = tiled(even, CGRect(x: 0, y: 0, width: 1800, height: 600)).values.map(\.width)
        XCTAssertEqual(widths.count, 6)
        XCTAssertTrue(widths.allSatisfy { abs($0 - 300) < 1e-6 }, "\(widths)")
    }

    func testZoomTogglesTheFocusedPaneAndFocusMovesTheZoom() throws {
        let (l, _, b, _) = lShape()
        let z = l.toggleZoom()
        XCTAssertEqual(z.zoomed, l.focused)
        XCTAssertTrue(z.toggleZoom().zoomed == nil)
        XCTAssertTrue(PaneLayout.single().toggleZoom().zoomed == nil, "one pane has nothing to zoom")
        let moved = try z.focus(b).get()
        XCTAssertEqual(moved.zoomed, b, "7.4: focus while zoomed moves the zoom")
        XCTAssertEqual(moved.focused, b)
    }

    func testNeighbourAcrossAnLShapeWithTiesToTheMostRecentlyFocused() throws {
        let (l, a, b, c) = lShape()
        let f = tiled(l, area)
        XCTAssertEqual(f.count, 3)
        XCTAssertEqual(l.neighbour(of: a, direction: .right, frames: f), b, "a tie, never focused: tree order")
        XCTAssertEqual(l.neighbour(of: a, direction: .left, frames: f), nil)
        XCTAssertEqual(l.neighbour(of: b, direction: .left, frames: f), a)
        XCTAssertEqual(l.neighbour(of: c, direction: .left, frames: f), a)
        XCTAssertEqual(l.neighbour(of: b, direction: .down, frames: f), c)
        XCTAssertEqual(l.neighbour(of: c, direction: .up, frames: f), b)
        XCTAssertEqual(l.neighbour(of: b, direction: .up, frames: f), nil)
        let recent = try l.focus(c).get().focus(a).get()
        XCTAssertEqual(recent.neighbour(of: a, direction: .right, frames: f), c, "the tie goes to the most recently focused")
        let back = try recent.focus(b).get().focus(a).get()
        XCTAssertEqual(back.neighbour(of: a, direction: .right, frames: f), b)
    }

    func testNeighbourInATwoByThreeGrid() {
        let p = (0..<6).map { _ in F.pane() }
        let row = { (i: Int) in PaneNode.split(.columns, ratio: 1.0 / 3, .leaf(p[i]),
                                               .split(.columns, ratio: 0.5, .leaf(p[i + 1]), .leaf(p[i + 2]))) }
        let l = F.layout(.split(.rows, ratio: 0.5, row(0), row(3)))
        let f = tiled(l, area)
        XCTAssertEqual(f.count, 6)
        let id = p.map(\.id)
        XCTAssertEqual(l.neighbour(of: id[1], direction: .left, frames: f), id[0])
        XCTAssertEqual(l.neighbour(of: id[1], direction: .right, frames: f), id[2])
        XCTAssertEqual(l.neighbour(of: id[1], direction: .down, frames: f), id[4])
        XCTAssertEqual(l.neighbour(of: id[1], direction: .up, frames: f), nil)
        XCTAssertEqual(l.neighbour(of: id[4], direction: .up, frames: f), id[1])
        XCTAssertEqual(l.neighbour(of: id[3], direction: .right, frames: f), id[4])
        XCTAssertEqual(l.neighbour(of: id[2], direction: .right, frames: f), nil)
        XCTAssertEqual(l.neighbour(of: id[5], direction: .left, frames: f), id[4])
    }

    func testNextAndPreviousFollowTreeOrderAndWrap() throws {
        let (l, a, b, c) = lShape()
        XCTAssertEqual(l.order, [a, b, c])
        XCTAssertEqual(l.next, b)
        XCTAssertEqual(l.previous, c)
        let atC = try l.focus(c).get()
        XCTAssertEqual(atC.next, a)
        XCTAssertEqual(atC.previous, b)
        let one = PaneLayout.single()
        XCTAssertEqual(one.next, one.focused)
        XCTAssertEqual(one.previous, one.focused)
    }

    // MARK: Frames, cap and minimum (3.3, 3.4)

    func testFramesTileAtTheMinimumAndFallBackToTooSmallBelowIt() throws {
        let (a, b) = (F.pane(), F.pane())
        let l = F.layout(.split(.columns, ratio: 0.5, .leaf(a), .leaf(b)), focused: b.id)
        let f = tiled(l, CGRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertEqual(f[a.id], CGRect(x: 0, y: 0, width: 300, height: 400))
        XCTAssertEqual(f[b.id], CGRect(x: 300, y: 0, width: 300, height: 400))
        XCTAssertEqual(l.frames(in: CGRect(x: 0, y: 0, width: 599, height: 400), minimum: F.minimum, splitsEnabled: true),
                       .tooSmall(b.id))
        XCTAssertEqual(l.frames(in: CGRect(x: 0, y: 0, width: 600, height: 199), minimum: F.minimum, splitsEnabled: true),
                       .tooSmall(b.id))
        let one = PaneLayout.single()
        XCTAssertEqual(one.frames(in: CGRect(x: 0, y: 0, width: 100, height: 100), minimum: F.minimum, splitsEnabled: true),
                       .tiled([one.focused: CGRect(x: 0, y: 0, width: 100, height: 100)]), "one pane is never too small")
    }

    func testASplitBelowTheMinimumIsRefusedAndOneAtItIsNot() {
        let one = PaneLayout.single(F.s("api"))
        let narrow = CGRect(x: 0, y: 0, width: 599, height: 400)
        let r = one.split(axis: .columns, minimum: F.minimum, in: narrow)
        XCTAssertEqual(refusal(r), .noRoom)
        XCTAssertEqual(PaneRefusal.noRoom.notice, "No room for another pane here. Widen the window or hide the sidebar (⌃⌘S).")
        XCTAssertNil(refusal(one.split(axis: .rows, minimum: F.minimum, in: narrow)), "two rows of exactly 200")
        XCTAssertNil(refusal(one.split(axis: .columns, minimum: F.minimum, in: CGRect(x: 0, y: 0, width: 600, height: 400))),
                     "two columns of exactly 300")
        XCTAssertEqual(refusal(one.split(axis: .rows, minimum: F.minimum, in: CGRect(x: 0, y: 0, width: 600, height: 399))), .noRoom)
        XCTAssertEqual(refusal(one.show(F.s("docs"), placement: .side, minimum: F.minimum, in: narrow.insetBy(dx: 0, dy: 50),
                                        splitsEnabled: true)), .noRoom)
    }

    func testTheSeventhPaneIsRefusedByEveryEntryPoint() throws {
        var l = PaneLayout.single()
        for i in 1..<6 { l = try l.split(axis: i.isMultiple(of: 2) ? .rows : .columns, minimum: F.minimum, in: big).get() }
        XCTAssertEqual(l.panes.count, 6)
        XCTAssertTrue(l.validate())
        // ⌘D / ⇧⌘D and the "⋯" items split; ⌥-click and "Open to the Side" go through show(.side).
        XCTAssertEqual(refusal(l.split(axis: .columns, minimum: F.minimum, in: big)), .cap)
        XCTAssertEqual(refusal(l.split(axis: .rows, target: F.s("api"), minimum: F.minimum, in: big)), .cap)
        XCTAssertEqual(refusal(l.show(F.s("api"), placement: .side, minimum: F.minimum, in: big, splitsEnabled: true)), .cap)
        XCTAssertEqual(PaneRefusal.cap.notice, "6 panes is the most a layout holds")
        XCTAssertEqual(PaneRefusal.cap.menuSuffix, "(6 panes max)")
        // Five panes still split.
        XCTAssertNil(refusal(try l.close(l.focused).get().split(axis: .columns, minimum: F.minimum, in: big)))
    }

    func testShrinkingTheWindowNeverRemovesAPane() throws {
        var l = PaneLayout.single()
        for i in 1..<6 { l = try l.split(axis: i.isMultiple(of: 2) ? .rows : .columns, minimum: F.minimum, in: big).get() }
        XCTAssertEqual(l.frames(in: CGRect(x: 0, y: 0, width: 640, height: 420), minimum: F.minimum, splitsEnabled: true),
                       .tooSmall(l.focused))
        XCTAssertEqual(l.panes.count, 6)
        XCTAssertEqual(tiled(l, big).count, 6, "growing back restores the tiling with the saved ratios")
    }

    func testSetRatioClampsToTheRangeAndTheMinimum() throws {
        let (a, b) = (F.pane(), F.pane())
        let l = F.layout(.split(.columns, ratio: 0.5, .leaf(a), .leaf(b)))
        let r1000 = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(F.rootRatio(try l.setRatio(path: [], 0.05, minimum: F.minimum, in: r1000).get()) ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(F.rootRatio(try l.setRatio(path: [], 0.95, minimum: F.minimum, in: r1000).get()) ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertEqual(F.rootRatio(try l.setRatio(path: [], 0.4, minimum: F.minimum, in: r1000).get()), 0.4)
        let wide = CGRect(x: 0, y: 0, width: 10000, height: 800)
        XCTAssertEqual(F.rootRatio(try l.setRatio(path: [], 0.01, minimum: F.minimum, in: wide).get()), 0.1)
        XCTAssertEqual(F.rootRatio(try l.setRatio(path: [], 1.5, minimum: F.minimum, in: wide).get()), 0.9)
        XCTAssertEqual(F.rootRatio(try l.setRatio(path: [], .nan, minimum: F.minimum, in: wide).get()), 0.5)
        XCTAssertEqual(refusal(l.setRatio(path: [0], 0.5, minimum: F.minimum, in: wide)), .noSuchSplit)
        XCTAssertEqual(refusal(l.setRatio(path: [2], 0.5, minimum: F.minimum, in: wide)), .noSuchSplit)
    }

    func testReplaceRefusesASessionShownInAnotherPane() throws {
        let (l, a, b, c) = lShape()
        XCTAssertEqual(refusal(l.replace(c, target: F.s("api"))), .shown(a))
        XCTAssertEqual(refusal(l.replace(c, target: F.h("api"))), .shown(a), "the name's own record is that session (#580)")
        XCTAssertNil(refusal(l.replace(a, target: F.h("api"))), "the same pane may swap to its own record")
        XCTAssertNil(refusal(l.replace(c, target: F.h("api.1762700000"))), "an aside record is another id")
        XCTAssertTrue(try l.replace(b, target: nil).get().panes.allSatisfy { $0.id != b || $0.target == nil })
        XCTAssertEqual(refusal(l.replace(UUID(), target: nil)), .noSuchPane)
    }

    // MARK: Invariants and repair (3.2)

    func testRepairEmptiesDuplicateTargetsAfterTheFirstIncludingTheNamesOwnHistory() {
        let p = [F.pane(F.s("api")), F.pane(F.h("api", seen: 5)), F.pane(F.h("docs.1762700000")),
                 F.pane(F.h("docs.1762700000", seen: 9)), F.pane(), F.pane()]
        let tree = p.dropFirst().reduce(PaneNode.leaf(p[0])) { .split(.columns, ratio: 0.5, $0, .leaf($1)) }
        let l = F.layout(tree)
        XCTAssertFalse(l.validate())
        let (fixed, repairs) = l.repaired()
        XCTAssertEqual(repairs, [.duplicateTarget])
        XCTAssertEqual(fixed.order, l.order, "repair keeps every pane and its id")
        XCTAssertEqual(fixed.panes.map(\.target), [F.s("api"), nil, F.h("docs.1762700000"), nil, nil, nil])
        XCTAssertTrue(fixed.validate())
    }

    func testRepairMovesADanglingFocusAndClearsADanglingZoom() {
        let (l0, a, _, _) = lShape()
        var l = l0
        l.focused = UUID()
        l.zoomed = UUID()
        XCTAssertFalse(l.validate())
        let (fixed, repairs) = l.repaired()
        XCTAssertEqual(repairs, [.danglingFocus, .danglingZoom])
        XCTAssertEqual(fixed.focused, a)
        XCTAssertTrue(fixed.zoomed == nil)
        XCTAssertTrue(fixed.validate())
    }

    func testRepairClampsOutOfRangeRatios() {
        let p = (0..<4).map { _ in F.pane() }
        let l = F.layout(.split(.columns, ratio: 0.01, .split(.rows, ratio: 1.5, .leaf(p[0]), .leaf(p[1])),
                                .split(.rows, ratio: .nan, .leaf(p[2]), .leaf(p[3]))))
        let (fixed, repairs) = l.repaired()
        XCTAssertEqual(repairs, [.ratioClamped])
        XCTAssertEqual(F.ratios(fixed.tree), [0.1, 0.9, 0.5])
        XCTAssertTrue(F.layout(.split(.rows, ratio: 0.1, .leaf(F.pane()), .leaf(F.pane()))).validate(), "0.1 is in range")
    }

    func testRepairCutsEightLeavesToSixFromTheEndOfTreeOrder() {
        let p = (0..<8).map { _ in F.pane() }
        let tree = p.dropFirst().reduce(PaneNode.leaf(p[0])) { .split(.columns, ratio: 0.5, $0, .leaf($1)) }
        let l = F.layout(tree, focused: p[7].id)
        let (fixed, repairs) = l.repaired()
        XCTAssertEqual(fixed.order, p.prefix(6).map(\.id))
        XCTAssertEqual(repairs, [.tooManyPanes, .danglingFocus])
        XCTAssertEqual(fixed.focused, p[0].id)
        XCTAssertTrue(fixed.validate())
    }

    func testRepairCutsABalancedTreeOf4096LeavesToItsFirstSixInOnePass() {
        func balanced(_ p: ArraySlice<Pane>) -> PaneNode {
            guard p.count > 1 else { return .leaf(p.first ?? F.pane()) }
            let mid = p.startIndex + p.count / 2
            return .split(.columns, ratio: 0.5, balanced(p[..<mid]), balanced(p[mid...]))
        }
        let p = (0..<4096).map { _ in F.pane() }
        let l = F.layout(balanced(p[...]))
        XCTAssertEqual(l.panes.count, 4096)
        let (fixed, repairs) = l.repaired()
        XCTAssertEqual(fixed.order, p.prefix(6).map(\.id), "the first six in tree order")
        XCTAssertEqual(repairs, [.tooManyPanes])
        XCTAssertEqual(fixed.focused, p.first?.id)
        XCTAssertTrue(fixed.validate())
    }

    func testRepairClearsAZoomOnALeafOtherThanTheFocusAfterRepairingTheFocus() {
        let (l0, a, b, _) = lShape()
        var l = l0
        l.zoomed = b
        XCTAssertFalse(l.validate(), "7.4: the zoom names the focused pane")
        var (fixed, repairs) = l.repaired()
        XCTAssertEqual(repairs, [.zoomNotFocused])
        XCTAssertTrue(fixed.zoomed == nil)
        XCTAssertEqual(fixed.focused, a)
        XCTAssertTrue(fixed.validate())
        // The focus is repaired first: a dangling focus moves to the first leaf, which is the zoom here.
        l.focused = UUID()
        l.zoomed = a
        (fixed, repairs) = l.repaired()
        XCTAssertEqual(repairs, [.danglingFocus])
        XCTAssertEqual(fixed.focused, a)
        XCTAssertEqual(fixed.zoomed, a)
        l.zoomed = b
        (fixed, repairs) = l.repaired()
        XCTAssertEqual(repairs, [.danglingFocus, .zoomNotFocused])
        XCTAssertTrue(fixed.zoomed == nil)
        XCTAssertTrue(l0.toggleZoom().validate(), "a zoom on the focus is valid")
    }

    func testADanglingFocusIsRefusedBySplitAndShowToTheSide() throws {
        let (l0, a, _, c) = lShape()
        var l = l0
        l.focused = UUID()
        for axis in [PaneNode.Axis.columns, .rows] {
            XCTAssertEqual(refusal(l.split(axis: axis, minimum: F.minimum, in: big)), .noSuchPane)
        }
        XCTAssertEqual(refusal(l.show(F.s("web"), placement: .side, minimum: F.minimum, in: big, splitsEnabled: true)),
                       .noSuchPane)
        XCTAssertEqual(refusal(l.show(F.s("web"), placement: .focused, minimum: F.minimum, in: big, splitsEnabled: true)),
                       .noSuchPane, "replace(focused) refuses too")
        XCTAssertTrue(l.toggleZoom().zoomed == nil, "no zoom on a pane that is not in the tree")
        XCTAssertTrue(try l.focus(a).get().validate(), "focus repairs it")
        XCTAssertEqual(try l.show(F.s("api"), placement: .side, minimum: F.minimum, in: big, splitsEnabled: true).get().focused, a,
                       "a row already shown focuses its pane")
        // The rest carry the input's dangling focus unchanged and add no defect of their own.
        let closed = try l.close(c).get()
        XCTAssertEqual(closed.focused, l.focused)
        XCTAssertEqual(closed.repaired().repairs, [.danglingFocus])
    }

    func testRepairGivesADuplicatePaneIDAFreshOne() {
        let a = F.pane(F.s("api"))
        let l = F.layout(.split(.columns, ratio: 0.5, .leaf(a), .leaf(Pane(id: a.id, target: F.s("docs")))))
        XCTAssertFalse(l.validate())
        let (fixed, repairs) = l.repaired()
        XCTAssertEqual(repairs, [.duplicatePaneID])
        XCTAssertEqual(Set(fixed.order).count, 2)
        XCTAssertEqual(fixed.order.first, a.id)
        XCTAssertEqual(fixed.panes.map(\.target), [F.s("api"), F.s("docs")], "the target stays with the renamed pane")
        XCTAssertTrue(fixed.validate())
    }

    // MARK: Property test (QA R5)

    func testRandomOperationSequencesKeepEveryInvariant() {
        let names = ["api", "api-qa", "docs", "web", "cli"]
        let areas = [big, area, CGRect(x: 0, y: 0, width: 700, height: 500)]
        for seed: UInt64 in [1, 7, 42, 831, 2026, 0xC0FFEE, 0xBADC0DE, 99_991] {
            var g = PaneSplitMix64(state: seed)
            var l = PaneLayout.single()
            for step in 0..<300 {
                let pick = Int.random(in: 0..<4, using: &g)
                let name = names[Int.random(in: 0..<names.count, using: &g)]
                let target: PaneTarget? = pick == 0 ? nil : pick == 1 ? F.s(name) : pick == 2 ? F.h(name, seen: 1) : F.h(name + ".1")
                let r = areas[Int.random(in: 0..<areas.count, using: &g)]
                let pane = l.order.randomElement(using: &g) ?? l.focused
                let path = F.splitPaths(l.tree).randomElement(using: &g) ?? []
                let op = Int.random(in: 0..<9, using: &g)
                let result: Result<PaneLayout, PaneRefusal> = switch op {
                case 0: l.split(axis: .columns, target: target, minimum: F.minimum, in: r)
                case 1: l.split(axis: .rows, target: target, minimum: F.minimum, in: r)
                case 2: l.close(pane)
                case 3: l.focus(pane)
                case 4: l.setRatio(path: path, Double.random(in: -0.5...1.5, using: &g), minimum: F.minimum, in: r)
                case 5: l.equalize(path: path, deep: Bool.random(using: &g))
                case 6: .success(l.toggleZoom())
                case 7: l.replace(pane, target: target)
                default: l.show(target ?? F.s(name), placement: Bool.random(using: &g) ? .side : .focused,
                                minimum: F.minimum, in: r, splitsEnabled: true)
                }
                if case let .success(next) = result { l = next }
                let ids = l.order
                let ok = (1...6).contains(ids.count) && Set(ids).count == ids.count
                    && F.ratios(l.tree).allSatisfy { PaneLayout.ratioRange.contains($0) }
                    && ids.contains(l.focused) && (l.zoomed.map { ids.contains($0) } ?? true)
                    && (l.zoomed == nil || l.zoomed == l.focused) && l.validate()
                if !ok {
                    return XCTFail("seed \(seed) step \(step) op \(op): \(ids.count) panes, repairs \(l.repaired().repairs)")
                }
            }
        }
    }

    // MARK: The browse rule (7.1)

    func testShowFocusesAPaneAlreadyShowingTheRow() throws {
        let (l, a, _, c) = lShape()
        let atC = try l.focus(c).get()
        for placement in [PaneLayout.Placement.focused, .side] {
            for t in [F.s("api"), F.h("api", seen: 3)] {
                let out = try atC.show(t, placement: placement, minimum: F.minimum, in: area, splitsEnabled: true).get()
                XCTAssertEqual(out.focused, a)
                XCTAssertEqual(out.tree, l.tree, "nothing else changes")
            }
        }
    }

    func testShowReplacesTheFocusedPaneInPlace() throws {
        let (l, _, _, c) = lShape()
        let out = try l.focus(c).get().show(F.s("web"), placement: .focused, minimum: F.minimum, in: area, splitsEnabled: true).get()
        XCTAssertEqual(out.order, l.order)
        XCTAssertEqual(out.focused, c)
        XCTAssertEqual(out.panes.last?.target, F.s("web"))
        XCTAssertEqual(F.ratios(out.tree), F.ratios(l.tree))
        let one = try PaneLayout.single(F.s("api")).show(F.h("docs.1"), placement: .focused, minimum: F.minimum, in: area,
                                                         splitsEnabled: true).get()
        XCTAssertEqual(one.panes.map(\.target), [F.h("docs.1")], "one pane: today's sidebar click")
    }

    func testShowToTheSideSplitsAlongTheLongerSide() throws {
        let one = PaneLayout.single(F.s("api"))
        let cases: [(CGRect, PaneNode.Axis)] = [(CGRect(x: 0, y: 0, width: 1200, height: 800), .columns),
                                                (CGRect(x: 0, y: 0, width: 800, height: 1200), .rows),
                                                (CGRect(x: 0, y: 0, width: 1000, height: 1000), .columns)]
        for (r, axis) in cases {
            let out = try one.show(F.s("docs"), placement: .side, minimum: F.minimum, in: r, splitsEnabled: true).get()
            guard case let .split(got, _, _, _) = out.tree else { return XCTFail("a split") }
            XCTAssertEqual(got, axis, "\(r)")
            XCTAssertEqual(out.panes.map(\.target), [F.s("api"), F.s("docs")])
            XCTAssertEqual(out.focused, out.order.last)
        }
    }

    @MainActor
    func testTheSplitGateTurnsSideIntoAClickAndShowsAMultiPaneLayoutsFocusedPaneAlone() throws {
        XCTAssertFalse(AgentPaneLayout.splitsEnabled, "15.0: off until Phase C")
        let gate = AgentPaneLayout.splitsEnabled
        let one = PaneLayout.single(F.s("api"))
        let out = try one.show(F.s("docs"), placement: .side, minimum: F.minimum, in: area, splitsEnabled: gate).get()
        XCTAssertEqual(out.panes.map(\.target), [F.s("docs")], "⌥-click acts as a plain click")
        let (l, _, b, _) = lShape()
        let atB = try l.focus(b).get()
        XCTAssertEqual(atB.frames(in: area, minimum: F.minimum, splitsEnabled: gate), .tiled([b: area]))
        XCTAssertEqual(tiled(atB, area).count, 3, "the tree is kept")
        XCTAssertEqual(atB.tree, l.tree)
    }

    func testWalkingSkipsRowsShownInAnotherPaneAndNeverWraps() throws {
        let rows = ["api", "docs", "web", "cli"].map(F.s)
        let (a, b) = (F.pane(F.s("api")), F.pane(F.s("docs")))
        let two = F.layout(.split(.columns, ratio: 0.5, .leaf(a), .leaf(b)))
        XCTAssertEqual(two.walk(rows, down: true), F.s("web"), "docs is shown in the other pane")
        XCTAssertEqual(two.walk(rows, down: false), nil, "the first row: no wrap")
        let atWeb = try two.replace(a.id, target: F.s("web")).get().replace(b.id, target: F.s("cli")).get()
        XCTAssertEqual(atWeb.walk(rows, down: true), nil, "every remaining row is shown elsewhere: a no-op, not a wrap")
        XCTAssertEqual(atWeb.walk(rows, down: false), F.s("docs"))
        let history = try two.replace(a.id, target: F.h("web")).get()
        XCTAssertEqual(history.walk(rows, down: true), F.s("cli"), "a pane on the name's own record shows that row")
        let empty = try two.replace(a.id, target: nil).get()
        XCTAssertEqual(empty.walk(rows, down: true), F.s("api"), "an empty pane starts before the first row")
        XCTAssertEqual(empty.walk(rows, down: false), F.s("cli"))
    }

    func testWalkingWithOnePaneSkipsNothing() {
        let rows = ["api", "docs", "web"].map(F.s)
        let one = PaneLayout.single(F.s("docs"))
        XCTAssertEqual(one.walk(rows, down: true), F.s("web"))
        XCTAssertEqual(one.walk(rows, down: false), F.s("api"))
        XCTAssertEqual(PaneLayout.single(F.s("web")).walk(rows, down: true), nil)
        XCTAssertEqual(PaneLayout.single().walk([], down: true), nil)
    }
}
