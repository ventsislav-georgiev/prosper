import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1455: Row details has a toggle for every part of a session row: model, effort, state word, agents, merged, open PRs,
/// age and the Command 1-9 chip. Model and effort, on, show only where they differ from the Default model / effort.
/// Offscreen only: views are measured in hosting views that are never shown; no menu is popped, no event is posted; the
/// defaults are the test's scratch Preferences domain. Model ids are made up in the documented shape.
final class AgentRowDetailsTests: XCTestCase {
    static let now: TimeInterval = 1_800_000_000
    static let dir = "/tmp/dch-test"

    /// A live Claude session (it has a transcript path), idle 4 minutes: "Opus 4.7", "high".
    func session(model: String? = "claude-opus-4-7", effort: String? = "high") -> AgentSession {
        var s = AgentSession(key: AgentSessionKey(dir: Self.dir, name: "api"), alias: "", activity: Self.now - 240,
                             state: .idle, agents: 2, transcriptPath: "/Users/example/t/api.jsonl")
        s.model = model
        s.effort = effort
        s.meta = DchSessionMeta(merged: 3)
        return s
    }

    func details(_ change: (inout AgentIslandRowDetails) -> Void) -> AgentIslandRowDetails {
        var d = AgentIslandRowDetails()
        change(&d)
        return d
    }

    @MainActor
    func sidebar(_ d: AgentIslandRowDetails, _ s: AgentSession? = nil) -> AgentSidebarRowView {
        AgentSidebarRowView(row: AgentSidebar.row(s ?? session(), details: d, now: Self.now), selected: false, number: 4, show: d)
    }

    @MainActor
    func island(_ d: AgentIslandRowDetails, _ s: AgentSession? = nil) -> String {
        AgentIslandRow.accessibilityLabel(s ?? session(), now: Self.now, show: d)
    }

    @MainActor
    func ideal<V: View>(_ v: V) -> CGSize { NSHostingView(rootView: v.fixedSize()).fittingSize }

    // MARK: The lists

    /// Settings' toggles and the sidebar "..." Row details items, each a literal list, and the same set of labels.
    @MainActor
    func testSettingsAndSidebarMenuListTheSameParts() throws {
        let settings = AgentIslandRowDetailsSection.toggles.map(\.label)
        XCTAssertEqual(settings, ["Model", "Effort", "State", "Agents", "Shells", "Merged", "Open PRs", "Age", "Shortcut"])
        let st = AgentIslandStore(geometry: AgentWindowD1Tests.geometry)
        let menu = AgentWindowControls.sidebarMenu(store: st, autoAllow: false)
        let items = menu.compactMap { e -> [AgentSidebarMenuEntry]? in
            if case .submenu(AgentWindowControls.rowDetailsLabel, _, let items) = e { return items }
            return nil
        }.first ?? []
        let labels = items.compactMap { e -> String? in
            if case .item(let label, _, _, _) = e { return label }
            return nil
        }
        XCTAssertEqual(labels, ["Model", "Effort", "State", "Agents", "Shells", "Merged", "Open PRs", "Age", "Shortcut"])
        XCTAssertEqual(Set(labels), Set(settings))
        XCTAssertEqual(labels.count, settings.count)
        XCTAssertFalse(AgentIslandRowDetailsSection.footer.contains("besides its title, state and age"),
                       "state and age are toggles now")
    }

    // MARK: Stored values

    static let newKeys = ["agentIslandShowModel", "agentIslandShowEffort", "agentIslandShowState", "agentIslandShowAge",
                          "agentIslandShowShortcut", "agentIslandShowShells"]
    static let oldKeys = ["agentIslandShowAgents", "agentIslandShowOpenPRs", "agentIslandShowMerged"]
    static let defaultKeys = ["agentIslandDefaultModel", "agentIslandDefaultEffort"]

    /// Clears the keys in the scratch Preferences domain for one test and puts back whatever was there.
    func clearKeys() {
        let keys = Self.newKeys + Self.oldKeys + Self.defaultKeys
        let saved = keys.map { Preferences.defaults.object(forKey: $0) }
        addTeardownBlock {
            for (k, v) in zip(keys, saved) {
                if let v { Preferences.defaults.set(v, forKey: k) } else { Preferences.defaults.removeObject(forKey: k) }
            }
        }
        keys.forEach(Preferences.defaults.removeObject(forKey:))
    }

    /// A value stored before #1455 (the three old keys only) loads with every new part on.
    func testOldStoredValueLoadsWithTheNewPartsOn() {
        clearKeys()
        Preferences.defaults.set(false, forKey: "agentIslandShowAgents")
        Preferences.defaults.set(true, forKey: "agentIslandShowMerged")
        let d = Preferences.agentIslandRowDetails
        XCTAssertFalse(d.agents, "the old key still reads")
        XCTAssertTrue(d.merged)
        XCTAssertTrue(d.openPRs)
        XCTAssertTrue(d.model, "Model on (when not the default)")
        XCTAssertTrue(d.effort, "Effort on (when not the default)")
        XCTAssertTrue(d.state, "State on")
        XCTAssertTrue(d.age, "Age on")
        XCTAssertTrue(d.shortcut, "Shortcut on")
        XCTAssertTrue(d.shells, "#1583: Shells on")
        for k in Self.newKeys { XCTAssertFalse(SyncedKeys.isSynced(k), "\(k): per Mac") }
    }

    /// Each new part round-trips on its own key alone; the Default model and effort come along from their keys.
    func testNewPartsRoundTripOnTheirOwnKeys() {
        clearKeys()
        let paths: [(WritableKeyPath<AgentIslandRowDetails, Bool>, String)] = [
            (\.model, "agentIslandShowModel"), (\.effort, "agentIslandShowEffort"), (\.state, "agentIslandShowState"),
            (\.age, "agentIslandShowAge"), (\.shortcut, "agentIslandShowShortcut"), (\.shells, "agentIslandShowShells"),
        ]
        for (path, key) in paths {
            Self.newKeys.forEach(Preferences.defaults.removeObject(forKey:))
            var one = AgentIslandRowDetails()
            one[keyPath: path] = false
            Preferences.agentIslandRowDetails = one
            XCTAssertEqual(Preferences.agentIslandRowDetails, one, key)
            XCTAssertEqual(Self.newKeys.filter { Preferences.defaults.object(forKey: $0) != nil }, [key])
        }
        Preferences.agentIslandDefaultModel = "opus"
        Preferences.agentIslandDefaultEffort = "high"
        XCTAssertEqual(Preferences.agentIslandRowDetails.defaultModel, "opus")
        XCTAssertEqual(Preferences.agentIslandRowDetails.defaultEffort, "high")
    }

    // MARK: Model and effort against the Default

    func testModelShowsOnlyWhereItDiffersFromTheDefault() {
        let same = details { $0.defaultModel = "claude-opus-4-7" }
        XCTAssertTrue(same.modelEffort(model: "Opus 4.7", effort: nil).model == nil, "same as the Default: hidden")
        XCTAssertEqual(same.modelEffort(model: "Sonnet 4.5", effort: nil).model, "Sonnet 4.5", "different: shown")
        XCTAssertEqual(same.modelEffort(model: "Opus 4.6", effort: nil).model, "Opus 4.6", "another version: shown")
        XCTAssertEqual(AgentIslandRowDetails().modelEffort(model: "Opus 4.7", effort: nil).model, "Opus 4.7",
                       "unset Default: shown")
        let alias = details { $0.defaultModel = "opus" }
        XCTAssertTrue(alias.modelEffort(model: "Opus 4.7", effort: nil).model == nil, "alias: the family at any version")
        XCTAssertTrue(alias.modelEffort(model: "Opus 5.5", effort: nil).model == nil)
        XCTAssertEqual(alias.modelEffort(model: "Sonnet 4.5", effort: nil).model, "Sonnet 4.5")
        let off = details { $0.model = false }
        XCTAssertTrue(off.modelEffort(model: "Sonnet 4.5", effort: nil).model == nil, "off: never")
        XCTAssertFalse(off.modelEffort(model: nil, effort: nil).modelSlot, "off: no slot")
        XCTAssertTrue(AgentIslandRowDetails().modelEffort(model: nil, effort: nil).modelSlot, "unknown: the slot stays")
    }

    func testEffortShowsOnlyWhereItDiffersFromTheDefault() {
        let high = details { $0.defaultEffort = "high" }
        XCTAssertTrue(high.modelEffort(model: "Opus 4.7", effort: "high").effort == nil, "same as the Default: hidden")
        XCTAssertEqual(high.modelEffort(model: "Opus 4.7", effort: "low").effort, "low", "different: shown")
        XCTAssertEqual(AgentIslandRowDetails().modelEffort(model: "Opus 4.7", effort: "high").effort, "high",
                       "unset Default: shown")
        let off = details { $0.effort = false }
        XCTAssertTrue(off.modelEffort(model: "Opus 4.7", effort: "low").effort == nil, "off: never")
    }

    /// Both at the Default: no badge slot, the title gets its width back; the words drop them too, sidebar and island.
    @MainActor
    func testModelAndEffortAtTheDefaultLeaveTheRow() {
        let at = details { $0.defaultModel = "opus"; $0.defaultEffort = "high" }
        let hidden = sidebar(at), all = sidebar(.all)
        XCTAssertEqual(ideal(hidden.titleLine(badges: true)).width, ideal(all.titleLine(badges: false)).width,
                       "no slot: the line is the title's")
        XCTAssertLessThan(ideal(hidden.titleLine(badges: true)).width, ideal(all.titleLine(badges: true)).width)
        XCTAssertFalse(hidden.accessibilityWords.contains("model"))
        XCTAssertTrue(all.accessibilityWords.contains("model Opus 4.7, effort high"))
        XCTAssertFalse(island(at).contains("model"))
        XCTAssertTrue(island(.all).contains("model Opus 4.7, effort high"))
        let other = details { $0.defaultModel = "opus"; $0.defaultEffort = "low" }
        XCTAssertTrue(sidebar(other).accessibilityWords.contains("effort high"), "the effort alone when it differs")
        XCTAssertFalse(sidebar(other).accessibilityWords.contains("model Opus"))
        XCTAssertTrue(island(other).contains("effort high"))
    }

    // MARK: One row per part: off hides it in the sidebar row and the island row

    @MainActor
    func testStateOffHidesTheStateWord() {
        let word = AgentState.idle.label, off = details { $0.state = false }
        XCTAssertTrue(sidebar(.all).accessibilityWords.contains(word))
        // R1455a-m1: the coloured mark still shows the state, so State off hides the DRAWN word only: both labels keep it.
        XCTAssertFalse(sidebar(off).stateShown, "the word is not drawn")
        XCTAssertTrue(sidebar(off).accessibilityWords.contains(word), "VoiceOver keeps the state")
        XCTAssertLessThan(ideal(sidebar(off).detailLine([])).width, ideal(sidebar(.all).detailLine([])).width)
        XCTAssertTrue(island(.all).contains(word))
        XCTAssertTrue(island(off).contains(word), "the island's label keeps the state too")
    }

    /// R1455a-s1: with a Default set an unknown model (effort) takes no slot, so arriving equal to it changes nothing.
    @MainActor
    func testUnknownModelWithADefaultTakesNoSlot() {
        let at = details { $0.defaultModel = "opus"; $0.defaultEffort = "high" }
        let me = at.modelEffort(model: nil, effort: nil)
        XCTAssertFalse(me.modelSlot)
        XCTAssertFalse(me.effortSlot)
        XCTAssertTrue(details { $0.defaultModel = "opus" }.modelEffort(model: nil, effort: nil).effortSlot, "no Default effort: as before")
        XCTAssertTrue(details { $0.defaultEffort = "high" }.modelEffort(model: nil, effort: nil).modelSlot, "no Default model: as before")
        let pixel = AXTreeSupport.devicePixel
        let before = ideal(sidebar(at, session(model: nil, effort: nil)).titleLine(badges: true)).width
        let after = ideal(sidebar(at, session()).titleLine(badges: true)).width
        XCTAssertEqual(before, after, accuracy: pixel, "the title keeps its width when the model arrives at the Default")
    }

    /// R1455a-s2: one trailing "[...]" goes from the Default and from the row's model before the label compare.
    func testBracketSuffixIsStripped() {
        let cases: [(String, String)] = [("opus[1m]", "claude-opus-4-7[1m]"), ("opus[1m]", "claude-opus-4-7"),
                                         ("claude-opus-4-7[1m]", "claude-opus-4-7[1m]")]
        for (def, raw) in cases {
            let d = details { $0.defaultModel = def }
            let label = AgentModelEffort.shortName(raw)   // what Row.model carries
            XCTAssertTrue(d.isDefaultModel(label), "\(def) vs \(raw)")
            XCTAssertTrue(d.modelEffort(model: label, effort: nil).model == nil, "\(def) vs \(raw)")
        }
        XCTAssertFalse(details { $0.defaultModel = "opus[1m]" }.isDefaultModel("Sonnet 4.5"))
    }

    @MainActor
    func testAgeOffHidesTheAge() {
        let off = details { $0.age = false }
        XCTAssertTrue(sidebar(.all).accessibilityWords.contains("4m ago"))
        XCTAssertFalse(sidebar(off).accessibilityWords.contains("4m ago"))
        XCTAssertLessThan(ideal(sidebar(off).detailLine([])).width, ideal(sidebar(.all).detailLine([])).width)
        XCTAssertTrue(island(.all).contains("4m ago"))
        XCTAssertFalse(island(off).contains("4m ago"))
    }

    /// The Command chip is the sidebar's only (the island's rows have none): its number and its column go.
    @MainActor
    func testShortcutOffHidesTheCommandChip() {
        let off = details { $0.shortcut = false }
        XCTAssertEqual(sidebar(.all).shownNumber, 4)
        XCTAssertTrue(sidebar(off).shownNumber == nil)
        XCTAssertLessThan(ideal(sidebar(off).fullBody).width, ideal(sidebar(.all).fullBody).width, "its column goes")
    }

    @MainActor
    func testAgentsMergedAndOpenPRsOffHideTheirCounts() {
        var s = session()
        s.meta = DchSessionMeta(openPRs: [DchSessionMeta.PR(url: "https://github.com/example-org/api/pull/12", repo: "example-org/api", num: 12, title: "Fix")], merged: 3)
        let agents = AgentSidebar.Count.agents.words(2), merged = AgentSidebar.Count.merged.words(3)
        let open = AgentSidebar.Count.open.words(1)
        XCTAssertTrue(sidebar(.all, s).accessibilityWords.contains(agents))
        XCTAssertFalse(sidebar(details { $0.agents = false }, s).accessibilityWords.contains(agents))
        XCTAssertTrue(sidebar(.all, s).accessibilityWords.contains(merged))
        XCTAssertFalse(sidebar(details { $0.merged = false }, s).accessibilityWords.contains(merged))
        XCTAssertTrue(sidebar(.all, s).accessibilityWords.contains(open))
        XCTAssertFalse(sidebar(details { $0.openPRs = false }, s).accessibilityWords.contains(open))
        XCTAssertTrue(island(.all, s).contains(agents))
        XCTAssertFalse(island(details { $0.agents = false }, s).contains(agents))
        XCTAssertTrue(island(.all, s).contains(merged))
        XCTAssertFalse(island(details { $0.merged = false }, s).contains(merged))
        XCTAssertTrue(island(.all, s).contains(open))
        XCTAssertFalse(island(details { $0.openPRs = false }, s).contains(open))
    }

    /// A running action's text stands in the state word's place and stays with State off; a History row keeps its words.
    @MainActor
    func testStateOffKeepsAnActionAndHistoryRows() {
        let off = details { $0.state = false }
        let busy = AgentSidebar.row(session(), details: off, now: Self.now, action: AgentIsland.stoppingText)
        XCTAssertTrue(AgentSidebarRowView(row: busy, selected: false, show: off).stateShown)
        var r = DchHistoryRecord(key: AgentSessionKey(dir: Self.dir, name: "old"))
        r.ended = Self.now - 7200
        r.updated = Self.now - 7200
        r.end = "exit 0"
        let v = AgentSidebarRowView(row: AgentSidebar.row(r, now: Self.now), selected: false, show: details { $0.state = false; $0.age = false })
        XCTAssertTrue(v.stateShown)
        XCTAssertTrue(v.ageShown)
    }
}
