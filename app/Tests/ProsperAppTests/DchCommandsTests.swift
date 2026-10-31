import Foundation
import Network
import os
import XCTest
@testable import ProsperApp

/// #619: the phone runs allowlisted palette commands. Every registry here reads the in-repo
/// system extensions (#filePath) or a fixture dir, seeds into a tempDir() userDir, uses
/// scratch defaults, and gets a recording fake ExtensionHostServices, so even a wrong invoke
/// cannot reach the real Mac. Only calc.eval and unit.convert (pure Lua) ever run, plus the
/// fixtures' own one-line handlers; every other allowlisted id appears only in the listing or
/// on a refusal path. CommandRouter.registry is never touched.
@MainActor
final class DchCommandsTests: XCTestCase {

    /// Records every host call that could act on the Mac. A run of calc or units makes none.
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

    // MARK: Registry rigs

    /// The in-repo system extensions (…/app/Sources/ProsperApp/Resources/extensions).
    private static let systemDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)

    /// A one-command fixture extension whose handler returns `result`.
    private func writeExt(in root: URL, folder: String, extID: String, commandID: String, result: String) throws {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let toml = """
        [extension]
        id = "\(extID)"
        name = "\(folder)"
        title = "Fixture \(folder)"
        description = "A #619 test fixture"
        version = "1.0.0"
        author = "tester"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"

        [[contributes.commands]]
        id = "\(commandID)"
        title = "Fixture command"
        mode = "no-view"
        """
        try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try "function \(ExtensionRegistry.handlerName(for: commandID))(q) return '\(result)' end"
            .write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
    }

    /// `systemDir` nil = no system extensions at all. `userExts` are written into the userDir
    /// before the first discover, so the grandfather migration trusts them.
    private func makeRegistry(systemDir: URL? = DchCommandsTests.systemDir, services: RecordingServices,
                              optIn: [String] = [],
                              userExts: [(folder: String, extID: String, commandID: String, result: String)] = []) throws -> ExtensionRegistry {
        if let systemDir {
            try XCTSkipIf(!FileManager.default.fileExists(atPath: systemDir.path), "no extensions dir at \(systemDir.path)")
        }
        let userDir = tempDir("dch-commands-user")
        for e in userExts { try writeExt(in: userDir, folder: e.folder, extID: e.extID, commandID: e.commandID, result: e.result) }
        let defaults = scratchDefaults("dch-commands")
        if !optIn.isEmpty { defaults.set(optIn, forKey: "enabledExtensionIDs") }
        let reg = ExtensionRegistry(systemDir: systemDir, userDir: userDir, hostVersion: "2.0.0",
                                    defaults: defaults, services: services)
        reg.discover()
        return reg
    }

    private func ops(_ reg: ExtensionRegistry?, enabled: Bool = true) -> DchCommandOps {
        DchCommandOps(enabled: { enabled }, registry: { reg })
    }

    // MARK: Frame helpers

    private static func type(_ f: Data) -> UInt8 { f[f.startIndex] }
    private static func json(_ f: Data) -> Any? { try? JSONSerialization.jsonObject(with: f.subdata(in: (f.startIndex + 5)..<f.endIndex)) }
    private static func object(_ f: Data?) -> [String: Any] { f.flatMap { json($0) as? [String: Any] } ?? [:] }
    private static func message(_ f: Data?) -> String? {
        guard let f, type(f) == DchFrame.error else { return nil }
        return object(f)["message"] as? String
    }
    private static func payload(_ obj: Any) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data() }

    /// One request through the ops; exactly one reply.
    private func request(_ ops: DchCommandOps, _ type: UInt8, _ payload: Data, line: UInt = #line) async -> Data? {
        let frames = Frames()
        await ops.handle(type, payload, reply: { frames.append($0) })
        let all = frames.snapshot
        XCTAssertEqual(all.count, 1, "replies", line: line)
        return all.first
    }

    private func runCommand(_ ops: DchCommandOps, _ body: [String: Any], line: UInt = #line) async -> Data? {
        await request(ops, DchFrame.runCommand, Self.payload(body), line: line)
    }

    /// A commandResult's {text, detail?}; nil for any other frame.
    private static func result(_ f: Data?) -> [String: String]? {
        guard let f, type(f) == DchFrame.commandResult else { return nil }
        return json(f) as? [String: String]
    }

    private func listIDs(_ ops: DchCommandOps, line: UInt = #line) async -> [String] {
        let f = await request(ops, DchFrame.commands, Data(), line: line)
        XCTAssertEqual(f.map(Self.type), DchFrame.commandsResp, line: line)
        return (f.flatMap(Self.json) as? [[String: String]] ?? []).compactMap { $0["id"] }
    }

    // MARK: 1-3: gate, handshake, listing

    func testOffRefusesBothRequests() async throws {
        let services = RecordingServices()
        let reg = try makeRegistry(services: services)
        let off = ops(reg, enabled: false)
        let list = await request(off, DchFrame.commands, Data())
        XCTAssertEqual(Self.message(list), "commands are off")
        let run = await runCommand(off, ["id": "calc.eval", "argument": "2+2"])
        XCTAssertEqual(Self.message(run), "commands are off")
        XCTAssertEqual(services.calls, [])
    }

    /// The phone hard-codes these (QA #501 LOW-1); DchChatTests' collision check lists every code.
    func testFrameCodesAreThePhonesContract() {
        XCTAssertEqual([DchFrame.commands, DchFrame.runCommand, DchFrame.commandsResp, DchFrame.commandResult],
                       [0x28, 0x29, 0x2a, 0x2b])
    }

    func testHandshakeAdvertisesCommandsOnlyWhenOn() throws {
        func ops(_ info: [String: Any]) -> [String] { info["ops"] as? [String] ?? [] }
        XCTAssertTrue(ops(DchFrame.machineInfo(deviceID: "d", hostname: "h", wakeId: nil, commands: true)).contains("commands"))
        XCTAssertFalse(ops(DchFrame.machineInfo(deviceID: "d", hostname: "h", wakeId: nil)).contains("commands"))
        // Through a connection: the handshake reads the gate per request.
        for on in [true, false] {
            let rig = connection(DchCommandOps(enabled: { on }, registry: { nil }))
            rig.queue.sync { rig.conn.ingest(DchFrame.encode(DchFrame.machineInfo, [])) }
            let info = rig.frames.snapshot.first { Self.type($0) == DchFrame.machineInfoResp }
            XCTAssertEqual(ops(Self.object(info)).contains("commands"), on, "toggle \(on)")
        }
    }

    func testListIsAllowlistedLiveSystemCommandsOnly() async throws {
        let services = RecordingServices()
        let reg = try makeRegistry(services: services)
        // Every excluded id is live in this registry, so only the allowlist keeps it out.
        for id in ["shell.run", "scripts.run", "killproc.run", "base64.open", "translate.run", "toggles.trash"] {
            XCTAssertEqual(reg.command(id: id)?.record.isLive, true, id)
        }
        let expected = ["calc.eval", "unit.convert", "currency.convert", "openlid.status", "openlid.toggle",
                        "openlid.caffeine", "toggles.lock", "toggles.displayoff", "toggles.screensaver"]
        let f = await request(ops(reg), DchFrame.commands, Self.payload([String: Any]()))
        let rows = f.flatMap(Self.json) as? [[String: String]] ?? []
        // clipclear is opt-in and off here.
        XCTAssertEqual(rows.compactMap { $0["id"] }, expected)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] ?? "", $0) })
        XCTAssertEqual(byID["calc.eval"], ["id": "calc.eval", "title": "Calculate", "ext": "Calculator",
                                           "subtitle": "Evaluate an arithmetic expression", "argument": "2+2"])
        XCTAssertEqual(byID["openlid.toggle"]?["icon"], "bolt.circle")
        XCTAssertEqual(byID["openlid.toggle"]?["ext"], "OpenLid")
        XCTAssertEqual(Set(rows.filter { $0["argument"] != nil }.compactMap { $0["id"] }),
                       ["calc.eval", "unit.convert", "currency.convert"])

        // Opted in, clipclear.now joins at its table position (last).
        let optedIn = try makeRegistry(services: services, optIn: ["com.prosper.clipclear"])
        let withClear = await listIDs(ops(optedIn))
        XCTAssertEqual(withClear, expected + ["clipclear.now"])
        // No registry yet: an empty list, not an error.
        let none = await listIDs(ops(nil))
        XCTAssertEqual(none, [])
        XCTAssertEqual(services.calls, [])
    }

    // MARK: 4-5, 9: real runs (calc and units only)

    func testRunCalcThroughRealRuntime() async throws {
        let services = RecordingServices()
        let reg = try makeRegistry(services: services)
        let f = await runCommand(ops(reg), ["id": "calc.eval", "argument": "2+2"])
        XCTAssertEqual(Self.result(f), ["text": "4"])
        XCTAssertEqual(services.calls, [])
    }

    func testRunUnitsSplitsTriple() async throws {
        let services = RecordingServices()
        let reg = try makeRegistry(services: services)
        let f = await runCommand(ops(reg), ["id": "unit.convert", "argument": "1 km to m"])
        XCTAssertEqual(Self.result(f), ["text": "1000 m", "detail": "km → m"])
        XCTAssertEqual(services.calls, [])
    }

    func testDeclineIsNoResult() async throws {
        let services = RecordingServices()
        let reg = try makeRegistry(services: services)
        let f = await runCommand(ops(reg), ["id": "calc.eval", "argument": "hello"])
        XCTAssertEqual(Self.message(f), "no result")
        // A missing argument is "", which calc declines too.
        let bare = await runCommand(ops(reg), ["id": "calc.eval"])
        XCTAssertEqual(Self.message(bare), "no result")
        XCTAssertEqual(services.calls, [])
    }

    // MARK: 6-8: refusals

    func testRunRefusesNonAllowlisted() async throws {
        let services = RecordingServices()
        let reg = try makeRegistry(services: services)
        let refused: [(String, String)] = [
            ("shell.run", "echo hi"), ("scripts.run", "deploy"), ("killproc.run", "kill 1!"),
            ("base64.open", "hi"), ("translate.run", "hola"), ("toggles.trash", ""), ("toggles.dark", ""),
            ("no.such.command", ""),
            // Allowlisted, but its opt-in extension is off.
            ("clipclear.now", ""),
        ]
        for (id, argument) in refused {
            let f = await runCommand(ops(reg), ["id": id, "argument": argument])
            XCTAssertEqual(Self.message(f), "not allowed", id)
        }
        // No registry yet: refused, never run.
        let none = await runCommand(ops(nil), ["id": "calc.eval", "argument": "2+2"])
        XCTAssertEqual(Self.message(none), "not allowed")
        // A record turned off after the routes were built is refused by its own isLive.
        let calc = try XCTUnwrap(reg.command(id: "calc.eval")).record
        calc.enabled = false
        let disabled = await runCommand(ops(reg), ["id": "calc.eval", "argument": "2+2"])
        XCTAssertEqual(Self.message(disabled), "not allowed")
        let ids = await listIDs(ops(reg))
        XCTAssertFalse(ids.contains("calc.eval"))
        XCTAssertEqual(services.calls, [])
    }

    /// A trusted user extension that declares "calc.eval" takes over commandByID (last
    /// writer wins), but never runs from the phone. Both the isSystem and the extension-id check
    /// refuse it; the next two tests each pin one of them alone.
    func testUserExtensionShadowingIsRefused() async throws {
        let services = RecordingServices()
        let reg = try makeRegistry(services: services, userExts: [
            ("zz-shadow", "com.user.shadow", "calc.eval", "SHADOW"),
        ])
        XCTAssertEqual(reg.command(id: "calc.eval")?.record.id, "com.user.shadow", "precondition: the shadow routes")
        let f = await runCommand(ops(reg), ["id": "calc.eval", "argument": "2+2"])
        XCTAssertEqual(Self.message(f), "not allowed")
        let ids = await listIDs(ops(reg))
        XCTAssertFalse(ids.contains("calc.eval"))
        XCTAssertTrue(ids.contains("unit.convert"))
    }

    /// A user extension that claims the table's own extension id is still not a system
    /// extension. Kills the isSystem check on its own.
    func testUserExtensionWithSystemExtIDIsRefused() async throws {
        let services = RecordingServices()
        let reg = try makeRegistry(systemDir: nil, services: services, userExts: [
            ("calc-user", "com.prosper.calc", "calc.eval", "IMPOSTOR"),
        ])
        let hit = reg.command(id: "calc.eval")
        XCTAssertEqual(hit?.record.id, "com.prosper.calc", "precondition")
        XCTAssertEqual(hit?.record.isLive, true, "precondition")
        XCTAssertEqual(hit?.record.isSystem, false, "precondition")
        let f = await runCommand(ops(reg), ["id": "calc.eval", "argument": "2+2"])
        XCTAssertEqual(Self.message(f), "not allowed")
        let ids = await listIDs(ops(reg))
        XCTAssertEqual(ids, [])
    }

    /// A system extension with another extension id that declares "calc.eval" is refused.
    func testSystemExtensionWithWrongExtIDIsRefused() async throws {
        let services = RecordingServices()
        let fixtureSystem = tempDir("dch-commands-system")
        try writeExt(in: fixtureSystem, folder: "fake", extID: "com.test.fake", commandID: "calc.eval", result: "FAKE")
        let reg = try makeRegistry(systemDir: fixtureSystem, services: services)
        let hit = reg.command(id: "calc.eval")
        XCTAssertEqual(hit?.record.isSystem, true, "precondition")
        XCTAssertEqual(hit?.record.isLive, true, "precondition")
        let f = await runCommand(ops(reg), ["id": "calc.eval", "argument": "2+2"])
        XCTAssertEqual(Self.message(f), "not allowed")
        let ids = await listIDs(ops(reg))
        XCTAssertEqual(ids, [])
    }

    // MARK: 10-11: request and result shapes

    func testMalformed() async throws {
        let services = RecordingServices()
        let reg = try makeRegistry(services: services)
        let o = ops(reg)
        for bad in [Data("nope".utf8), Self.payload([1, 2]), Self.payload([String: Any]()),
                    Self.payload(["id": 5]), Self.payload(["argument": "2+2"]),
                    Self.payload(["id": "calc.eval", "argument": 5]), Data()] {
            let f = await request(o, DchFrame.runCommand, bad)
            XCTAssertEqual(Self.message(f), "malformed", String(decoding: bad, as: UTF8.self))
        }
        for bad in [Self.payload(["x": 1]), Data("nope".utf8), Self.payload([1])] {
            let f = await request(o, DchFrame.commands, bad)
            XCTAssertEqual(Self.message(f), "malformed", String(decoding: bad, as: UTF8.self))
        }
        // The cap is 1 KB of UTF-8: exactly 1024 bytes runs ("1+" x 511, "1", one space).
        let atCap = String(repeating: "1+", count: 511) + "1 "
        XCTAssertEqual(atCap.utf8.count, 1024)
        let ok = await runCommand(o, ["id": "calc.eval", "argument": atCap])
        XCTAssertEqual(Self.result(ok), ["text": "512"])
        let over = await runCommand(o, ["id": "calc.eval", "argument": atCap + "1"])
        XCTAssertEqual(Self.message(over), "argument too long")
        // 513 two-byte characters: under 1024 characters, over 1024 bytes.
        let wide = await runCommand(o, ["id": "calc.eval", "argument": String(repeating: "é", count: 513)])
        XCTAssertEqual(Self.message(wide), "argument too long")
        // The cap holds before the allowlist: a long shell argument is refused either way.
        let longShell = await runCommand(o, ["id": "shell.run", "argument": String(repeating: "x", count: 2000)])
        XCTAssertEqual(Self.message(longShell), "argument too long")
        XCTAssertEqual(services.calls, [])
    }

    func testShapeRules() {
        XCTAssertEqual(Self.result(DchCommandOps.shape("4")), ["text": "4"])
        XCTAssertEqual(Self.result(DchCommandOps.shape("line one\nline two")), ["text": "line one\nline two"])
        XCTAssertEqual(Self.result(DchCommandOps.shape("29.41 EUR\t32 USD → EUR")), ["text": "29.41 EUR", "detail": "32 USD → EUR"])
        XCTAssertEqual(Self.result(DchCommandOps.shape("km\tm\t1000 m")), ["text": "1000 m", "detail": "km → m"])
        XCTAssertEqual(Self.message(DchCommandOps.shape(#"{"type":"list","items":[{"id":"a","title":"Row A"}]}"#)),
                       "unsupported result")
        XCTAssertEqual(Self.message(DchCommandOps.shape(nil)), "no result")
        XCTAssertEqual(Self.message(DchCommandOps.shape("")), "no result")
    }

    // MARK: 12: the connection

    private struct Rig {
        let conn: DchConnection
        let queue: DispatchQueue
        let frames: Frames
    }

    /// The NWConnection is never started; frames go to sendOverride.
    private func connection(_ commands: DchCommandOps) -> Rig {
        let queue = DispatchQueue(label: "test.dchconn.commands")
        let frames = Frames()
        let conn = DchConnection(conn: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), queue: queue,
                                 log: Logger(subsystem: "test", category: "dch"), onClose: { @Sendable _ in })
        conn.sendOverride = { frames.append($0) }
        conn.commands = commands
        addTeardownBlock { queue.sync { conn.close() } }
        return Rig(conn: conn, queue: queue, frames: frames)
    }

    private func waitUntil(_ what: String, line: UInt = #line, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(10)
        while !cond() {
            guard Date() < end else { return XCTFail("timed out waiting for \(what)", line: line) }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testConnectionRepliesOnceAndRefusesWhileInFlight() async throws {
        let services = RecordingServices()
        let reg = try makeRegistry(services: services)
        let r = connection(ops(reg))
        let run = DchFrame.encode(DchFrame.runCommand, json: ["id": "calc.eval", "argument": "2+2"])
        // One block on the queue: the second request arrives while the first is in flight.
        r.queue.sync { r.conn.ingest(run + DchFrame.encode(DchFrame.commands, [])) }
        await waitUntil("the result") { r.frames.snapshot.contains { Self.type($0) == DchFrame.commandResult } }
        let first = r.frames.snapshot
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(Self.message(first.first), "busy with an earlier request")
        XCTAssertEqual(Self.result(first.last), ["text": "4"])
        XCTAssertFalse(r.queue.sync { r.conn.inFlight })

        // The final reply freed the connection for the next request.
        r.queue.sync { r.conn.ingest(DchFrame.encode(DchFrame.commands, [])) }
        await waitUntil("the list") { r.frames.snapshot.count == 3 }
        XCTAssertEqual(r.frames.snapshot.last.map(Self.type), DchFrame.commandsResp)
        XCTAssertEqual(services.calls, [])
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func hit() { lock.withLock { _count += 1 } }
    }

    /// A request after close() never reaches the ops (neither seam is consulted) and sends nothing.
    func testClosedConnectionRunsNothing() async throws {
        let services = RecordingServices()
        let reg = try makeRegistry(services: services)
        let calls = Calls()
        let r = connection(DchCommandOps(enabled: { calls.hit(); return true }, registry: { calls.hit(); return reg }))
        r.queue.sync {
            r.conn.close()
            r.conn.ingest(DchFrame.encode(DchFrame.runCommand, json: ["id": "calc.eval", "argument": "2+2"]))
            r.conn.ingest(DchFrame.encode(DchFrame.commands, []))
        }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(calls.count, 0, "the ops ran after close()")
        XCTAssertEqual(r.frames.snapshot.count, 0)
        XCTAssertFalse(r.queue.sync { r.conn.inFlight })
        XCTAssertEqual(services.calls, [])
    }
}
