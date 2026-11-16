import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #909 (#847 P1e Step C1): Stop both / Stop all N and Resume both / Resume all N in the Agent Sessions window's row
/// and History menus, through the island controller's stopGroup / resumeGroup (seams here: nothing runs). Offscreen:
/// entry lists only (no NSMenu), no window shown, no event posted, no dch.
extension AgentWindowD1Tests {
    @MainActor
    final class GroupCalls {
        var stops: [(session: AgentSession, names: [String])] = []
        var resumes: [DchHistoryRecord] = []
        func wire(_ m: AgentWindowModel) {
            m.stopGroup = { self.stops.append(($0, $1)); return true }
            m.resumeGroup = { self.resumes.append($0) }
        }
    }

    func groupItems(_ entries: [AgentWindowMenuEntry]) -> [AgentWindowMenuEntry] {
        entries.filter {
            switch $0 {
            case .item(_, _, .stopGroup), .item(_, _, .resumeGroup): true
            default: false
            }
        }
    }

    /// The operator's first case: a user with no group sees today's menus, entry for entry.
    @MainActor
    func testWindowGroupMenusAreTodaysWithoutAGroup() {
        let api = session("api", .working), web = session("web", .idle)
        let st = store([api, web], history: [record("old"), record("api-qa")])
        st.controlDch = bin([1, 38, 0])
        let live: [AgentWindowMenuEntry] = [
            .item("Rename\u{2026}", enabled: true, verb: .rename), .divider,
            .item("Restart agent\u{2026}", enabled: true, verb: .restart), .item("Stop\u{2026}", enabled: true, verb: .stop), .divider,
            .item("End\u{2026}", enabled: true, verb: .kill),
        ]
        let history: [AgentWindowMenuEntry] = [
            .item("Resume", enabled: true, verb: .resume), .item("Resume (no message)", enabled: true, verb: .resumeNoMessage),
            .divider, .item("Pin", enabled: true, verb: .pin), .item("Remove from History\u{2026}", enabled: true, verb: .remove),
        ]
        for suffix in ["", "-rev", "-"] {   // pairs off; a suffix no name carries; R909-2: a suffix with no letter is off
            st.pairSuffix = suffix
            XCTAssertEqual(AgentWindowControls.menu(api, store: st), live, suffix)
            XCTAssertEqual(AgentWindowControls.sessionMenu(web, store: st, ended: false), [.open(enabled: true), .divider] + live, suffix)
            XCTAssertEqual(AgentWindowControls.historyMenu(record("old"), store: st), history, suffix)
            XCTAssertEqual(AgentWindowControls.historyMenu(record("api-qa"), store: st), history, suffix)
        }
        st.pairSuffix = "-qa"   // api live with api-qa in History: a group, but its other member is not live
        XCTAssertEqual(AgentWindowControls.menu(api, store: st), live, "Stop both needs another live member")
        XCTAssertEqual(AgentWindowControls.historyMenu(record("api-qa"), store: st), history, "Resume both: api is live")
        XCTAssertEqual(AgentWindowControls.historyMenu(record("old"), store: st), history)
    }

    /// T24, T25: Stop both right under Stop with a live partner; it asks, naming both; the answer calls the controller's
    /// stopGroup once with the asked session and the names the menu drew, even when the partner went since (S4 step 2).
    @MainActor
    func testWindowGroupStopBothAsksThenCallsStopGroupOnce() throws {
        let api = session("api", .working), qa = session("api-qa", .blocked)
        let st = store([api, qa])
        st.controlDch = bin([1, 38, 0])
        st.pairSuffix = "-qa"
        let both = AgentWindowVerb.stopGroup(["api", "api-qa"])
        let menu = AgentWindowControls.menu(api, store: st)
        XCTAssertEqual(menu.count, 7)
        XCTAssertEqual(menu.dropFirst(3).first, .item("Stop\u{2026}", enabled: true, verb: .stop))
        XCTAssertEqual(menu.dropFirst(4).first, .item("Stop both (with api-qa)\u{2026}", enabled: true, verb: both), "right after Stop")
        XCTAssertEqual(groupItems(AgentWindowControls.menu(qa, store: st)),
                       [.item("Stop both (with api)\u{2026}", enabled: true, verb: both)], "the sidekick's row: the same group")
        // Off, saying why: a control dch older than the masters (1.30.0) closes the gate (the note says why, as for
        // Stop), then a member whose master cannot stop.
        st.controlDch = bin([1, 24, 0])
        let why = try XCTUnwrap(st.resumeGate.refusal)
        XCTAssertEqual(groupItems(AgentWindowControls.menu(api, store: st)),
                       [.item("Stop both (with api-qa)", enabled: false, verb: both)])
        XCTAssertEqual(AgentWindowControls.menu(api, store: st).last, .note("Controls \(why)"))
        st.controlDch = bin([1, 38, 0])
        var old = qa
        old.version = "1.23.0"
        st.sessions = [api, old]
        XCTAssertEqual(groupItems(AgentWindowControls.menu(api, store: st)),
                       [.item("Stop both (with api-qa) (restart api-qa first)", enabled: false, verb: both)])
        st.sessions = [api, qa]
        // Ask: the strip's words; nothing runs until the answer.
        let m = windowModel(st)
        let calls = Calls(), groups = GroupCalls()
        calls.wire(m)
        groups.wire(m)
        m.setVisible(true)
        defer { m.close() }
        m.ask(both, api)
        XCTAssertEqual(m.confirming, AgentWindowConfirm(verb: both, key: api.key))
        XCTAssertEqual(m.confirmingOthers.map(\.name), ["api-qa"])
        XCTAssertEqual(AgentWindowControls.question(both, api),
                       "Stop api and api-qa? Claude Code is paused in both and both sessions end. Resume them later from History.")
        XCTAssertEqual(AgentWindowControls.question(both, api, others: m.confirmingOthers),
                       AgentWindowControls.question(both, api) + AgentWindowControls.blockedSentence, "api-qa waits on a prompt")
        XCTAssertEqual(AgentWindowControls.confirmTitle(both), "Stop both")
        XCTAssertTrue(groups.stops.isEmpty && calls.all.isEmpty, "asking runs nothing")
        m.confirm(true)
        XCTAssertEqual(groups.stops.count, 1)
        XCTAssertEqual(groups.stops.last?.session.key, api.key)
        XCTAssertEqual(groups.stops.last?.names, ["api", "api-qa"])
        XCTAssertTrue(calls.all.isEmpty, "never the single Stop")
        // The partner ended between the question and the answer: the controller decides (its "is not listed any more").
        m.ask(both, api)
        st.sessions = [api]
        m.confirm(true)
        XCTAssertEqual(groups.stops.count, 2)
        XCTAssertEqual(groups.stops.last?.names, ["api", "api-qa"])
        // A gate closed since the question: nothing runs, the row says why.
        st.sessions = [api, qa]
        m.ask(both, api)
        st.controlDch = bin([1, 24, 0])
        m.confirm(true)
        XCTAssertEqual(groups.stops.count, 2)
        XCTAssertEqual(m.refusalText(.live(api.key)), "Not run: Controls \(why)")
    }

    /// Stop all 3 / Resume all 3: a group of three in group order; a session in no group gets no item.
    @MainActor
    func testWindowGroupOfThreeReadsAllThree() {
        let f1 = session("feat-1", .idle), f2 = session("feat-2", .idle), qa = session("feat-qa", .idle)
        let other = session("other", .idle)
        let st = store([qa, f2, f1, other])
        st.controlDch = bin([1, 38, 0])
        st.pairSuffix = "-qa"
        let all3 = AgentWindowVerb.stopGroup(["feat-1", "feat-2", "feat-qa"])
        XCTAssertEqual(groupItems(AgentWindowControls.menu(f2, store: st)),
                       [.item("Stop all 3 (with feat-1, feat-qa)\u{2026}", enabled: true, verb: all3)])
        XCTAssertEqual(groupItems(AgentWindowControls.menu(other, store: st)), [], "no group: no item")
        XCTAssertEqual(AgentWindowControls.question(all3, f2),
                       "Stop feat-1, feat-2 and feat-qa? Claude Code is paused in all three and the sessions end."
                       + " Resume them later from History.")
        XCTAssertEqual(AgentWindowControls.confirmTitle(all3), "Stop all 3")
        st.sessions = [other]
        st.history = [record("feat-qa"), record("feat-2"), record("feat-1")]
        let menu = AgentWindowControls.historyMenu(record("feat-qa"), store: st)
        XCTAssertEqual(menu.dropFirst().first, .item("Resume all 3 (with feat-1, feat-2)", enabled: true, verb: .resumeGroup),
                       "right after Resume, mains first")
        XCTAssertEqual(groupItems(AgentWindowControls.historyMenu(record("other"), store: st)), [])
    }

    /// T26, T27: Resume both after Resume when no member is live; it runs at once (no question) through resumeGroup;
    /// the History detail's pills are the same size with and without a group (no pill added, nothing re-centres).
    @MainActor
    func testWindowGroupResumeBothActsAtOnce() throws {
        let api = record("api"), qa = record("api-qa", ago: 7200)
        let st = store([], history: [api, qa])
        st.controlDch = bin([1, 38, 0])
        st.pairSuffix = "-qa"
        let menu = AgentWindowControls.historyMenu(api, store: st)
        XCTAssertEqual(menu.count, 6)
        XCTAssertEqual(menu.dropFirst().first, .item("Resume both (with api-qa)", enabled: true, verb: .resumeGroup))
        XCTAssertEqual(groupItems(AgentWindowControls.historyMenu(qa, store: st)),
                       [.item("Resume both (with api)", enabled: true, verb: .resumeGroup)])
        st.controlDch = nil
        XCTAssertEqual(groupItems(AgentWindowControls.historyMenu(api, store: st)), [], "the resume gate refuses: no item")
        st.controlDch = bin([1, 38, 0])
        st.sessions = [session("api-qa", .idle)]
        XCTAssertEqual(groupItems(AgentWindowControls.historyMenu(api, store: st)), [], "a member is live: no item")
        st.sessions = []
        let m = windowModel(st)
        let calls = Calls(), groups = GroupCalls()
        calls.wire(m)
        groups.wire(m)
        m.setVisible(true)
        defer { m.close() }
        m.act(.resumeGroup, api)
        XCTAssertEqual(groups.resumes.map(\.id), [api.id], "once, the record itself")
        XCTAssertTrue(m.confirming == nil, "Resume both asks nothing")
        XCTAssertTrue(calls.records.isEmpty, "never the single Resume")
        func size(_ r: DchHistoryRecord) -> CGSize {
            NSHostingView(rootView: AgentHistoryButtons(store: st, record: r, act: { _ in })).fittingSize
        }
        let grouped = size(api)
        st.pairSuffix = ""
        XCTAssertEqual(size(api), grouped, "the detail's pills do not move when a group appears")
    }

    /// R909-1: a menu reads the groups its caller computed once per draw (the sidebar's), never its own per row.
    @MainActor
    func testWindowGroupMenusReadTheCallersGroups() {
        let api = session("api", .idle), qa = session("api-qa", .idle)
        let st = store([api, qa], history: [record("web"), record("web-qa")])
        st.controlDch = bin([1, 38, 0])
        st.pairSuffix = "-qa"
        XCTAssertEqual(groupItems(AgentWindowControls.menu(api, store: st, groups: [])), [], "the caller's (none) win")
        XCTAssertEqual(groupItems(AgentWindowControls.historyMenu(record("web"), store: st, groups: [])), [])
        let groups = st.groups
        XCTAssertEqual(groupItems(AgentWindowControls.menu(api, store: st, groups: groups)),
                       groupItems(AgentWindowControls.menu(api, store: st)))
        XCTAssertEqual(groupItems(AgentWindowControls.historyMenu(record("web"), store: st, groups: groups)),
                       [.item("Resume both (with web-qa)", enabled: true, verb: .resumeGroup)])
        XCTAssertEqual(groupItems(AgentWindowControls.rowMenu(api, store: st, splits: false, side: nil, groups: [])), [])
    }
}
