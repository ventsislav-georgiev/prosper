import Foundation
import XCTest
@testable import ProsperApp

/// #1818: actions.list / actions.run over a fake extension and a recorder in place of the hotkey paths.
@MainActor
final class ControlActionsTests: XCTestCase {
    private var fired: [String] = []

    /// A registry over one fake system extension: a run-on-select command and a listing command with two rows.
    private func fakeRegistry() throws -> ExtensionRegistry {
        let root = tempDir()
        let dir = root.appendingPathComponent("system/fake", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        [extension]
        id          = "com.example.fake"
        name        = "fake"
        title       = "Fake Tools"
        description = "Test fixture"
        version     = "1.0.0"
        author      = "example"
        license     = "MIT"
        icon        = "star"
        system      = true

        [extension.host]
        min_version = "2.0.0"
        api_level   = 1

        [extension.entry]
        main = "init.lua"

        [[contributes.commands]]
        id             = "fake.ping"
        title          = "Ping"
        description    = "Fires at once"
        mode           = "no-view"
        icon           = "bolt"
        runs_on_select = true

        [[contributes.commands]]
        id             = "fake.pick"
        title          = "Pick"
        description    = "Lists two rows"
        mode           = "no-view"
        icon           = "list.bullet"
        match          = "^fk( |$)"
        prefix         = "fk "
        list_on_empty  = true
        bindable_items = true

        [[contributes.commands]]
        id              = "fake.win"
        title           = "Open Window"
        description     = "Opens its own window"
        mode            = "no-view"
        icon            = "macwindow"
        launches_window = true

        [[contributes.commands]]
        id              = "quickdirs.run"
        title           = "Quickdir"
        description     = "Stands in for the bundled one, which opens the runner"
        mode            = "no-view"
        match           = "^qd( |$)"
        prefix          = "qd "
        """.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try """
        function fake_ping(query) return "pong" end
        function fake_win(query) return "" end
        function quickdirs_run(query) return "" end
        function fake_pick(query)
            return host.ui.render(host.ui.list{ title = "Fake", items = {
                { id = "a", title = "Alpha" }, { id = "b", title = "Beta" } } })
        end
        """.write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        let registry = ExtensionRegistry(systemDir: root.appendingPathComponent("system"),
                                         userDir: root.appendingPathComponent("user"),
                                         hostVersion: "2.0.0", defaults: scratchDefaults("ctlactions"))
        registry.discover()
        return registry
    }

    /// Points ControlActions at `registry` with a recorder for both fire paths.
    private func useRecorder(_ registry: ExtensionRegistry?) {
        addTeardownBlock { @MainActor in ControlActions.source = .app }
        ControlActions.source = ControlActions.Source(
            registry: { registry },
            fireBuiltIn: { [weak self] in self?.fired.append("builtin:\($0.rawValue)"); return true },
            fireExtension: { [weak self] in self?.fired.append("ext:\($0)|\($1)") })
    }

    private func registry() -> ControlRegistry {
        var r = ControlRegistry()
        ControlRegistry.registerActions(&r)
        return r
    }

    private func call(_ reg: ControlRegistry, _ cmd: String, _ args: [String: ControlJSON] = [:]) async -> ControlReply {
        await reg.reply(to: try! JSONEncoder().encode(ControlRequest(cmd: cmd, args: args)))
    }

    private func actions(_ reply: ControlReply) -> [String: [String: ControlJSON]] {
        guard case .object(let o)? = reply.result, case .array(let list)? = o["actions"] else { return [:] }
        var out: [String: [String: ControlJSON]] = [:]
        for case .object(let a) in list { if case .string(let id)? = a["id"] { out[id] = a } }
        return out
    }

    /// Lists until the bindable-actions refresh has landed (the first list starts it).
    private func listed(_ reg: ControlRegistry, query: String? = nil) async -> ControlReply {
        let args: [String: ControlJSON] = query.map { ["query": .string($0)] } ?? [:]
        _ = await call(reg, "actions.list", args)
        await ControlActions.refresh?.value
        return await call(reg, "actions.list", args)
    }

    func testListIncludesABuiltInAnExtensionCommandAndAListedItem() async throws {
        useRecorder(try fakeRegistry())
        let reply = await listed(registry())
        XCTAssertTrue(reply.ok, "\(reply)")
        guard case .object(let o)? = reply.result else { return XCTFail("\(reply)") }
        XCTAssertEqual(o["complete"], .bool(true))
        let all = actions(reply)
        let center = all["prosper\u{1}windowCenter"]
        XCTAssertEqual(center?["takesInput"], .bool(false), "\(all.keys.sorted())")
        let ping = all["extensionItem\u{1}fake.ping\u{1}"]
        XCTAssertEqual(ping?["title"], .string("Ping"))
        XCTAssertEqual(ping?["category"], .string("Fake Tools"))
        XCTAssertEqual(ping?["icon"], .string("bolt"))
        XCTAssertEqual(ping?["takesInput"], .bool(false))
        XCTAssertEqual(all["extensionItem\u{1}fake.pick\u{1}Alpha"]?["title"], .string("Alpha"))
        XCTAssertEqual(all["extensionItem\u{1}fake.pick\u{1}Beta"]?["takesInput"], .bool(false))
        let pick = all["extensionItem\u{1}fake.pick\u{1}"]
        XCTAssertEqual(pick?["takesInput"], .bool(true))
        XCTAssertEqual(pick?["items"], .array([.string("Alpha"), .string("Beta")]))
        XCTAssertTrue(fired.isEmpty, "a list fires nothing: \(fired)")
    }

    func testListQueryFiltersLikeTheShortcutsPane() async throws {
        useRecorder(try fakeRegistry())
        let ids = Set(actions(await listed(registry(), query: "alpha")).keys)
        XCTAssertEqual(ids, ["extensionItem\u{1}fake.pick\u{1}Alpha"])
    }

    /// One refresh at a time: a second list while the first refresh runs starts no other listing.
    func testListRefreshIsCoalesced() async throws {
        useRecorder(try fakeRegistry())
        let reg = registry()
        _ = await call(reg, "actions.list")
        let first = ControlActions.refresh
        _ = await call(reg, "actions.list")
        if let first { XCTAssertEqual(ControlActions.refresh, first) }
        await ControlActions.refresh?.value
    }

    func testRunFiresTheShortcutDispatch() async throws {
        useRecorder(try fakeRegistry())
        let reg = registry()
        let ping = await call(reg, "actions.run", ["id": .string("extensionItem\u{1}fake.ping\u{1}")])
        XCTAssertTrue(ping.ok, "\(ping)")
        XCTAssertEqual(ping.result, .bool(true))
        _ = await call(reg, "actions.run", ["id": .string("extensionItem\u{1}fake.pick\u{1}Alpha")])
        _ = await call(reg, "actions.run", ["id": .string("prosper\u{1}windowCenter")])
        XCTAssertEqual(fired, ["ext:fake.ping|", "ext:fake.pick|Alpha", "builtin:windowCenter"])
        XCTAssertEqual(try ControlActions.run(id: "extensionItem\u{1}fake.pick\u{1}Alpha", input: nil), "Fake Tools \u{203A} Alpha")
    }

    func testRunNoticeReadsAgentRanAndHasNoUndo() async throws {
        useRecorder(try fakeRegistry())
        var reg = registry()
        let changes = ControlChanges()
        var notices: [(String, Bool)] = []
        changes.present = { text, undo in notices.append((text, undo != nil)) }
        reg.changes = changes
        let r = await call(reg, "actions.run", ["id": .string("extensionItem\u{1}fake.pick\u{1}Alpha")])
        XCTAssertTrue(r.ok, "\(r)")
        XCTAssertEqual(notices.map(\.0), ["Agent ran: Fake Tools \u{203A} Alpha"])
        XCTAssertEqual(notices.map(\.1), [false])
        XCTAssertEqual(changes.entries.last?.undoable, false)
    }

    func testUnknownIdIsAnError() async throws {
        useRecorder(try fakeRegistry())
        let reg = registry()
        for id in ["bogus", "prosper\u{1}nope", "extensionItem\u{1}nope.cmd\u{1}", "app\u{1}x", ""] {
            let r = await call(reg, "actions.run", ["id": .string(id)])
            XCTAssertFalse(r.ok, id)
            XCTAssertTrue(r.error?.hasPrefix("unknown action") == true, "\(id): \(r)")
        }
        let missing = await call(reg, "actions.run")
        XCTAssertFalse(missing.ok)
        XCTAssertTrue(fired.isEmpty, "\(fired)")
    }

    /// #1845/#1848: the screen readers and the panel openers stay human-only: pinned set, not listed, refused with
    /// the reason (an opener whose extension the fake registry lacks is refused as human-only, not as unknown).
    func testScreenReadersAreHumanOnly() async throws {
        useRecorder(try fakeRegistry())
        XCTAssertEqual(ControlActions.humanOnly.map(\.rawValue), [
            "copyScreenText", "pickColor", "runner", "runnerSpace", "runnerBackslash", "translate", "settings",
            "clipboard", "agent", "agentSessions", "agentIsland", "calendarTogglePopup",
        ])
        let reg = registry()
        let list = actions(await listed(reg))
        XCTAssertFalse(list.isEmpty)
        for action in ControlActions.humanOnly {
            let id = BindableAction(kind: .prosper, key: action.rawValue, title: "", category: "", icon: "", combo: unsetKeyCombo).id
            XCTAssertTrue(list[id] == nil, id)
            let r = await call(reg, "actions.run", ["id": .string(id)])
            XCTAssertFalse(r.ok, id)
            XCTAssertTrue(r.error?.contains("human-only") == true, "\(r)")
        }
        XCTAssertTrue(fired.isEmpty, "\(fired)")
    }

    /// #1848: the literal set an agent may run: every built-in that acts without a Prosper panel taking the keyboard.
    /// A built-in added to ShortcutAction lands here or in humanOnly by a written choice, never by default.
    func testAgentRunnableBuiltInsArePinned() async throws {
        useRecorder(try fakeRegistry())
        let runnable = [
            "toggleAutocomplete", "windowLeftHalf", "windowRightHalf", "windowTopHalf", "windowBottomHalf",
            "windowMaximize", "windowCenter", "menuBarToggleHidden", "mixerCycleOutput", "mixerToggleMicMute",
        ]
        XCTAssertEqual(ShortcutAction.allCases.filter { !ControlActions.humanOnly.contains($0) }.map(\.rawValue), runnable)
        let listed = Set(actions(await listed(registry())).keys.compactMap { id -> String? in
            let (kind, key) = ShortcutCatalog.splitExtensionKey(id)
            return kind == BindableActionKind.prosper.rawValue ? key : nil
        })
        XCTAssertTrue(listed.isSubset(of: Set(runnable)), "\(listed.subtracting(runnable).sorted())")
        // No owning extension and no setting gates these, so the fake registry lists every one.
        let ungated = ["toggleAutocomplete", "windowLeftHalf", "windowRightHalf", "windowTopHalf", "windowBottomHalf",
                       "windowMaximize", "windowCenter"]
        XCTAssertTrue(Set(ungated).isSubset(of: listed), "\(listed.sorted())")
    }

    /// #1848 (QA n137): a panel opener is refused with its reason and its hotkey payload never runs.
    func testRunOfAPanelOpenerIsRefusedAndNotFired() async throws {
        useRecorder(try fakeRegistry())
        let reg = registry()
        let clip = await call(reg, "actions.run", ["id": .string("prosper\u{1}clipboard")])
        XCTAssertFalse(clip.ok)
        XCTAssertEqual(clip.error, "Open Clipboard History is human-only: it opens a panel that takes the keyboard")
        let runner = await call(reg, "actions.run", ["id": .string("prosper\u{1}runner")])
        XCTAssertEqual(runner.error, "Open Command Runner is human-only: it opens a panel that takes the keyboard")
        let pick = await call(reg, "actions.run", ["id": .string("prosper\u{1}pickColor")])
        XCTAssertEqual(pick.error, "Screen: Pick Color is human-only: it reads the screen through a selection the person makes")
        XCTAssertTrue(fired.isEmpty, "\(fired)")
    }

    /// #1848: an extension command that opens its own window (launches_window) is not listed and a run is refused
    /// before the hotkey press; quickdirs.run, which opens the runner, counts as one too.
    func testExtensionWindowCommandIsNotListedAndIsRefused() async throws {
        useRecorder(try fakeRegistry())
        let reg = registry()
        let all = actions(await listed(reg))
        XCTAssertTrue(all["extensionItem\u{1}fake.ping\u{1}"] != nil, "\(all.keys.sorted())")
        XCTAssertTrue(all["extensionItem\u{1}fake.win\u{1}"] == nil, "\(all.keys.sorted())")
        let r = await call(reg, "actions.run", ["id": .string("extensionItem\u{1}fake.win\u{1}")])
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.error, "Fake Tools \u{203A} Open Window is human-only: it opens a panel that takes the keyboard")
        // quickdirs.run takes input, so without opensPanel it would be an input row.
        XCTAssertTrue(all["extensionItem\u{1}quickdirs.run\u{1}"] == nil, "\(all.keys.sorted())")
        let qd = await call(reg, "actions.run", ["id": .string("extensionItem\u{1}quickdirs.run\u{1}"), "input": .string("work")])
        XCTAssertEqual(qd.error, "Fake Tools \u{203A} work is human-only: it opens a panel that takes the keyboard")
        XCTAssertTrue(fired.isEmpty, "\(fired)")
    }

    /// The Settings switch refuses every `mutates` command in ControlRegistry.reply (#1808); run is one, list is not.
    func testRunIsRefusedByTheAgentControlSwitchAndListIsNot() {
        let reg = registry()
        XCTAssertTrue(reg.commands["actions.run"]?.mutates == true)
        XCTAssertTrue(reg.commands["actions.list"]?.mutates == false)
    }

    func testInputIsPassedToAnActionThatTakesIt() async throws {
        useRecorder(try fakeRegistry())
        let reg = registry()
        let r = await call(reg, "actions.run", ["id": .string("extensionItem\u{1}fake.pick\u{1}"), "input": .string("Beta")])
        XCTAssertTrue(r.ok, "\(r)")
        XCTAssertEqual(fired, ["ext:fake.pick|Beta"])
        for id in ["extensionItem\u{1}fake.ping\u{1}", "extensionItem\u{1}fake.pick\u{1}Alpha", "prosper\u{1}windowCenter"] {
            let refused = await call(reg, "actions.run", ["id": .string(id), "input": .string("x")])
            XCTAssertTrue(refused.error?.hasSuffix("takes no input") == true, "\(id): \(refused)")
        }
        XCTAssertEqual(fired.count, 1, "\(fired)")
    }

    /// No app delegate under XCTest: the real source finds no registry, so a run is an unknown id, never a fire.
    func testAppSourceWithoutTheAppFiresNothing() async {
        ControlActions.source = .app
        let r = await call(registry(), "actions.run", ["id": .string("extensionItem\u{1}fake.ping\u{1}")])
        XCTAssertFalse(r.ok)
    }
}
