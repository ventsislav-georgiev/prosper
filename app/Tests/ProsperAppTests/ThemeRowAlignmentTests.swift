import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1462: the Theme rows of Settings > Appearance line up. Each row is hosted alone in a window that is never shown, ordered
/// or made key (AXTreeSupport.hosted), over a scratch store; the frames come from the row's own preference
/// (ThemeRowFrames), so no accessibility tree and no event is involved. Slack is one device pixel, never a literal 0.5.
@MainActor
final class ThemeRowAlignmentTests: XCTestCase {
    private var saved: (ThemePalette, CGFloat)!

    override func setUp() async throws { saved = (ThemeRuntime.palette, ThemeRuntime.scale) }
    override func tearDown() async throws { (ThemeRuntime.palette, ThemeRuntime.scale) = saved }

    private final class Box { var frames: [ThemeRowPart: CGRect] = [:] }

    private struct Probe<V: View>: View {
        let content: V
        let box: Box
        var body: some View {
            content.overlayPreferenceValue(ThemeRowFrames.self) { anchors in
                GeometryReader { g in
                    let _ = { box.frames = anchors.mapValues { g[$0] } }()
                    Color.clear
                }
            }
        }
    }

    /// Default (4 dots), the two High Contrast rows (5 and 6 dots), Daylight, Graphite, Silver and one theme with no tints.
    private func store() throws -> ThemeStore {
        let s = ThemeStore(defaults: scratchDefaults("t1462"), cacheDir: tempDir("tc"))
        let url = tempDir("plain").appendingPathComponent("theme.json")
        try "{ \(ThemeVariantTests.baseColors) }".write(to: url, atomically: true, encoding: .utf8)
        let plain = ThemeDescriptor(id: "t.plain", title: "Plain", appearance: .dark, extensionID: "e", jsonPath: url)
        s.setAvailable(ThemeVariantTests.phaseB + [ThemeVariantTests.hcDark, plain, ThemeVariantTests.hcLight])
        return s
    }

    /// The part frames of row `d` hosted alone at the Settings minimum room for the current scale.
    private func frames(_ s: ThemeStore, _ d: ThemeDescriptor) -> [ThemeRowPart: CGRect] {
        let room = SettingsWindow.contentMinSize(scale: ThemeRuntime.scale).width - sz(218 + 2 * 26 + 2 * 16)
        let box = Box()
        let (win, host) = AXTreeSupport.hosted(Probe(content: ThemeList(theme: s, paneID: "appearance").row(d).frame(width: room), box: box),
                                               CGSize(width: room, height: 200))
        defer { win.close() }
        for _ in 0..<2 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(win.isVisible, "never shown")
        return box.frames
    }

    func testThemeRowsLineUpAtEveryScale() throws {
        let pixel = AXTreeSupport.devicePixel
        for scale in [0.7, 0.85, 1.0] as [CGFloat] {
            let s = try store()
            ThemeRuntime.scale = scale
            let rows = s.available
            XCTAssertGreaterThanOrEqual(rows.count, 7, "scale \(scale): the fixture rows")
            XCTAssertEqual(Set(rows.compactMap { s.tints[$0.id]?.count }).count > 2, true, "scale \(scale): several dot counts")
            var dotsTrailing: [CGFloat] = [], slotTrailing: [CGFloat] = [], checks: [CGRect] = []
            for d in rows {
                let other = try XCTUnwrap(rows.first { $0.id != d.id })
                var byState: [Bool: [ThemeRowPart: CGRect]] = [:]
                for selected in [true, false] {
                    s.select(id: selected ? d.id : other.id)
                    ThemeRuntime.scale = scale
                    let f = frames(s, d)
                    byState[selected] = f
                    let tag = "scale \(scale), \(d.title), selected \(selected)"
                    guard let hl = f[.highlight], let sw = f[.swatch], let ck = f[.check], let slot = f[.dotsSlot] else {
                        XCTFail("\(tag): a part has no frame: \(f.keys)")
                        continue
                    }
                    XCTAssertGreaterThanOrEqual(sw.minX, hl.minX + ThemeList.rowPad - pixel, "\(tag): the swatch keeps its padding in the highlight")
                    XCTAssertTrue(sw.minY >= hl.minY - pixel && sw.maxY <= hl.maxY + pixel && sw.maxX <= hl.maxX, "\(tag): the swatch lies inside the highlight")
                    XCTAssertGreaterThanOrEqual(hl.maxX - ck.maxX, ThemeList.rowPad - pixel, "\(tag): the checkmark keeps its padding too")
                    slotTrailing.append(slot.maxX)
                    checks.append(ck)
                    if let dots = f[.dots] { dotsTrailing.append(dots.maxX) }
                }
                if let on = byState[true]?[.title], let off = byState[false]?[.title] {
                    XCTAssertEqual(on.minX, off.minX, accuracy: pixel, "scale \(scale), \(d.title): the title does not move with the selection")
                } else { XCTFail("scale \(scale), \(d.title): no title frame") }
            }
            XCTAssertGreaterThanOrEqual(dotsTrailing.count, 12, "scale \(scale): the six tinted rows, both states")
            let want = try XCTUnwrap(slotTrailing.first)
            XCTAssertTrue(dotsTrailing.allSatisfy { abs($0 - want) <= pixel }, "scale \(scale): every last dot ends at the same x: \(dotsTrailing) vs \(want)")
            XCTAssertTrue(slotTrailing.allSatisfy { abs($0 - want) <= pixel }, "scale \(scale): the dots slot ends at the same x on every row: \(slotTrailing)")
            let ck = try XCTUnwrap(checks.first)
            XCTAssertTrue(checks.allSatisfy { abs($0.minX - ck.minX) <= pixel && abs($0.width - ck.width) <= pixel && abs($0.height - ck.height) <= pixel },
                          "scale \(scale): the checkmark slot has one frame on every row, selected or not: \(checks)")
        }
    }

    /// QA r1419 a1: the plain row's checkmark (opacity 0 when unselected) is hidden from VoiceOver in both states; the
    /// row button's selected trait alone carries the state.
    func testPlainRowCheckmarkIsHiddenFromVoiceOverInBothStates() throws {
        ThemeRuntime.scale = 1
        let s = try store()
        let plain = try XCTUnwrap(s.available.first { $0.id == "t.plain" })
        let other = try XCTUnwrap(s.available.first { $0.id != plain.id })
        XCTAssertTrue(s.tints[plain.id] == nil, "the fixture row is a plain row")
        for selected in [true, false] {
            s.select(id: selected ? plain.id : other.id)
            ThemeRuntime.scale = 1
            let tree = AXTreeSupport.tree(ThemeList(theme: s, paneID: "appearance").row(plain).frame(width: 400), CGSize(width: 400, height: 200)) { t in
                t.contains { $0.names.contains { $0.contains(plain.title) } }
            }
            XCTAssertTrue(tree.contains { $0.names.contains { $0.contains(plain.title) } }, "selected \(selected): the row is in the tree")
            let spoken = tree.filter { !$0.ignored && $0.names.contains { $0.localizedCaseInsensitiveContains("checkmark") } }
            XCTAssertTrue(spoken.isEmpty, "selected \(selected): nothing in the row says checkmark: \(spoken.map { $0.names })")
            XCTAssertEqual(tree.contains { $0.selected && !$0.ignored }, selected, "selected \(selected): the selected trait only on the selected row")
        }
    }
}
