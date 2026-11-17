import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1467: the Agent Sessions header count, "6/17 active \u{B7} \u{1F916} 9" with the full split as its tooltip and
/// VoiceOver label. The text is a pure function of (state, sub-agents) per listed session; the narrow form is
/// measured offscreen (a never-shown hosting view drawn into a bitmap). No window shown, no event, no pasteboard.
extension AgentWindowD1Tests {
    typealias HeaderSet = [(state: AgentState?, agents: Int)]

    /// The literal table: session set -> (short, narrow, long). Zero parts are left out; singulars; no robot at 0.
    @MainActor
    func testAgentWindowHeaderCountTextTable() {
        let mixed: HeaderSet = [(.working, 3), (.working, 2), (.working, 0), (.working, 0), (.blocked, 1), (.blocked, 0),
                                (.done, 2), (.done, 0), (.done, 0), (.idle, 1)] + Array(repeating: (.idle, 0), count: 7)
        let table: [(String, HeaderSet, String, String, String)] = [
            ("4 working + 2 blocked + 3 done + 8 idle, 9 sub-agents", mixed,
             "6/17 active \u{B7} \u{1F916} 9", "6/17 \u{B7} \u{1F916} 9", "4 working, 2 need input, 3 done, 8 idle \u{B7} 9 sub-agents"),
            ("one idle, no sub-agents", [(.idle, 0)], "0/1 active", "0/1", "1 idle"),
            ("one blocked, one sub-agent", [(.blocked, 1)], "1/1 active \u{B7} \u{1F916} 1", "1/1 \u{B7} \u{1F916} 1", "1 needs input \u{B7} 1 sub-agent"),
            ("all idle", [(.idle, 0), (.idle, 0), (.idle, 0)], "0/3 active", "0/3", "3 idle"),
            ("one working, one done", [(.working, 0), (.done, 0)], "1/2 active", "1/2", "1 working, 1 done"),
            ("no state reads as idle", [(nil, 0)], "0/1 active", "0/1", "1 idle"),
            ("no sessions", [], "0/0 active", "0/0", ""),
        ]
        for (name, set, short, narrow, long) in table {
            let t = AgentSidebarTitleRow.countText(set)
            XCTAssertEqual(t.short, short, name)
            XCTAssertEqual(t.narrow, narrow, name)
            XCTAssertEqual(t.long, long, name)
        }
    }

    /// The header draws the short form when it fits and the "active"-less form when it does not (the numbers are never
    /// cut), says the long form to VoiceOver, and draws nothing with no sessions.
    @MainActor
    func testAgentWindowHeaderCountDropsActiveWhenNarrowAndSpeaksTheSplit() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        ThemeRuntime.scale = 1.0
        try withNewSessionPrefs {
            let sessions = [session("api", .working, agents: 2), session("api-qa", .blocked, agents: 1), session("web", .idle)]
            let full = wiringModel(store(sessions), SpawnCalls()), empty = wiringModel(store([]), SpawnCalls())
            defer { full.close(); empty.close() }
            let t = AgentSidebarTitleRow.countText([(.working, 2), (.blocked, 1), (.idle, 0)])
            XCTAssertEqual(t.short, "2/3 active \u{B7} \u{1F916} 3")
            @MainActor func width(_ s: String) -> CGFloat {
                NSHostingView(rootView: Text(s).font(Neon.font(10.5)).fixedSize()).fittingSize.width
            }
            let (wShort, wNarrow) = (width(t.short), width(t.narrow))
            XCTAssertGreaterThan(wShort, wNarrow + 8, "the word is wider than rounding")
            // The row without a count is the title and the buttons only: its ideal width is what the count's room adds to.
            let base = NSHostingView(rootView: AgentSidebarTitleRow(model: empty)).fittingSize.width
            let wide = base + wShort + 40, narrow = base + wNarrow + (wShort - wNarrow) / 2
            let tol: CGFloat = 1   // ink boxes round to whole points
            @MainActor func countInk(_ w: CGFloat, _ m: AgentWindowModel) throws -> CGRect? {
                let size = CGSize(width: w, height: sz(70))
                let right = size.width - sz(14) - AgentSidebarTitleRow.buttonsWidth - 2
                let title = try XCTUnwrap(ink(try wiringRender(AgentSidebarTitleRow(model: empty), size, backing: 2),
                                              CGRect(x: 0, y: 0, width: right, height: size.height)), "title")
                return ink(try wiringRender(AgentSidebarTitleRow(model: m), size, backing: 2),
                           CGRect(x: title.maxX + 2, y: 0, width: right - title.maxX - 2, height: size.height))
            }
            @MainActor func refInk(_ s: String) throws -> CGRect {
                let size = CGSize(width: 400, height: sz(40))
                let rep = try wiringRender(Text(s).font(Neon.font(10.5)).foregroundStyle(Neon.textSecondary).padding(.leading, 4), size, backing: 2)
                return try XCTUnwrap(ink(rep, CGRect(origin: .zero, size: size)), s)
            }
            let (refShort, refNarrow) = (try refInk(t.short), try refInk(t.narrow))
            XCTAssertGreaterThan(refShort.width, refNarrow.width + 8)
            let w = try XCTUnwrap(countInk(wide, full), "a count in the wide row")
            XCTAssertEqual(w.width, refShort.width, accuracy: tol, "wide: the short form")
            let n = try XCTUnwrap(countInk(narrow, full), "a count in the narrow row")
            XCTAssertEqual(n.width, refNarrow.width, accuracy: tol, "narrow: the form without \"active\", whole")
            XCTAssertTrue(try countInk(wide, empty) == nil, "no count with no sessions")
            // VoiceOver reads the full split.
            let tree = AXTreeSupport.tree(AgentSidebarTitleRow(model: full).frame(width: wide), CGSize(width: wide, height: sz(60))) {
                $0.contains { $0.label == t.long }
            }
            XCTAssertEqual(t.long, "1 working, 1 needs input, 1 idle \u{B7} 3 sub-agents")
            XCTAssertTrue(tree.contains { $0.label == t.long }, "\(tree.map(\.label))")
        }
    }
}
