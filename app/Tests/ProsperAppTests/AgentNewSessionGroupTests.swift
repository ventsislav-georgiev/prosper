import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #1214: the New session form's "Add to group": the choice shown only while a group runs, what it fills (folder,
/// command, the next name), the namer's table, the sidekick's first prompt naming its main, the row at UI scale 0.7,
/// 0.85 and 1.0, and its accessibility labels. Offscreen only: an AgentsNSWindow that is never shown, ordered or made
/// key; the accessibility tree is read through AXTreeSupport (this process's flags, put back). No dch runs: the spawn is
/// `spawnSession`'s recorder and the members' commands come from the `memberRecords` seam. No pasteboard, menu or
/// panel; Preferences are the XCTest in-memory store, saved and restored per row.
@MainActor
final class AgentNewSessionGroupTests: XCTestCase {
    private let d1 = AgentWindowD1Tests()

    /// A live session in the test socket dir with a folder under /Users/example.
    func live(_ name: String, cwd: String) -> AgentSession {
        var s = d1.mapped(name)
        s.cwd = cwd
        return s
    }

    /// A store with the Settings suffix "-qa" (the pair suffix the island sets from it).
    func store(_ sessions: [AgentSession], history: [DchHistoryRecord] = []) -> AgentIslandStore {
        let st = d1.store(sessions, history: history)
        st.pairSuffix = "-qa"
        return st
    }

    /// The members' live records: mains run "claude --verbose", sidekicks (names holding "-qa") "claude --debug".
    nonisolated static func records(_ sessions: [AgentSession]) -> [DchHistoryRecord] {
        sessions.map { s in
            var r = DchHistoryRecord(key: s.key)
            r.argv = ["claude", s.name.contains("-qa") ? "--debug" : "--verbose"]
            var a = DchHistoryRecord.Agent()
            a.kind = "claude"
            r.agent = a
            return r
        }
    }

    func model(_ st: AgentIslandStore, _ spawns: AgentWindowD1Tests.SpawnCalls) -> AgentWindowModel {
        let m = d1.wiringModel(st, spawns)
        m.memberRecords = { Self.records($0) }
        return m
    }

    /// The tree once the Folder field is there; the choice's and the role's nodes (not a label's text).
    func tree(_ host: NSView) -> [AXTreeNode] {
        d1.settle(host)
        return AXTreeSupport.poll(host) { t in t.contains { $0.named("Folder") && $0.frame.width > 0 } }
    }

    func node(_ t: [AXTreeNode], _ label: String) -> AXTreeNode? {
        t.last { $0.role != "AXStaticText" && $0.named(prefix: label) && $0.frame.width > 0 }
    }

    // MARK: Absent with no group running

    /// No group running (two plain sessions; a sidekick whose main only ended): no choice, and the fields sit exactly
    /// where they do with no session at all; with a group running the row is there and every field moves down by one
    /// delta (so its absence leaves no gap).
    func testNoGroupRunningShowsNoChoiceAndTheFormKeepsItsRows() throws {
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        try d1.withNewSessionPrefs {
            @MainActor func fields(_ sessions: [AgentSession], history: [DchHistoryRecord] = []) throws -> (frames: [CGRect], tree: [AXTreeNode], groups: [AgentGroup]) {
                let spawns = AgentWindowD1Tests.SpawnCalls(), m = model(store(sessions, history: history), spawns)
                defer { m.close() }
                let (win, host) = d1.formWindow(m, CGSize(width: sz(560), height: sz(700)))
                defer { win.close() }
                m.openNewSession()
                let t = tree(host)
                XCTAssertTrue(spawns.calls.isEmpty)
                return (d1.formFields(host).map { host.convert($0.bounds, from: $0) }, t, m.newSessionGroups)
            }
            let none = try fields([])
            let plain = try fields([live("api", cwd: "/Users/example/api"), live("web", cwd: "/Users/example/web")])
            let ended = try fields([live("web-qa", cwd: "/Users/example/web")], history: [d1.record("web")])
            for (r, what) in [(none, "no session"), (plain, "two plain sessions"), (ended, "a group whose main ended")] {
                XCTAssertTrue(r.groups.isEmpty, what)
                XCTAssertTrue(node(r.tree, AgentNewSessionView.groupChoiceLabel) == nil, "no choice: \(what)")
                XCTAssertTrue(node(r.tree, AgentNewSessionView.groupRoleLabel) == nil, "no role: \(what)")
                XCTAssertFalse(r.tree.contains { $0.named("Group") }, "no row label: \(what)")
                XCTAssertEqual(r.frames.count, 3, "Folder, Name, Command: \(what)")
                XCTAssertEqual(r.frames, none.frames, "the fields where they are with no session: \(what)")
            }
            let group = try fields([live("api", cwd: "/Users/example/api"), live("api-qa", cwd: "/Users/example/api")])
            XCTAssertEqual(group.groups.map(\.stem), ["api"])
            XCTAssertTrue(node(group.tree, AgentNewSessionView.groupChoiceLabel) != nil, "the choice with a group running")
            XCTAssertEqual(group.frames.count, 3)
            let deltas = zip(none.frames, group.frames).map { $0.minY - $1.minY }
            XCTAssertGreaterThan(abs(deltas.first ?? 0), sz(9), "the row takes room only when shown (half its height: the form is centred, #1479)")
            let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
            XCTAssertEqual(Set(deltas.map { ($0 / pixel).rounded() }).count, 1, "every field by one delta: \(deltas)")
        }
    }

    // MARK: The choice lists the running groups and fills

    func testChoiceListsRunningGroupsAndFillsFolderHarnessAndName() throws {
        try d1.withNewSessionPrefs {
            let st = store([live("api", cwd: "/Users/example/api"), live("api-qa", cwd: "/Users/example/api"),
                            live("web", cwd: "/Users/example/web"), live("web-qa", cwd: "/Users/example/web"),
                            live("solo", cwd: "/Users/example/solo")],
                           history: [d1.record("web-3")])
            let spawns = AgentWindowD1Tests.SpawnCalls(), m = model(st, spawns)
            defer { m.close() }
            m.openNewSession()
            XCTAssertEqual(m.newSessionGroups.map(\.stem), ["api", "web"], "running groups by stem; solo is in none")
            XCTAssertEqual(m.newSession?.folder, "~/api", "the last folder before a choice")

            m.setNewSessionGroup("web", sidekick: false)
            XCTAssertEqual(m.newSession?.group, AgentNewSessionForm.GroupPick(stem: "web", sidekick: false))
            XCTAssertEqual(m.newSession?.folder, "~/web", "the group's folder")
            XCTAssertEqual(m.newSession?.command, "claude --verbose", "the main's command")
            XCTAssertEqual(m.newSessionName, "", "#1731: no generated group name (was: web-4)")
            XCTAssertEqual(m.newSession?.name, "", "nothing typed")
            XCTAssertTrue(m.newSessionGroupError == nil && !m.canStartNewSession, "Start waits for a typed name")
            m.setNewSessionName("web-4")

            m.setNewSessionGroup("web", sidekick: true)
            XCTAssertEqual(m.newSession?.command, "claude --debug", "the sidekick's command")
            XCTAssertEqual(m.newSessionName, "", "the role choice leaves the name empty (was: web-qa-2)")
            m.setNewSessionName("web-qa-9")
            XCTAssertEqual(m.newSessionName, "web-qa-9", "the person types it")
            m.setNewSessionName("web-qa-2")
            m.setNewSessionSidekick(true)
            XCTAssertEqual(m.newSession?.sidekick, false, "one session joins: no second spawn")

            XCTAssertTrue(m.startNewSession())
            XCTAssertEqual(spawns.calls.count, 1)
            XCTAssertEqual(spawns.calls.last?.name, "web-qa-2")
            XCTAssertEqual(spawns.calls.last?.folder, "/Users/example/web")
            XCTAssertEqual(spawns.calls.last?.argv.first, "claude")
            XCTAssertEqual(spawns.calls.last?.argv.contains("--debug"), true, "the sidekick's harness: \(spawns.calls.last?.argv ?? [])")
            m.cancelNewSession()

            m.openNewSession()
            m.setNewSessionGroup("api", sidekick: false)
            m.setNewSessionName("api-2")
            st.sessions.removeAll { $0.name == "api-qa" }
            XCTAssertEqual(m.newSessionGroupError, "api is not running any more")
            XCTAssertFalse(m.canStartNewSession, "a stopped group starts nothing")
            m.setNewSessionGroup(nil, sidekick: false)
            XCTAssertTrue(m.newSession?.group == nil && m.newSessionGroupError == nil, "None")
            XCTAssertEqual(spawns.calls.count, 1)
        }
    }

    // MARK: The sidekick's first prompt names its main

    func testSidekickFirstPromptNamesTheSelectedMainElseTheFirst() throws {
        try d1.withNewSessionPrefs {
            Preferences.agentIslandSidekickPrompt = "Work for $name."
            let api = live("api", cwd: "/Users/example/api"), api2 = live("api-2", cwd: "/Users/example/api")
            let web = live("web", cwd: "/Users/example/web")
            let st = store([api, api2, live("api-qa", cwd: "/Users/example/api"), web])
            let spawns = AgentWindowD1Tests.SpawnCalls(), m = model(st, spawns)
            defer { m.close() }
            XCTAssertEqual(m.newSessionGroups.first?.mains, ["api", "api-2"])
            for (selected, main) in [(api2, "api-2"), (web, "api"), (api, "api")] {
                m.select(.live(selected.key))
                m.openNewSession()
                m.setNewSessionGroup("api", sidekick: true)
                XCTAssertEqual(m.newSession?.prompt, "Work for \(main).", "opened on \(selected.name)")
                XCTAssertEqual(m.newSession?.promptShown, true)
                XCTAssertEqual(m.newSessionName, "", "#1731: no generated group name (was: api-qa-2)")
                m.setNewSessionGroup("api", sidekick: false)
                XCTAssertEqual(m.newSession?.prompt, "", "a main: the filled prompt taken back")
                m.cancelNewSession()
            }
            XCTAssertTrue(spawns.calls.isEmpty)
        }
    }

    /// Switching to another Mac drops the group and takes back a prompt the Sidekick choice filled, as None does; a prompt
    /// the person edited stays. (Old code: setNewSessionHost cleared f.group only, so "Work for api." stayed.)
    func testSwitchingHostTakesBackTheGroupPromptUnlessEdited() throws {
        try d1.withNewSessionPrefs {
            Preferences.agentIslandSidekickPrompt = "Work for $name."
            let st = store([live("api", cwd: "/Users/example/api"), live("api-qa", cwd: "/Users/example/api")])
            let spawns = AgentWindowD1Tests.SpawnCalls(), m = model(st, spawns)
            defer { m.close() }
            m.openNewSession()
            m.setNewSessionPrompt("Mine.")
            m.setNewSessionGroup("api", sidekick: true)
            XCTAssertEqual(m.newSession?.prompt, "Work for api.")
            m.setNewSessionHost("example-host")
            XCTAssertTrue(m.newSession?.group == nil, "no group on another Mac")
            XCTAssertEqual(m.newSession?.prompt, "Mine.", "the prompt before the choice")   // red before the fix: "Work for api."
            m.setNewSessionHost(nil)
            m.setNewSessionGroup("api", sidekick: true)
            m.setNewSessionPrompt("Edited.")
            m.setNewSessionHost("example-host")
            XCTAssertTrue(m.newSession?.group == nil)
            XCTAssertEqual(m.newSession?.prompt, "Edited.", "an edited prompt stays")
            XCTAssertTrue(spawns.calls.isEmpty)
        }
    }

    // MARK: #1400 Add session to this group

    /// A group row's "Add session to this group" opens the form with that group chosen as a main, its folder and harness
    /// filled; the person picks the role. On an open form it chooses the group there, and a form on another Mac comes
    /// back to this one. A row alone has no item.
    func testAddSessionToGroupPrefillsGroupFolderAndHarness() throws {
        try d1.withNewSessionPrefs {
            let st = store([live("api", cwd: "/Users/example/api"), live("api-qa", cwd: "/Users/example/api"),
                            live("web", cwd: "/Users/example/web"), live("web-qa", cwd: "/Users/example/web"),
                            live("solo", cwd: "/Users/example/solo")])
            let spawns = AgentWindowD1Tests.SpawnCalls(), m = model(st, spawns)
            defer { m.close() }
            let items = AgentSidebar.items(m.sections) { st.groups }.values.flatMap { $0 }
            let web = try XCTUnwrap(items.first { $0.stem == "web" }, "\(items.map(\.stem))")
            XCTAssertEqual(m.addableGroup(web), "web", "a running group's row has the item")
            XCTAssertFalse(items.filter { $0.stem == nil }.isEmpty, "solo is a row alone")
            XCTAssertTrue(items.filter { $0.stem == nil }.allSatisfy { m.addableGroup($0) == nil }, "a row alone has none")

            XCTAssertTrue(m.newSession == nil)
            m.addSession(toGroup: "web")
            XCTAssertEqual(m.newSession?.group, AgentNewSessionForm.GroupPick(stem: "web", sidekick: false), "the group, as a main")
            XCTAssertEqual(m.newSession?.folder, "~/web", "the group's folder")   // red if the group is ignored: the default folder
            XCTAssertEqual(m.newSession?.command, "claude --verbose", "the group's harness")
            XCTAssertEqual(m.newSessionName, "", "#1731: no generated group name (was: web-2)")
            m.setNewSessionGroup("web", sidekick: true)
            XCTAssertEqual(m.newSession?.command, "claude --debug", "the person picks the role")

            m.addSession(toGroup: "api")
            XCTAssertEqual(m.newSession?.group, AgentNewSessionForm.GroupPick(stem: "api", sidekick: false), "the open form")
            XCTAssertEqual(m.newSession?.folder, "~/api")

            m.setNewSessionHost("example-host")
            XCTAssertTrue(m.newSession?.group == nil)
            m.addSession(toGroup: "web")
            XCTAssertTrue(m.newSession?.host == nil, "groups are this Mac's")
            XCTAssertEqual(m.newSession?.group, AgentNewSessionForm.GroupPick(stem: "web", sidekick: false))
            XCTAssertEqual(m.newSession?.folder, "~/web")
            XCTAssertTrue(spawns.calls.isEmpty)
        }
    }

    /// No group running: a group row whose group stopped, and a group of one live member (a plain row), have no item;
    /// the action on a stopped group opens the form with no group chosen.
    func testNoRunningGroupHasNoAddSessionItem() throws {
        try d1.withNewSessionPrefs {
            let st = store([live("api", cwd: "/Users/example/api"), live("api-qa", cwd: "/Users/example/api"),
                            live("web", cwd: "/Users/example/web")], history: [d1.record("web-qa")])
            let spawns = AgentWindowD1Tests.SpawnCalls(), m = model(st, spawns)
            defer { m.close() }
            let items = AgentSidebar.items(m.sections) { st.groups }.values.flatMap { $0 }
            XCTAssertEqual(items.compactMap(\.stem), ["api"], "web has one live member: a plain row")
            let api = try XCTUnwrap(items.first { $0.stem == "api" })
            XCTAssertEqual(m.addableGroup(api), "api")
            XCTAssertTrue(items.filter { $0.stem == nil }.allSatisfy { m.addableGroup($0) == nil })
            st.sessions.removeAll { $0.name == "api-qa" }
            XCTAssertTrue(m.addableGroup(api) == nil, "its group stopped: no item")
            m.addSession(toGroup: "api")
            XCTAssertTrue(m.newSession != nil && m.newSession?.group == nil, "no group to choose")
            XCTAssertTrue(spawns.calls.isEmpty)
        }
    }

    /// R1214-i1: a group choice clears a typed name; None (and another Mac) brings it back unless a name was typed
    /// since. (Old code: None left the name empty.)
    func testNoneRestoresTheNameTypedBeforeTheGroupChoice() throws {
        try d1.withNewSessionPrefs {
            let st = store([live("api", cwd: "/Users/example/api"), live("api-qa", cwd: "/Users/example/api")])
            let spawns = AgentWindowD1Tests.SpawnCalls(), m = model(st, spawns)
            defer { m.close() }
            m.openNewSession()
            m.setNewSessionName("mine")
            m.setNewSessionGroup("api", sidekick: false)
            XCTAssertEqual(m.newSession?.name, "", "the choice clears it")
            XCTAssertEqual(m.newSessionName, "", "#1731: empty (was: api-2)")
            m.setNewSessionGroup("api", sidekick: true)
            m.setNewSessionGroup(nil, sidekick: false)
            XCTAssertEqual(m.newSession?.name, "mine", "None brings it back")   // red before the fix: ""
            XCTAssertEqual(m.newSession?.nameEdited, true)
            XCTAssertEqual(m.newSessionName, "mine")

            m.setNewSessionGroup("api", sidekick: false)
            m.setNewSessionName("other")
            m.setNewSessionGroup(nil, sidekick: false)
            XCTAssertEqual(m.newSession?.name, "other", "a name typed since stays")

            m.setNewSessionGroup("api", sidekick: false)
            m.setNewSessionHost("example-host")
            XCTAssertEqual(m.newSession?.name, "other", "another Mac takes the group back as None does")
            m.cancelNewSession()

            m.openNewSession()
            m.setNewSessionGroup("api", sidekick: false)
            m.setNewSessionGroup(nil, sidekick: false)
            XCTAssertEqual(m.newSession?.name, "", "none typed: none brought back")
            XCTAssertEqual(m.newSession?.nameEdited, false)
            XCTAssertTrue(spawns.calls.isEmpty)
        }
    }

    // MARK: UI scale

    /// At 1.0, 0.85 and 0.7 the choice and the role sit on one line inside the form's column, overlap neither each other,
    /// their row's label nor the Folder field, and a choice resizes neither them nor the Folder field.
    func testGroupRowFitsAtEveryScaleWithNoOverlapAndNoResize() throws {
        let saved = ThemeRuntime.scale
        defer { ThemeRuntime.scale = saved }
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        try d1.withNewSessionPrefs {
            for scale: CGFloat in [1.0, 0.85, 0.7] {
                ThemeRuntime.scale = scale
                let pixel = AXTreeSupport.devicePixel   // CI backs at 1x (a pixel is 1 pt there, 0.5 pt at 2x): never a literal 0.5
                let st = store([live("api", cwd: "/Users/example/api"), live("api-qa", cwd: "/Users/example/api")])
                let spawns = AgentWindowD1Tests.SpawnCalls(), m = model(st, spawns)
                defer { m.close() }
                let (win, host) = d1.formWindow(m, CGSize(width: sz(560), height: sz(700)))
                defer { win.close() }
                m.openNewSession()
                @MainActor func frames() throws -> [CGRect] {
                    let t = tree(host)
                    let choice = try XCTUnwrap(node(t, AgentNewSessionView.groupChoiceLabel), "choice at \(scale): \(t.map(\.name))")
                    let role = try XCTUnwrap(node(t, AgentNewSessionView.groupRoleLabel), "role at \(scale)")
                    let folder = try XCTUnwrap(t.last { $0.role == "AXTextField" && $0.named("Folder") }, "Folder at \(scale)")
                    let label = try XCTUnwrap(t.last { $0.role == "AXStaticText" && $0.named("Group") }, "the row's label at \(scale)")
                    let start = try XCTUnwrap(t.last { $0.role == "AXButton" && $0.named("Start") }, "Start at \(scale)")
                    XCTAssertEqual(choice.frame.midY, role.frame.midY, accuracy: 2, "one line at \(scale)")
                    XCTAssertLessThanOrEqual(label.frame.maxX, choice.frame.minX + pixel, "label, then the choice at \(scale)")
                    XCTAssertLessThanOrEqual(choice.frame.maxX, role.frame.minX + pixel, "choice, then the role at \(scale)")
                    XCTAssertLessThanOrEqual(role.frame.maxX, start.frame.maxX + pixel, "inside the form's column at \(scale)")
                    for (a, n) in [(choice.frame, "choice"), (role.frame, "role"), (label.frame, "label")] {
                        XCTAssertFalse(a.insetBy(dx: pixel, dy: pixel).intersects(folder.frame), "\(n) clear of Folder at \(scale)")
                    }
                    return [choice.frame, role.frame, folder.frame]
                }
                let before = try frames()
                m.setNewSessionGroup("api", sidekick: true)
                let after = try frames()
                XCTAssertEqual(after.count, before.count)
                // #1479: the form is centred, so choosing a group (which grows the form below) moves the whole column by one shift (was: nothing moved)
                let shift = (after.last?.minY ?? 0) - (before.last?.minY ?? 0)
                for (a, b) in zip(after, before) {
                    d1.assertRect(a, b.offsetBy(dx: 0, dy: shift), accuracy: pixel, "a choice resizes nothing and moves the column as one at \(scale)")
                }
                XCTAssertTrue(spawns.calls.isEmpty)
            }
        }
    }

    // MARK: Accessibility

    /// On the real tree: the choice and the role are labelled in words (no glyph-only label in the row); the role is
    /// dimmed until a group is chosen and then reads the chosen role.
    func testGroupChoiceAndRoleAreLabelledInWords() throws {
        let restore = AXTreeSupport.axOn()
        defer { restore() }
        try d1.withNewSessionPrefs {
            let st = store([live("api", cwd: "/Users/example/api"), live("api-qa", cwd: "/Users/example/api")])
            let spawns = AgentWindowD1Tests.SpawnCalls(), m = model(st, spawns)
            defer { m.close() }
            let (win, host) = d1.formWindow(m, CGSize(width: sz(560), height: sz(700)))
            defer { win.close() }
            m.openNewSession()
            var t = tree(host)
            let choice = try XCTUnwrap(node(t, AgentNewSessionView.groupChoiceLabel), "\(t.map(\.name))")
            var role = try XCTUnwrap(node(t, AgentNewSessionView.groupRoleLabel), "\(t.map(\.name))")
            XCTAssertTrue(choice.enabled)
            for (n, l) in [(choice, AgentNewSessionView.groupChoiceLabel), (role, AgentNewSessionView.groupRoleLabel)] {
                XCTAssertFalse(n.names.contains { $0.contains("\(l), \(l)") }, "read once: \(n.names)")
            }
            XCTAssertFalse(role.enabled, "no group: no role to pick")
            let band = choice.frame.insetBy(dx: -2000, dy: -2)
            for n in t where !n.ignored && n.frame.intersects(band) {
                for s in n.names {
                    XCTAssertTrue(s.contains { $0.isLetter }, "a label in words, not a glyph: \(n.role) \(s)")
                }
            }
            m.setNewSessionGroup("api", sidekick: true)
            t = tree(host)
            role = try XCTUnwrap(node(t, AgentNewSessionView.groupRoleLabel))
            XCTAssertTrue(role.enabled, "a group chosen: the role is live")
            XCTAssertTrue(role.names.contains("Sidekick"), "it reads the role: \(role.names)")
            XCTAssertTrue(node(t, AgentNewSessionView.groupChoiceLabel)?.names.contains("api") == true, "it reads the group")
            XCTAssertTrue(spawns.calls.isEmpty)
        }
    }
}
