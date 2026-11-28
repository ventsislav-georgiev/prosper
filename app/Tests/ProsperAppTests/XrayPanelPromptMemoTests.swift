import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #2090 (#2077 hotspots 2 and 7): the Prompts list is computed once per change of what it reads (chapters, anchors,
/// filter, chips), never per body or tab switch; the drawer keeps each visited tab's list built, the hidden ones out of
/// VoiceOver's reach.
@MainActor
final class XrayPanelPromptMemoTests: XCTestCase {
    static func chapter(_ i: Int, _ title: String, auto: Bool = false, peer: String? = nil) -> TranscriptOutline.Chapter {
        var c = TranscriptOutline.Chapter(id: i, ordinal: i, title: title, kind: .prompt, hasError: false)
        c.auto = auto
        c.peer = peer
        return c
    }

    static let rows: [TranscriptOutline.Chapter] = [
        chapter(1, "Fix the login test"), chapter(2, "Conversation compacted", auto: true),
        chapter(3, "Please rerun the api suite", peer: "api-qa"), chapter(4, "Hand back", auto: true, peer: "api-qa"),
        chapter(5, "Continue the api work"), chapter(12, "Fix the api parser"),
    ]

    func panel() -> XrayPanelModel {
        let p = XrayPanelModel(target: XrayChaptersTests.local, tab: .prompts)
        p.dchChapters = Self.rows
        return p
    }

    /// The memo against the plain computation (shown(), promptLines, the counts) right after each input changed.
    func assertFresh(_ p: XrayPanelModel, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        let rows = p.shown(.prompts), all = p.shown(.prompts, auto: true, peer: true)
        XCTAssertEqual(p.shownPrompts.map(\.id), rows.map(\.id), "\(why): rows", file: file, line: line)
        XCTAssertEqual(p.prompts.ids, p.promptLines(rows).map(\.id), "\(why): ids", file: file, line: line)
        XCTAssertEqual(p.prompts.lines.map(\.id), p.prompts.ids, "\(why): lines", file: file, line: line)
        XCTAssertEqual(p.prompts.ordinalWidest, XrayCol.widest(rows.map { "\($0.ordinal)" }), "\(why): width", file: file, line: line)
        XCTAssertEqual(p.hidden(.prompts).auto, all.filter(\.auto).count, "\(why): auto", file: file, line: line)
        XCTAssertEqual(p.hidden(.prompts).peer, all.filter { $0.from == .peer }.count, "\(why): peer", file: file, line: line)
        XCTAssertEqual(p.count(.prompts), rows.count, "\(why): count", file: file, line: line)
    }

    /// Red with the memo left uncleared by listChanged (filter, chips), by dchChapters or by chapterAnchors.
    func testMemoFollowsFilterChipsChaptersAndAnchors() {
        let p = panel()
        assertFresh(p, "open")
        XCTAssertEqual(p.shownPrompts.map(\.title), ["Fix the api parser", "Continue the api work", "Fix the login test"])
        p.filter = "api"
        assertFresh(p, "filter")
        XCTAssertEqual(p.shownPrompts.map(\.title), ["Fix the api parser", "Continue the api work"], "filtered")
        p.showAuto = true
        assertFresh(p, "Automatic")
        p.hidePeer = !p.hidePeer
        assertFresh(p, "Agent messages")
        p.filter = ""
        assertFresh(p, "filter cleared")
        p.dchChapters = Self.rows + [Self.chapter(13, "A new prompt")]
        assertFresh(p, "a new chapter")
        XCTAssertEqual(p.shownPrompts.first?.title, "A new prompt", "newest first")
        XCTAssertEqual(p.prompts.ordinalWidest, "13")
        p.chapterAnchors = ["f3a41c:100": 13]
        assertFresh(p, "anchors")
        XCTAssertEqual(p.prompts.ids.first, "a:f3a41c:100", "the anchor's id")
        p.dchChapters = nil
        assertFresh(p, "no chapters")
        XCTAssertTrue(p.shownPrompts.isEmpty)
    }

    /// Red at base (no promptsBuilt seam: one computation per body and per count) and with a tab switch clearing the memo.
    func testTabSwitchesAndTitlesDoNotRecomputePrompts() {
        let p = panel()
        p.apply(tasks: AgentPanePerfTests.tasks, memory: AgentPanePerfTests.memory)
        _ = p.prompts
        let built = p.promptsBuilt
        for t in [XrayTab.tasks, .memory, .prompts, .tasks, .prompts] {
            p.select(t)
            for tab in p.tabs { _ = p.title(tab); _ = p.spoken(tab) }
            _ = p.promptFooter(.prompts)
        }
        XCTAssertEqual(p.promptsBuilt, built, "tab switches and the strip's titles reuse the memo")
        p.filter = "api"
        _ = p.prompts; _ = p.count(.prompts); _ = p.hidden(.prompts)
        XCTAssertEqual(p.promptsBuilt, built + 1, "a filter change: one computation")
        let same = p.chapterAnchors
        p.chapterAnchors = same
        _ = p.prompts
        XCTAssertEqual(p.promptsBuilt, built + 1, "the same anchors again (a poll): no computation")
    }

    /// The per-tab counts and titles match the rows; the kept tabs are the visited ones still there.
    func testCountsTitlesAndKeptTabs() {
        let p = panel()
        p.apply(tasks: AgentPanePerfTests.tasks, memory: AgentPanePerfTests.memory)
        XCTAssertEqual(p.title(.prompts), "Prompts \(p.shown(.prompts).count)")
        XCTAssertEqual(p.count(.tasks), p.tasks?.open)
        XCTAssertEqual(p.keptTabs, [.prompts], "only the shown tab at open")
        let gen = p.listGen
        p.select(.memory)
        XCTAssertEqual(p.listGen, gen + 1, "a switch tells kept lists to start at their top")
        p.select(.tasks)
        XCTAssertEqual(Set(p.keptTabs), [.prompts, .memory, .tasks])
        XCTAssertTrue(p.topRow == nil)
        p.apply(tasks: (1, Data()), memory: (1, Data()))
        p.apply(tasks: AgentPanePerfTests.tasks, memory: AgentPanePerfTests.memory)
        XCTAssertEqual(p.keptTabs, [.prompts], "tabs that went are built again only when shown (not all at once on their return)")
    }

    /// The drawer keeps Tasks built behind Prompts; VoiceOver reads only the shown tab's field. Red with the hidden
    /// list left in the accessibility tree.
    func testHiddenKeptListIsNotInTheAccessibilityTree() throws {
        let p = panel()
        p.now = { XrayPanelTasksTests.now }
        p.apply(tasks: AgentPanePerfTests.tasks, memory: AgentPanePerfTests.memory)
        p.select(.tasks)
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        let (win, host) = AXTreeSupport.hosted(XrayPanelView(panel: p), CGSize(width: 440, height: 600))
        defer { win.contentView = nil; win.close(); p.stop() }
        func seen(_ t: [AXTreeNode]) -> [String] { t.filter { !$0.ignored }.map(\.label) }
        let before = seen(AXTreeSupport.poll(host) { seen($0).contains("Filter tasks") })
        XCTAssertTrue(before.contains("Filter tasks"), "the shown tab's field: \(before)")
        // #2114: the SHOWN kept list redraws on a data change (XrayKeptList == is equal only while hidden).
        func rowDrawn(_ t: [AXTreeNode], _ id: Int) -> Bool { t.contains { $0.named(prefix: "Pending task \(id),") } }
        let drawn = AXTreeSupport.poll(host) { rowDrawn($0, 1) && rowDrawn($0, 2) }
        XCTAssertTrue(rowDrawn(drawn, 1) && rowDrawn(drawn, 2), "both rows before the filter: \(seen(drawn))")
        p.filter = "Task number 2 with"
        let filtered = AXTreeSupport.poll(host) { !rowDrawn($0, 1) }
        XCTAssertFalse(rowDrawn(filtered, 1), "task 1 left the drawn list: \(seen(filtered))")
        XCTAssertTrue(rowDrawn(filtered, 2), "task 2 stays")
        p.filter = ""
        p.select(.prompts)
        let after = seen(AXTreeSupport.poll(host) { seen($0).contains("Filter prompts") })
        XCTAssertTrue(after.contains("Filter prompts"), "\(after)")
        XCTAssertFalse(after.contains("Filter tasks"), "the kept Tasks list is hidden from VoiceOver")
        XCTAssertEqual(Set(p.keptTabs), [.prompts, .tasks], "and kept")
        XCTAssertFalse(win.isVisible)
    }
}
