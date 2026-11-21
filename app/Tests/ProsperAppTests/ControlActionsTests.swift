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
        """.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try """
        function fake_ping(query) return "pong" end
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
        let settings = all["prosper\u{1}settings"]
        XCTAssertEqual(settings?["takesInput"], .bool(false), "\(all.keys.sorted())")
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
        _ = await call(reg, "actions.run", ["id": .string("prosper\u{1}settings")])
        XCTAssertEqual(fired, ["ext:fake.ping|", "ext:fake.pick|Alpha", "builtin:settings"])
        XCTAssertEqual(try ControlActions.run(id: "extensionItem\u{1}fake.pick\u{1}Alpha", input: nil), "Fake Tools \u{203A} Alpha")
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
        for id in ["extensionItem\u{1}fake.ping\u{1}", "extensionItem\u{1}fake.pick\u{1}Alpha", "prosper\u{1}settings"] {
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
