import Foundation
import XCTest
@testable import ProsperApp

/// #726: user and market extensions on the phone's Commands screen. Every registry reads fixture
/// extensions from a tempDir() (plus, for the ordering test, the in-repo system extensions), uses
/// scratch defaults and a recording fake ExtensionHostServices. Only the fixtures' one-line Lua
/// handlers ever run; CommandRouter.registry and the real defaults are never touched.
@MainActor
final class DchUserCommandsTests: XCTestCase {

    /// Records every host call that could act on the Mac. The fixture handlers make none.
    private final class RecordingServices: ExtensionHostServices, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        var calls: [String] { lock.withLock { _calls } }
        private func record(_ name: String) { lock.withLock { _calls.append(name) } }

        func clipboardRead() -> String? { record("clipboardRead"); return nil }
        func clipboardWrite(_ text: String) { record("clipboardWrite") }
        func clipboardHistory(limit: Int) -> [String] { record("clipboardHistory"); return [] }
        func llmComplete(_ prompt: String) async -> String { record("llmComplete"); return "" }
        func llmTranslate(_ text: String, target: String, source: String?) async -> String { record("llmTranslate"); return "" }
        func llmChat(_ prompt: String) async -> String { record("llmChat"); return "" }
        func shellRun(_ command: String) async -> String { record("shellRun"); return "" }
        func httpRequest(method: String, url: String, headers: [String: String],
                         body: String?, timeout: TimeInterval) async -> HTTPResponse? { record("httpRequest"); return nil }
        func currentEpochSeconds() -> Double { 0 }
        func focusedWindowFrame() -> WindowFrame? { nil }
        func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { record("setFocusedWindowFrame"); return false }
        func prefGet(extensionID: String, key: String) -> String? { nil }
        func prefSet(extensionID: String, key: String, value: String) {}
        func notify(title: String, body: String) { record("notify") }
        func listDirectories(_ path: String) -> [String] { [] }
        func processKill(pid: Int32, force: Bool) -> String? { record("processKill"); return "refused" }
        func runAppleScript(_ source: String) -> String { record("runAppleScript"); return "" }
        func dialogConfirm(json: String) async -> Bool { record("dialogConfirm"); return false }
        func dialogPrompt(json: String) async -> String? { record("dialogPrompt"); return nil }
        func alertShow(text: String, seconds: Double) { record("alertShow") }
        func urlOpen(_ url: String, bundleID: String?) -> Bool { record("urlOpen"); return false }
        func appLaunchOrFocus(_ nameOrBundleID: String) { record("appLaunchOrFocus") }
        func keysStroke(_ spec: String) { record("keysStroke") }
        func keysSystem(_ name: String) { record("keysSystem") }
        func openWindow(extensionID: String, nodeJSON: String) { record("openWindow") }
        func filesAct(id: String, path: String) { record("filesAct") }
        func caffeinatePreventIdleSleep(extensionID: String, kind: String, on: Bool) { record("caffeinatePreventIdleSleep") }
        func caffeinateSetDisableLidSleep(extensionID: String, on: Bool) async { record("caffeinateSetDisableLidSleep") }
        func caffeinateLockScreen() { record("caffeinateLockScreen") }
        func caffeinateStartScreensaver() { record("caffeinateStartScreensaver") }
        func caffeinateSleepNow() { record("caffeinateSleepNow") }
    }

    private final class Frames: @unchecked Sendable {
        let lock = NSLock()
        var all: [Data] = []
        func append(_ f: Data) { lock.withLock { all.append(f) } }
        var snapshot: [Data] { lock.withLock { all } }
    }

    // MARK: Fixtures

    /// One `[[contributes.commands]]` row: `extra` holds the phone keys and anything else.
    private struct Cmd {
        var id: String
        var title: String? = nil
        var extra = "phone = true"
    }

    private static let systemDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)

    /// Each handler returns "<extension id>|<query>", or `lua` when given.
    @discardableResult
    private func writeExt(in root: URL, folder: String, extID: String, title: String, version: String = "1.0.0",
                          commands: [Cmd], lua: String? = nil) throws -> URL {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var toml = """
        [extension]
        id = "\(extID)"
        name = "\(folder)"
        title = "\(title)"
        description = "A #726 test fixture"
        version = "\(version)"
        author = "tester"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"

        """
        for c in commands {
            toml += """

            [[contributes.commands]]
            id = "\(c.id)"
            title = "\(c.title ?? "Title \(c.id)")"
            mode = "no-view"
            \(c.extra)

            """
        }
        try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        let source = lua ?? commands.map {
            "function \(ExtensionRegistry.handlerName(for: $0.id))(q) return '\(extID)|' .. q end"
        }.joined(separator: "\n")
        try source.write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        return dir
    }

    private struct Rig {
        let reg: ExtensionRegistry
        let userDir: URL
        let defaults: UserDefaults
        let services: RecordingServices
    }

    /// `write` fills the userDir before the first discover, so the grandfather migration trusts
    /// every fixture there.
    private func rig(systemDir: URL? = nil, _ write: (URL) throws -> Void) throws -> Rig {
        let userDir = tempDir("dch-user-commands")
        try write(userDir)
        let defaults = scratchDefaults("dch-user-commands")
        let services = RecordingServices()
        let reg = ExtensionRegistry(systemDir: systemDir, userDir: userDir, hostVersion: "2.0.0",
                                    defaults: defaults, services: services)
        reg.discover()
        return Rig(reg: reg, userDir: userDir, defaults: defaults, services: services)
    }

    private func ops(_ reg: ExtensionRegistry?, enabled: Bool = true, fans: [FanReading] = []) -> DchCommandOps {
        DchCommandOps(enabled: { enabled }, registry: { reg }, fans: .init(read: { fans }))
    }

    // MARK: Frame helpers

    private static func type(_ f: Data) -> UInt8 { f[f.startIndex] }
    private static func json(_ f: Data) -> Any? { try? JSONSerialization.jsonObject(with: f.subdata(in: (f.startIndex + 5)..<f.endIndex)) }
    private static func message(_ f: Data?) -> String? {
        guard let f, type(f) == DchFrame.error else { return nil }
        return (json(f) as? [String: Any])?["message"] as? String
    }
    private static func result(_ f: Data?) -> [String: String]? {
        guard let f, type(f) == DchFrame.commandResult else { return nil }
        return json(f) as? [String: String]
    }

    private func request(_ ops: DchCommandOps, _ type: UInt8, _ payload: Data, line: UInt = #line) async -> Data? {
        let frames = Frames()
        await ops.handle(type, payload, reply: { frames.append($0) })
        XCTAssertEqual(frames.snapshot.count, 1, "replies", line: line)
        return frames.snapshot.first
    }

    private func run(_ ops: DchCommandOps, _ id: String, _ argument: String = "", line: UInt = #line) async -> Data? {
        let body = (try? JSONSerialization.data(withJSONObject: ["id": id, "argument": argument])) ?? Data()
        return await request(ops, DchFrame.runCommand, body, line: line)
    }

    private func listRows(_ ops: DchCommandOps, line: UInt = #line) async -> [[String: String]] {
        let f = await request(ops, DchFrame.commands, Data(), line: line)
        XCTAssertEqual(f.map(Self.type), DchFrame.commandsResp, line: line)
        return f.flatMap(Self.json) as? [[String: String]] ?? []
    }

    private func listIDs(_ ops: DchCommandOps, line: UInt = #line) async -> [String] {
        await listRows(ops, line: line).compactMap { $0["id"] }
    }

    // MARK: Manifest

    func testManifestParsesPhoneKeysAndRefusesExcludedModes() throws {
        let root = tempDir("dch-user-manifest")
        let dir = try writeExt(in: root, folder: "m", extID: "com.user.m", title: "M", commands: [
            Cmd(id: "m.arg", extra: "phone = true\nphone_argument = \"2+2\""),
            Cmd(id: "m.tap"),
            Cmd(id: "m.empty", extra: "phone = true\nphone_argument = \"\""),
            Cmd(id: "m.off", extra: "phone = false"),
            Cmd(id: "m.none", extra: ""),
            Cmd(id: "m.window", extra: "phone = true\nlaunches_window = true"),
            Cmd(id: "m.model", extra: "phone = true\nrequires = [\"model\"]"),
            Cmd(id: "m.listing", extra: "phone = true\nlist_on_empty = true"),
            Cmd(id: "m.hintonly", extra: "phone_argument = \"x\""),
        ])
        // A view and a background command: mode is fixed to no-view by writeExt, so patch it.
        let tomlURL = dir.appendingPathComponent("extension.toml")
        var toml = try String(contentsOf: tomlURL, encoding: .utf8)
        toml += """

        [[contributes.commands]]
        id = "m.view"
        title = "View"
        mode = "view"
        phone = true

        [[contributes.commands]]
        id = "m.bg"
        title = "Background"
        mode = "background"
        phone = true
        """
        try toml.write(to: tomlURL, atomically: true, encoding: .utf8)

        let loaded = try ExtensionLoader.load(directory: dir, isSystem: false, hostVersion: "2.0.0")
        let contributes = try XCTUnwrap(loaded.manifest.contributes)
        let byID = Dictionary(uniqueKeysWithValues: contributes.allCommands.map { ($0.id, $0) })
        XCTAssertEqual(byID["m.arg"]?.phone, true)
        XCTAssertEqual(byID["m.arg"]?.phoneArgument, "2+2")
        XCTAssertNil(byID["m.tap"]?.phoneArgument)
        XCTAssertNil(byID["m.empty"]?.phoneArgument, "\"\" is no hint")
        XCTAssertEqual(byID["m.off"]?.phone, false)
        XCTAssertNil(byID["m.none"]?.phone)
        XCTAssertEqual(contributes.phoneCommands.map(\.id), ["m.arg", "m.tap", "m.empty"])
        XCTAssertEqual(byID["m.window"]?.phoneRefusal, "launches_window")
        XCTAssertEqual(byID["m.model"]?.phoneRefusal, "requires model")
        XCTAssertEqual(byID["m.listing"]?.phoneRefusal, "list_on_empty")
        XCTAssertEqual(byID["m.view"]?.phoneRefusal, "mode \"view\"")
        XCTAssertEqual(byID["m.bg"]?.phoneRefusal, "mode \"background\"")
        XCTAssertEqual(contributes.phoneWarnings, [
            "command m.window: phone = true ignored (launches_window)",
            "command m.model: phone = true ignored (requires model)",
            "command m.listing: phone = true ignored (list_on_empty)",
            "command m.hintonly: phone_argument ignored without phone = true",
            "command m.view: phone = true ignored (mode \"view\")",
            "command m.bg: phone = true ignored (mode \"background\")",
        ])
    }

    // MARK: The phone's "/" contract (iOS #727)

    /// The phone confirms every id with a "/" before running it: system and fan ids must never
    /// carry one, and every user row must.
    func testOnlyUserIDsContainASlash() async throws {
        for a in DchCommandOps.allowlist { XCTAssertFalse(a.id.contains("/"), a.id) }
        for id in [DchCommandOps.fanAuto, DchCommandOps.fanManual] + DchCommandOps.fanRows.compactMap({ $0["id"] }) {
            XCTAssertFalse(id.contains("/"), id)
        }
        XCTAssertEqual(DchCommandOps.phoneID("com.user.a", "a.run"), "com.user.a/a.run")
        let r = try rig { try writeExt(in: $0, folder: "a", extID: "com.user.a", title: "A", commands: [Cmd(id: "a.run")]) }
        r.reg.setPhoneApproved(true, id: "com.user.a")
        let ids = await listIDs(ops(r.reg))
        XCTAssertEqual(ids, ["com.user.a/a.run"])
        XCTAssertTrue(ids.allSatisfy { $0.contains("/") })
    }

    // MARK: Listing

    func testListingOrderAndRowsOnlyForApprovedLiveExtensions() async throws {
        try XCTSkipIf(!FileManager.default.fileExists(atPath: Self.systemDir.path), "no extensions dir")
        let r = try rig(systemDir: Self.systemDir) { root in
            try writeExt(in: root, folder: "b", extID: "com.user.beta", title: "Beta", commands: [Cmd(id: "b.one")])
            // Discovery order is by folder (beta, gamma, alpha); the listing is by title.
            try writeExt(in: root, folder: "z-a", extID: "com.user.alpha", title: "Alpha", commands: [
                Cmd(id: "a.two", title: "Two", extra: "phone = true\nphone_argument = \"2+2\"\ndescription = \"Adds\"\nicon = \"plus\""),
                Cmd(id: "a.palette", extra: ""),
                Cmd(id: "a.one", title: "One"),
            ])
            try writeExt(in: root, folder: "c", extID: "com.user.gamma", title: "Gamma", commands: [Cmd(id: "g.one")])
        }
        let fan = [FanReading(id: 0, min: 1000, max: 5000, current: 1500, manual: false)]
        let system = ["calc.eval", "unit.convert", "currency.convert", "openlid.status", "openlid.toggle",
                      "openlid.caffeine", "toggles.lock", "toggles.displayoff", "toggles.screensaver"]
        let fans = [DchCommandOps.fanAuto, DchCommandOps.fanManual]
        // Nothing approved: the listing is exactly what it was before #726.
        let before = await listIDs(ops(r.reg, fans: fan))
        XCTAssertEqual(before, system + fans)

        r.reg.setPhoneApproved(true, id: "com.user.beta")
        r.reg.setPhoneApproved(true, id: "com.user.alpha")
        let rows = await listRows(ops(r.reg, fans: fan))
        // System, fans, then user rows grouped by extension title, manifest order inside.
        XCTAssertEqual(rows.compactMap { $0["id"] },
                       system + fans + ["com.user.alpha/a.two", "com.user.alpha/a.one", "com.user.beta/b.one"])
        XCTAssertEqual(rows.first { $0["id"] == "com.user.alpha/a.two" },
                       ["id": "com.user.alpha/a.two", "title": "Two", "ext": "Alpha", "subtitle": "Adds",
                        "argument": "2+2", "icon": "plus"])
        XCTAssertEqual(rows.first { $0["id"] == "com.user.beta/b.one" },
                       ["id": "com.user.beta/b.one", "title": "Title b.one", "ext": "Beta"])
        XCTAssertEqual(r.services.calls, [])
    }

    func testOffGateRefusesUserCommands() async throws {
        let r = try rig { try writeExt(in: $0, folder: "a", extID: "com.user.a", title: "A", commands: [Cmd(id: "a.run")]) }
        r.reg.setPhoneApproved(true, id: "com.user.a")
        let off = ops(r.reg, enabled: false)
        let list = await request(off, DchFrame.commands, Data())
        XCTAssertEqual(Self.message(list), "commands are off")
        let f = await run(off, "com.user.a/a.run", "x")
        XCTAssertEqual(Self.message(f), "commands are off")
        // Same request, gate on: it runs.
        let on = await run(ops(r.reg), "com.user.a/a.run", "x")
        XCTAssertEqual(Self.result(on), ["text": "com.user.a|x"])
    }

    func testDisabledOrUntrustedIsNotListedOrRun() async throws {
        let r = try rig { try writeExt(in: $0, folder: "a", extID: "com.user.a", title: "A", commands: [Cmd(id: "a.run")]) }
        r.reg.setPhoneApproved(true, id: "com.user.a")
        try r.reg.setEnabled(false, id: "com.user.a")
        let offList = await listIDs(ops(r.reg))
        XCTAssertEqual(offList, [])
        let offRun = await run(ops(r.reg), "com.user.a/a.run")
        XCTAssertEqual(Self.message(offRun), "not allowed")
        // Re-enabled, the approval still stands.
        try r.reg.setEnabled(true, id: "com.user.a")
        let onList = await listIDs(ops(r.reg))
        XCTAssertEqual(onList, ["com.user.a/a.run"])
        // Untrust withdraws the approval for good: a re-trust doesn't bring it back.
        try r.reg.untrust(id: "com.user.a")
        let untrusted = await listIDs(ops(r.reg))
        XCTAssertEqual(untrusted, [])
        try r.reg.trust(id: "com.user.a")
        XCTAssertFalse(r.reg.isPhoneApproved(id: "com.user.a"))
        let retrusted = await run(ops(r.reg), "com.user.a/a.run")
        XCTAssertEqual(Self.message(retrusted), "not allowed")
    }

    func testUninstallDropsApprovalForAReinstall() async throws {
        let r = try rig { try writeExt(in: $0, folder: "com.user.a", extID: "com.user.a", title: "A", commands: [Cmd(id: "a.run")]) }
        r.reg.setPhoneApproved(true, id: "com.user.a")
        XCTAssertTrue(r.reg.isPhoneApproved(id: "com.user.a"))
        try r.reg.uninstall(id: "com.user.a")
        let source = try writeExt(in: tempDir("dch-user-source"), folder: "src", extID: "com.user.a", title: "A",
                                  commands: [Cmd(id: "a.run")])
        try r.reg.installLocal(from: source)
        try r.reg.trust(id: "com.user.a")
        XCTAssertFalse(r.reg.isPhoneApproved(id: "com.user.a"))
        let ids = await listIDs(ops(r.reg))
        XCTAssertEqual(ids, [])
    }

    // MARK: Identity

    /// Two extensions declare the same command id. The unapproved one wins the route table
    /// (last writer), but only the approved one runs or lists.
    func testSameCommandIDInAnotherExtensionCannotHijack() async throws {
        let r = try rig { root in
            try writeExt(in: root, folder: "a-good", extID: "com.user.good", title: "Good", commands: [Cmd(id: "same.cmd")])
            try writeExt(in: root, folder: "z-evil", extID: "com.user.evil", title: "Evil", commands: [Cmd(id: "same.cmd")])
        }
        r.reg.setPhoneApproved(true, id: "com.user.good")
        XCTAssertEqual(r.reg.command(id: "same.cmd")?.record.id, "com.user.evil", "precondition: evil owns the route")
        let good = await run(ops(r.reg), "com.user.good/same.cmd", "hi")
        XCTAssertEqual(Self.result(good), ["text": "com.user.good|hi"])
        let evil = await run(ops(r.reg), "com.user.evil/same.cmd", "hi")
        XCTAssertEqual(Self.message(evil), "not allowed")
        // The bare command id is no user path either.
        let bare = await run(ops(r.reg), "same.cmd", "hi")
        XCTAssertEqual(Self.message(bare), "not allowed")
        let ids = await listIDs(ops(r.reg))
        XCTAssertEqual(ids, ["com.user.good/same.cmd"])
    }

    /// Split on the first "/": the command id keeps any further "/"; an empty half is refused.
    func testNamespacedIDSplitRules() async throws {
        let r = try rig { root in
            try writeExt(in: root, folder: "a", extID: "com.user.a", title: "A",
                         commands: [Cmd(id: "multi/part"), Cmd(id: "multi"), Cmd(id: "palette", extra: "")])
            // An empty extension id or command id would put an empty half on the wire.
            try writeExt(in: root, folder: "b", extID: "", title: "B", commands: [Cmd(id: "multi")])
            try writeExt(in: root, folder: "c", extID: "com.user.c", title: "C", commands: [Cmd(id: "")],
                         lua: "function x(q) return q end")
        }
        for id in ["com.user.a", "", "com.user.c"] { r.reg.setPhoneApproved(true, id: id) }
        XCTAssertTrue(r.reg.isPhoneApproved(id: "") && r.reg.isPhoneApproved(id: "com.user.c"), "precondition")
        let ids = await listIDs(ops(r.reg))
        XCTAssertEqual(ids, ["com.user.a/multi/part", "com.user.a/multi"])
        // An approved extension's palette-only command never runs from the phone.
        let palette = await run(ops(r.reg), "com.user.a/palette")
        XCTAssertEqual(Self.message(palette), "not allowed")
        let multi = await run(ops(r.reg), "com.user.a/multi/part", "q")
        XCTAssertEqual(Self.result(multi), ["text": "com.user.a|q"])
        for bad in ["/multi", "com.user.a/", "com.user.a", "/", "com.user.a//multi", "com.user.a/multi/", "com.user/a/multi"] {
            let f = await run(ops(r.reg), bad)
            XCTAssertEqual(Self.message(f), "not allowed", bad)
        }
        XCTAssertNil(DchCommandOps.resolveUser("/multi", in: r.reg))
        XCTAssertNil(DchCommandOps.resolveUser("com.user.a/", in: r.reg))
        XCTAssertEqual(DchCommandOps.resolveUser("com.user.a/multi", in: r.reg)?.command.id, "multi")
    }

    /// A system extension's phone flag is ignored, even with an approval forced into the store.
    func testSystemExtensionPhoneFlagIsIgnored() async throws {
        let sys = tempDir("dch-user-system")
        try writeExt(in: sys, folder: "s", extID: "com.test.sys", title: "Sys", commands: [Cmd(id: "sys.cmd")])
        let r = try rig(systemDir: sys) { _ in }
        let record = try XCTUnwrap(r.reg.record(id: "com.test.sys"))
        XCTAssertTrue(record.isSystem && record.isLive, "precondition")
        r.reg.setPhoneApproved(true, id: "com.test.sys")
        XCTAssertNil(r.defaults.dictionary(forKey: ExtensionRegistry.phoneApprovedKey)?["com.test.sys"])
        r.defaults.set(["com.test.sys": ExtensionRegistry.phoneApprovalHash(record.manifest)],
                       forKey: ExtensionRegistry.phoneApprovedKey)
        XCTAssertFalse(r.reg.isPhoneApproved(id: "com.test.sys"))
        let ids = await listIDs(ops(r.reg))
        XCTAssertEqual(ids, [])
        let f = await run(ops(r.reg), "com.test.sys/sys.cmd")
        XCTAssertEqual(Self.message(f), "not allowed")
        XCTAssertFalse(ExtensionsPane.showsPhoneToggle(record, commandsFromPhone: true))
    }

    // MARK: Approval binding

    func testUpdateThatChangesPhoneCommandsDropsApproval() async throws {
        let v1 = [Cmd(id: "a.run", extra: "phone = true\nphone_argument = \"x\"")]
        let r = try rig { try writeExt(in: $0, folder: "a", extID: "com.user.a", title: "A", commands: v1) }
        r.reg.setPhoneApproved(true, id: "com.user.a")
        XCTAssertTrue(r.reg.isPhoneApproved(id: "com.user.a"))

        // A version bump, new code and a new palette-only command keep the approval.
        try writeExt(in: r.userDir, folder: "a", extID: "com.user.a", title: "A", version: "1.1.0",
                     commands: v1 + [Cmd(id: "a.palette", extra: "")])
        r.reg.discover()
        XCTAssertTrue(r.reg.isPhoneApproved(id: "com.user.a"))

        // An update that adds a phone command drops it: nothing new reaches the phone.
        try writeExt(in: r.userDir, folder: "a", extID: "com.user.a", title: "A", version: "1.2.0",
                     commands: v1 + [Cmd(id: "a.new")])
        r.reg.discover()
        XCTAssertFalse(r.reg.isPhoneApproved(id: "com.user.a"))
        let ids = await listIDs(ops(r.reg))
        XCTAssertEqual(ids, [])
        let old = await run(ops(r.reg), "com.user.a/a.run")
        XCTAssertEqual(Self.message(old), "not allowed")
        let new = await run(ops(r.reg), "com.user.a/a.new")
        XCTAssertEqual(Self.message(new), "not allowed")

        // Reverting the update doesn't bring the approval back on its own.
        try writeExt(in: r.userDir, folder: "a", extID: "com.user.a", title: "A", version: "1.3.0", commands: v1)
        r.reg.discover()
        XCTAssertFalse(r.reg.isPhoneApproved(id: "com.user.a"))

        // Re-approved; then a changed hint or a renamed title drops it too.
        r.reg.setPhoneApproved(true, id: "com.user.a")
        let back = await listIDs(ops(r.reg))
        XCTAssertEqual(back, ["com.user.a/a.run"])
        try writeExt(in: r.userDir, folder: "a", extID: "com.user.a", title: "A", version: "1.4.0",
                     commands: [Cmd(id: "a.run", extra: "phone = true\nphone_argument = \"y\"")])
        r.reg.discover()
        XCTAssertFalse(r.reg.isPhoneApproved(id: "com.user.a"))
        r.reg.setPhoneApproved(true, id: "com.user.a")
        try writeExt(in: r.userDir, folder: "a", extID: "com.user.a", title: "A", version: "1.5.0",
                     commands: [Cmd(id: "a.run", title: "Renamed", extra: "phone = true\nphone_argument = \"y\"")])
        r.reg.discover()
        XCTAssertFalse(r.reg.isPhoneApproved(id: "com.user.a"))
    }

    /// A manifest that fails to load for a while is not an update: its approval survives.
    func testUnloadableManifestKeepsApproval() async throws {
        let cmds = [Cmd(id: "a.run")]
        let r = try rig { try writeExt(in: $0, folder: "a", extID: "com.user.a", title: "A", commands: cmds) }
        r.reg.setPhoneApproved(true, id: "com.user.a")
        let toml = r.userDir.appendingPathComponent("a/extension.toml")
        try "not toml [".write(to: toml, atomically: true, encoding: .utf8)
        r.reg.discover()
        XCTAssertNil(r.reg.record(id: "com.user.a"), "precondition: it failed to load")
        try writeExt(in: r.userDir, folder: "a", extID: "com.user.a", title: "A", commands: cmds)
        r.reg.discover()
        XCTAssertTrue(r.reg.isPhoneApproved(id: "com.user.a"))
    }

    /// The stored hash is checked on every read, not only when discover() prunes.
    func testStaleStoredApprovalIsNotHonoured() async throws {
        let r = try rig { try writeExt(in: $0, folder: "a", extID: "com.user.a", title: "A", commands: [Cmd(id: "a.run")]) }
        r.defaults.set(["com.user.a": "stale"], forKey: ExtensionRegistry.phoneApprovedKey)
        XCTAssertFalse(r.reg.isPhoneApproved(id: "com.user.a"))
        let ids = await listIDs(ops(r.reg))
        XCTAssertEqual(ids, [])
        let f = await run(ops(r.reg), "com.user.a/a.run")
        XCTAssertEqual(Self.message(f), "not allowed")
    }

    // MARK: Running

    func testRunRestoresPrefixRefusesViewTreeAndCapsArgument() async throws {
        let view = #"{"type":"list","items":[{"id":"a","title":"Row A"}]}"#
        let r = try rig { root in
            try writeExt(in: root, folder: "a", extID: "com.user.a", title: "A",
                         commands: [Cmd(id: "a.echo", extra: "phone = true\nprefix = \"fx \""), Cmd(id: "a.tree")],
                         lua: "function a_echo(q) return q end\nfunction a_tree(q) return '\(view)' end")
        }
        r.reg.setPhoneApproved(true, id: "com.user.a")
        let echo = await run(ops(r.reg), "com.user.a/a.echo", "hello")
        XCTAssertEqual(Self.result(echo), ["text": "fx hello"])
        let tree = await run(ops(r.reg), "com.user.a/a.tree")
        XCTAssertEqual(Self.message(tree), "unsupported result")
        let long = await run(ops(r.reg), "com.user.a/a.echo", String(repeating: "x", count: DchCommandOps.maxArgument + 1))
        XCTAssertEqual(Self.message(long), "argument too long")
        XCTAssertEqual(r.services.calls, [])
    }

    // MARK: Settings row

    func testAllowOnIPhoneToggleVisibility() throws {
        let r = try rig { root in
            try writeExt(in: root, folder: "a", extID: "com.user.a", title: "A", commands: [Cmd(id: "a.run")])
            try writeExt(in: root, folder: "b", extID: "com.user.b", title: "B", commands: [Cmd(id: "b.run", extra: "")])
            try writeExt(in: root, folder: "c", extID: "com.user.c", title: "C",
                         commands: [Cmd(id: "c.run", extra: "phone = true\nlaunches_window = true")])
        }
        let a = try XCTUnwrap(r.reg.record(id: "com.user.a"))
        XCTAssertTrue(ExtensionsPane.showsPhoneToggle(a, commandsFromPhone: true))
        XCTAssertFalse(ExtensionsPane.showsPhoneToggle(a, commandsFromPhone: false))
        // No phone command, or only a refused one: hidden.
        XCTAssertFalse(ExtensionsPane.showsPhoneToggle(try XCTUnwrap(r.reg.record(id: "com.user.b")), commandsFromPhone: true))
        XCTAssertFalse(ExtensionsPane.showsPhoneToggle(try XCTUnwrap(r.reg.record(id: "com.user.c")), commandsFromPhone: true))
        try r.reg.untrust(id: "com.user.a")
        XCTAssertFalse(ExtensionsPane.showsPhoneToggle(a, commandsFromPhone: true))
    }
}
