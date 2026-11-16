import Foundation
import XCTest
@testable import ProsperApp

// #1421 (#918 S1): what the kit pane needs from KitRuntime: one op at a time, refresh after a relaunch, a tool switched
// off on its own, a checked selection and a preview. Real KitStore and ManagedConfig over the row's own tempDir() roots;
// the consent is a recording fake; no kit file is ever run.

/// A consent whose FIRST sheet parks until the row calls release(); every sheet is then answered (and recorded) by
/// `inner`, so inner.seen counts answered sheets only. No sleep: the row waits on waitParked().
final class KitParkedConsent: ManagedConfigConsent, @unchecked Sendable {
    let inner: KitRTConsent
    private let lock = NSLock()
    private var first = true
    private var parked: CheckedContinuation<Void, Never>?
    private var _didPark = false
    private var woken = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(_ inner: KitRTConsent) { self.inner = inner }

    func confirm(_ changes: ManagedConfigChangeSet) async -> Bool {
        let park = lock.withLock { () -> Bool in
            defer { first = false }
            return first
        }
        if park {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                lock.withLock { parked = k; _didPark = true }
                wake()
            }
        }
        return await inner.confirm(changes)
    }

    var didPark: Bool { lock.withLock { _didPark } }

    /// Returns once the first sheet parked, or once wake() ran (the op's task calls it when it ends, so an op that never
    /// asks cannot leave the row waiting).
    func waitParked() async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if woken { return true }
                waiter = k
                return false
            }
            if now { k.resume() }
        }
    }

    func wake() {
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            woken = true
            defer { waiter = nil }
            return waiter
        }
        w?.resume()
    }

    func release() {
        let k = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { parked = nil }
            return parked
        }
        k?.resume()
    }
}

final class KitRuntimePaneTests: XCTestCase {
    typealias Env = KitRuntimeTests.Env
    static let ext = KitRuntimeTests.ext
    static let slug = KitRuntimeTests.slug

    /// The fixture plus needs (guard needs tools, hud needs guard) and a second claude-md piece "extra" without the
    /// local.md line (as KitRenderTests' neededFixture).
    static let neededKit = KitFixture.kit(replacing: #"id      = "guard""#, with: "id      = \"guard\"\nneeds   = [\"tools\"]")
        .replacingOccurrences(of: #"id          = "hud""#, with: "id          = \"hud\"\nneeds       = [\"guard\"]")
        .replacingOccurrences(of: "\n[[contributes.kit.settings]]",
                              with: "\n[[contributes.kit.pieces]]\nid     = \"extra\"\nkind   = \"claude-md\"\nsource = \"EXTRA.md\"\n\n[[contributes.kit.settings]]")

    /// `sheet`: what ManagedConfig asks (default: the recording consent itself).
    private func env(_ consent: KitRTConsent = KitRTConsent(), sheet: (any ManagedConfigConsent)? = nil,
                     label: String = #function) throws -> Env {
        let root = tempDir(label)
        let roots = ManagedConfigRoots(claude: root.appendingPathComponent("claude home", isDirectory: true),
                                       configHome: root.appendingPathComponent("config", isDirectory: true),
                                       stateDir: root.appendingPathComponent("state", isDirectory: true))
        for d in [roots.claude, roots.configHome] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data(KitRuntimeTests.userMD.utf8).write(to: roots.claude.appendingPathComponent("CLAUDE.md"))
        try Data(KitRuntimeTests.userSettings.utf8).write(to: roots.claude.appendingPathComponent("settings.json"))
        let clock = MCClock()
        let mc = ManagedConfig(roots: roots, consent: sheet ?? consent, writer: ManagedConfigPOSIXWriter(), now: { clock.now() })
        return Env(root: root, roots: roots, consent: consent, provider: ManagedConfigProvider(mc))
    }

    private func runtime(_ e: Env) throws -> KitRuntime {
        KitRuntime(provider: e.provider, store: try KitStore(configHome: e.roots.configHome, extID: Self.ext),
                   isTrusted: { _ in true }, now: { Date() })
    }

    /// A kit source dir under the row's tempDir: every piece kind, a tools piece with TWO tools, plus `extra` files.
    private func source(_ e: Env, id: String = KitRuntimePaneTests.ext, version: String, kit: String = KitFixture.kit,
                        timeout: Int = 10, readme: String = KitDirFixture.readme, extra: [(String, String, Int)] = []) throws -> LoadedExtension {
        let dir = e.root.appendingPathComponent("sources/\(id)-\(version)", isDirectory: true)
        let head = KitFixture.head.replacingOccurrences(of: "\"dev.example.kit.calm-agent\"", with: "\"\(id)\"")
            .replacingOccurrences(of: "\"1.0.0\"", with: "\"\(version)\"")
            .replacingOccurrences(of: "\"2.170.0\"", with: "\"0.0.1\"") // any host the test bundle reports loads it
        let body = kit.replacingOccurrences(of: "timeout = 10", with: "timeout = \(timeout)")
        let files: [(String, String, Int)] = [
            ("extension.toml", head + "\n" + body + "\n", 0o644), ("README.md", readme, 0o644),
            ("CLAUDE.md", KitDirFixture.claudeMD, 0o644), ("init.lua", "return {}\n", 0o644),
            ("hooks/guard.sh", KitDirFixture.guardScript, 0o755), ("statusline/hud.mjs", "console.log('calm')\n", 0o644),
            ("tools/calm-note", "#!/bin/sh\necho note\n", 0o755), ("tools/calm-todo", "#!/bin/sh\necho todo\n", 0o755),
            ("seed/notes.toml", "# your notes\n", 0o644)] + extra
        for (rel, text, mode) in files {
            let u = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: u.path)
        }
        return LoadedExtension(manifest: try KitFixture.manifest(body, head: head), directory: dir, isSystem: false)
    }

    private func neededSource(_ e: Env, version: String = "1.0.0") throws -> LoadedExtension {
        try source(e, version: version, kit: Self.neededKit, extra: [("EXTRA.md", "# extra rules\n", 0o644)])
    }

    private func validated(_ rt: KitRuntime, _ ext: LoadedExtension, line: UInt = #line) throws -> KitValidated {
        let p = rt.preview(ext, source: .local, otherKitSlugs: [])
        guard case .ok(let v) = p else { XCTFail("\(p)", line: line); throw CancellationError() }
        return v
    }

    private func bytes(_ u: URL) -> [UInt8]? { (try? Data(contentsOf: u)).map(Array.init) }
    private func bytes(_ path: String) -> [UInt8]? { bytes(URL(fileURLWithPath: path)) }
    private func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    private func kind(_ path: String) -> KitFileKind { KitPOSIXFS().kind(path) }
    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    private func settings(_ e: Env) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: e.settings)) as? [String: Any])
    }

    private func records(_ e: Env) throws -> [ManagedConfigRecord] {
        let b = try XCTUnwrap(bytes(e.roots.stateDir.appendingPathComponent("state.json")))
        return try XCTUnwrap(ManagedConfig.decodeState(b)).records
    }

    // MARK: single-flight (R1402-i1)

    /// The first apply parks at its sheet; a second apply, a rollback, a remove, a repair and a refresh during it are
    /// refused busy and touch nothing; after the first returns, a new call runs.
    func testASecondOpWhileOneRunsIsRefusedBusy() async throws {
        let rec = KitRTConsent()
        let gate = KitParkedConsent(rec)
        let e = try env(rec, sheet: gate)
        let rt = try runtime(e)
        let ext = try source(e, version: "1.0.0")
        let (md, st) = (bytes(e.claudeMD), bytes(e.settings))
        let first = Task { () -> KitRuntimeResult in
            let r = await rt.apply(ext, source: .local, otherKitSlugs: [])
            gate.wake()
            return r
        }
        await gate.waitParked()
        XCTAssertTrue(gate.didPark, "the first apply is parked at its sheet")
        let second = await rt.apply(ext, source: .local, otherKitSlugs: [])
        let back = await rt.rollback(ext)
        let gone = await rt.remove(ext)
        let fixed = await rt.repair(ext)
        let busyStatus = await rt.refresh(ext)
        for r in [second, back, gone, fixed] {
            XCTAssertEqual(r.refused, KitRuntime.busyText)
            XCTAssertTrue(r.state == nil && r.config == nil)
            XCTAssertEqual(r.failures, [])
        }
        XCTAssertEqual(busyStatus?.notes, [KitRuntime.busyText])
        XCTAssertTrue(busyStatus?.live == nil)
        XCTAssertEqual(rec.seen.count, 0, "no sheet answered while the first is parked")
        XCTAssertEqual(bytes(e.claudeMD), md)
        XCTAssertEqual(bytes(e.settings), st)
        gate.release()
        let r = await first.value
        XCTAssertEqual(r.failures, [])
        XCTAssertEqual(r.state?.live.version, "1.0.0")
        XCTAssertEqual(rec.seen.count, 1, "the sheet was seen once: the busy calls asked nothing")
        let again = await rt.repair(ext)
        XCTAssertTrue(again.refused == nil, "\(String(describing: again.refused))")
        XCTAssertEqual(again.config?.ok, true)
        let status = await rt.refresh(ext)
        XCTAssertEqual(status?.live, "1.0.0")
        XCTAssertEqual(status?.notes, [])
    }

    /// Every refused or early return releases the flag: the next call is never refused busy.
    func testEveryRefusedReturnReleasesTheFlag() async throws {
        let e = try env()
        let rt = try runtime(e)
        let ext = try source(e, version: "1.0.0")
        let other = try source(e, id: "com.example.other", version: "1.0.0")
        let notMine = await rt.apply(other, source: .local, otherKitSlugs: [])
        XCTAssertEqual(notMine.refused, "not this runtime's kit")
        let back = await rt.rollback(ext)
        XCTAssertEqual(back.refused, "nothing applied")
        let gone = await rt.remove(ext)
        XCTAssertEqual(gone.refused, "nothing applied")
        let fixed = await rt.repair(ext)
        XCTAssertEqual(fixed.refused, "nothing applied")
        let otherStatus = await rt.refresh(other)
        XCTAssertTrue(otherStatus == nil)
        let r = await rt.apply(ext, source: .local, otherKitSlugs: [])
        XCTAssertTrue(r.refused == nil, "\(String(describing: r.refused))")
        XCTAssertEqual(r.failures, [])
        XCTAssertEqual(r.state?.live.version, "1.0.0")
        XCTAssertEqual(e.consent.seen.count, 1)
    }

    // MARK: refresh after a relaunch (#1409 S3)

    func testRefreshAfterARelaunchReportsLiveAndItsPieces() async throws {
        let e = try env()
        let rt = try runtime(e)
        let ext = try source(e, version: "1.0.0")
        let r = await rt.apply(ext, source: .local, otherKitSlugs: [])
        XCTAssertEqual(r.failures, [])
        let before = try XCTUnwrap(rt.status(ext))
        XCTAssertEqual(before.live, "1.0.0")
        XCTAssertFalse(before.pieces.isEmpty)
        let relaunched = try runtime(e)
        XCTAssertEqual(relaunched.current?.live.version, "1.0.0")
        XCTAssertTrue(relaunched.status(ext)?.live == nil, "status alone does not validate live again (the S3 limit)")
        let refreshed = await relaunched.refresh(ext)
        let warm = try XCTUnwrap(refreshed)
        XCTAssertEqual(warm.live, "1.0.0")
        XCTAssertEqual(warm.notes, [])
        XCTAssertEqual(warm.pieces.map(\.id), before.pieces.map(\.id), "the declared pieces")
        XCTAssertEqual(Set(warm.pieces.map(\.state)), [.applied])
        XCTAssertEqual(relaunched.status(ext)?.live, "1.0.0", "status after a refresh")
        XCTAssertEqual(e.consent.seen.count, 1, "refresh asks nothing")
    }

    // MARK: per-tool off (G1 c)

    func testAToolSwitchedOffHasNoShimAndStaysOffAcrossAnUpdate() async throws {
        let e = try env()
        let rt = try runtime(e)
        let v1 = try source(e, version: "1.0.0"), v2 = try source(e, version: "2.0.0", timeout: 20)
        let v = try validated(rt, v1)
        XCTAssertEqual(v.tools["tools"]?.map(\.name).sorted(), ["calm-note", "calm-todo"])
        let sel = try rt.setSelection(v, off: [], offTools: ["tools": ["calm-todo", "no-such-tool"], "no-such-piece": ["x"]])
        XCTAssertEqual(sel, .closed(off: [], unknown: []))
        XCTAssertEqual(rt.offTools(), ["tools": ["calm-todo"]], "only the kit's own tools are written")
        let bin = rt.store.layout.bin
        let r = await rt.apply(v1, source: .local, otherKitSlugs: [])
        XCTAssertEqual(r.failures, [])
        XCTAssertEqual(r.state?.live.version, "1.0.0")
        XCTAssertTrue(exists(bin + "/calm-note"))
        XCTAssertFalse(exists(bin + "/calm-todo"), "a tool switched off gets no shim")
        let up = await rt.apply(v2, source: .local, otherKitSlugs: [])
        XCTAssertEqual(up.failures, [])
        XCTAssertEqual(up.state?.live.version, "2.0.0")
        XCTAssertTrue(exists(bin + "/calm-note"))
        XCTAssertFalse(exists(bin + "/calm-todo"), "the tool stays off across an update (4.12 row 5)")
        XCTAssertEqual(rt.offTools(), ["tools": ["calm-todo"]])
    }

    func testAnOldPiecesFileWithoutOffToolsStillDecodes() throws {
        let e = try env()
        let rt = try runtime(e)
        try rt.store.ensureLayout()
        try Data(#"{"off":["hud"]}"#.utf8).write(to: URL(fileURLWithPath: rt.store.layout.piecesJSON))
        XCTAssertEqual(rt.off(), ["hud"])
        XCTAssertEqual(rt.offTools(), [:])
    }

    // MARK: checked selection (G1 a, b)

    func testSwitchingANeededPieceOffWritesItsDependentsToo() throws {
        let e = try env()
        let rt = try runtime(e)
        let v = try validated(rt, try neededSource(e))
        let r = try rt.setSelection(v, off: ["tools"])
        XCTAssertEqual(r, .closed(off: ["tools", "guard", "hud"], unknown: []))
        XCTAssertEqual(rt.off(), ["tools", "guard", "hud"], "the closed set is written, not the asked one")
    }

    func testTheLocalPieceOffWhileAnotherClaudeMDIsOnIsRefusedUnwritten() throws {
        let e = try env()
        let rt = try runtime(e)
        let v = try validated(rt, try neededSource(e))
        let refusal = KitSelectionResult.refused(KitRefusal(subject: "rules", reason: .localPieceStaysOn))
        XCTAssertEqual(try rt.setSelection(v, off: ["rules"]), refusal)
        XCTAssertEqual(kind(e.roots.configHome.path + "/prosper"), .missing, "nothing written")
        XCTAssertEqual(try rt.setSelection(v, off: ["hud"]), .closed(off: ["hud"], unknown: []))
        let saved = bytes(rt.store.layout.piecesJSON)
        XCTAssertTrue(saved != nil)
        XCTAssertEqual(try rt.setSelection(v, off: ["rules", "hud"]), refusal)
        XCTAssertEqual(bytes(rt.store.layout.piecesJSON), saved, "pieces.json unchanged")
        XCTAssertEqual(rt.off(), ["hud"])
    }

    func testAPieceUncheckedBeforeTheFirstApplyNeverReachesClaudeCode() async throws {
        let e = try env()
        let rt = try runtime(e)
        let ext = try neededSource(e)
        let v = try validated(rt, ext)
        XCTAssertEqual(try rt.setSelection(v, off: ["guard", "extra"]), .closed(off: ["guard", "hud", "extra"], unknown: []))
        let r = await rt.apply(ext, source: .local, otherKitSlugs: [])
        XCTAssertEqual(r.failures, [])
        XCTAssertEqual(r.state?.live.version, "1.0.0")
        let md = try XCTUnwrap(text(e.claudeMD.path))
        XCTAssertTrue(md.contains(KitRender.importLine(rt.store.layout.live + "/CLAUDE.md") ?? "?"), md)
        XCTAssertFalse(md.contains("EXTRA.md"), md)
        let doc = try settings(e)
        XCTAssertEqual((doc["statusLine"] as? [String: Any])?["command"] as? String, "my-own-status")
        XCTAssertEqual(((doc["hooks"] as? [String: Any])?["PreToolUse"] as? [Any])?.count, 1, "the person's own hook only")
        let ids = Set(try records(e).map(\.piece.id))
        XCTAssertTrue(ids.isDisjoint(with: ["guard", "hud", "extra"]), "\(ids)")
        XCTAssertTrue(ids.contains("rules"), "\(ids)")
    }

    // MARK: preview (the install sheet)

    func testPreviewValidatesTheSourceAndWritesNothing() async throws {
        let e = try env()
        let rt = try runtime(e)
        let (md, st) = (bytes(e.claudeMD), bytes(e.settings))
        let ext = try source(e, version: "1.0.0")
        guard case .ok(let v) = rt.preview(ext, source: .market, otherKitSlugs: []) else { return XCTFail("refused") }
        XCTAssertEqual(v.version, "1.0.0")
        XCTAssertEqual(v.localPiece, "rules")
        guard case .refused(let taken) = rt.preview(ext, source: .local, otherKitSlugs: [Self.slug]) else { return XCTFail("not refused") }
        XCTAssertTrue(taken.contains { $0.reason == .slugTaken }, "\(taken)")
        let noRemove = KitDirFixture.readme.replacingOccurrences(of: "## Remove", with: "## Later")
        let bad = try source(e, version: "1.0.1", readme: noRemove)
        guard case .refused(let why) = rt.preview(bad, source: .local, otherKitSlugs: []) else { return XCTFail("not refused") }
        XCTAssertTrue(why.contains { $0.reason == .readmeHeading }, "\(why)")
        XCTAssertEqual(kind(e.roots.configHome.path + "/prosper"), .missing, "nothing under kits/")
        XCTAssertEqual(kind(e.roots.stateDir.path), .missing)
        XCTAssertEqual(e.consent.seen.count, 0)
        XCTAssertEqual(bytes(e.claudeMD), md)
        XCTAssertEqual(bytes(e.settings), st)
    }

    // MARK: L6 (source and otherKitSlugs explicit)

    func testTheMarketByteCapRefusesABigSourceAndLocalApplies() async throws {
        let e = try env()
        let rt = try runtime(e)
        let (md, st) = (bytes(e.claudeMD), bytes(e.settings))
        // 324,000 bytes: over KitStore.marketByteCap (256 KiB), far under localByteCap
        let big = String(repeating: "calm notes, nothing to run\n", count: 12_000)
        let ext = try source(e, version: "1.0.0", extra: [("docs/big.txt", big, 0o644)])
        let market = await rt.apply(ext, source: .market, otherKitSlugs: [])
        XCTAssertTrue(market.refused?.hasPrefix("source:") == true, "\(String(describing: market.refused))")
        XCTAssertTrue(market.state == nil)
        XCTAssertEqual(e.consent.seen.count, 0)
        XCTAssertEqual(kind(rt.store.layout.live), .missing)
        XCTAssertEqual(bytes(e.claudeMD), md)
        XCTAssertEqual(bytes(e.settings), st)
        let local = await rt.apply(ext, source: .local, otherKitSlugs: [])
        XCTAssertTrue(local.refused == nil, "\(String(describing: local.refused))")
        XCTAssertEqual(local.failures, [])
        XCTAssertEqual(local.state?.live.version, "1.0.0")
    }
}
