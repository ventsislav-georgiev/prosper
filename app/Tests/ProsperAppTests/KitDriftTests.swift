import Foundation
import XCTest
@testable import ProsperApp

// #2099: an applied piece whose slot or block was changed or removed outside Prosper is reported as drifted (the pane's
// notes and kits.list), never repaired on read. Real KitStore and ManagedConfig over the row's own tempDir() roots
// (KitPaneModelTests' fixtures); no real home.
@MainActor
final class KitDriftTests: XCTestCase {
    static let ext = KitPaneModelTests.ext

    /// Counts the ManagedConfig reads of one file (the onRead seam).
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ p: String) { lock.withLock { paths.append(p) } }
        func reset() { lock.withLock { paths = [] } }
        func count(suffix: String) -> Int { lock.withLock { paths.filter { $0.hasSuffix(suffix) }.count } }
    }

    private func settings(_ e: KitRuntimeTests.Env) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: e.settings)) as? [String: Any])
    }

    private func writeSettings(_ e: KitRuntimeTests.Env, _ s: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]).write(to: e.settings)
    }

    /// An applied kit and its model.
    private func applied(_ e: KitRuntimeTests.Env) async throws -> KitPaneModel {
        let r = ExtensionRecord(loaded: try kitPaneSource(e), enabled: true, trusted: true)
        let m = KitPaneModel(extID: Self.ext, owner: kitPaneOwner(e) { [r] })
        await m.load()?.value
        await m.apply()?.value
        XCTAssertEqual(m.result, "done")
        return m
    }

    func testUntouchedAppliedKitIsNotDrifted() async throws {
        let e = try kitPaneEnv()
        let m = try await applied(e)
        XCTAssertTrue(m.facts?.status?.pieces.contains { $0.id == "hud" && $0.state == .applied } == true, "\(String(describing: m.facts?.status?.pieces))")
        XCTAssertEqual(m.facts?.drifted, [])
        XCTAssertFalse(KitPaneView.notes(m).contains(KitPaneModel.driftNote("hud")))
    }

    /// The QA case: the statusLine the hud piece set was removed by hand.
    func testRemovedStatusLineIsDriftedAndNothingIsWritten() async throws {
        let e = try kitPaneEnv()
        let m = try await applied(e)
        var s = try settings(e)
        s["statusLine"] = nil
        try writeSettings(e, s)
        let before = try Data(contentsOf: e.settings)
        await m.load()?.value
        XCTAssertEqual(m.facts?.drifted, ["hud"])
        XCTAssertTrue(KitPaneView.notes(m).contains("hud was changed outside Prosper; Repair puts it back"), "\(KitPaneView.notes(m))")
        XCTAssertEqual(try Data(contentsOf: e.settings), before, "no repair on read")
        XCTAssertTrue(try settings(e)["statusLine"] == nil)
    }

    func testHandChangedStatusLineIsDrifted() async throws {
        let e = try kitPaneEnv()
        let m = try await applied(e)
        var s = try settings(e)
        s["statusLine"] = ["type": "command", "command": "someone-else"]
        try writeSettings(e, s)
        await m.load()?.value
        XCTAssertEqual(m.facts?.drifted, ["hud"])
    }

    /// A text block gone: the rules block taken out of CLAUDE.md.
    func testRemovedBlockIsDrifted() async throws {
        let e = try kitPaneEnv()
        let m = try await applied(e)
        try Data(KitRuntimeTests.userMD.utf8).write(to: e.claudeMD)
        await m.load()?.value
        XCTAssertEqual(m.facts?.drifted, ["rules"])
    }

    func testNeverAppliedKitIsNotDrifted() async throws {
        let e = try kitPaneEnv()
        let r = ExtensionRecord(loaded: try kitPaneSource(e), enabled: true, trusted: true)
        let m = KitPaneModel(extID: Self.ext, owner: kitPaneOwner(e) { [r] })
        await m.load()?.value
        XCTAssertTrue(m.facts != nil && m.facts?.status?.live == nil)
        XCTAssertEqual(m.facts?.drifted, [])
    }

    /// Off, not live, or not a drift state: never drifted.
    func testOffOrNotLivePiecesAreNeverDrifted() {
        let hud = ManagedConfigPieceStatus(id: "hud", state: .missing, target: "claude:settings.json", path: "/Users/example/.claude/settings.json")
        let ok = ManagedConfigPieceStatus(id: "rules", state: .applied, target: "claude:CLAUDE.md", path: "/Users/example/.claude/CLAUDE.md")
        XCTAssertEqual(KitPaneModel.drifted(KitRuntimeStatus(pieces: [hud, ok], off: [], live: "1.0.0")), ["hud"])
        XCTAssertEqual(KitPaneModel.drifted(KitRuntimeStatus(pieces: [hud, ok], off: ["hud"], live: "1.0.0")), [])
        XCTAssertEqual(KitPaneModel.drifted(KitRuntimeStatus(pieces: [hud, ok], off: [], live: nil)), [])
        XCTAssertEqual(KitPaneModel.drifted(nil), [])
        for st in [ManagedConfigPieceState.replaced, .drifted] {
            XCTAssertEqual(KitPaneModel.drifted(KitRuntimeStatus(pieces: [.init(id: "x", state: st, target: "", path: "")], off: [], live: "1")), ["x"], "\(st)")
        }
        for st in [ManagedConfigPieceState.applied, .adopted, .notApplied, .unwritable, .corrupt, .orphaned, .importMissing, .conflict] {
            XCTAssertEqual(KitPaneModel.drifted(KitRuntimeStatus(pieces: [.init(id: "x", state: st, target: "", path: "")], off: [], live: "1")), [], "\(st)")
        }
    }

    /// PERF: one status reads settings.json once, though several applied pieces live in it.
    func testStatusReadsEachTargetOnce() async throws {
        let base = try kitPaneEnv()
        let reads = Reads()
        let mc = ManagedConfig(roots: base.roots, consent: base.consent, writer: ManagedConfigPOSIXWriter(), onRead: { reads.add($0) })
        let e = KitRuntimeTests.Env(root: base.root, roots: base.roots, consent: base.consent, provider: ManagedConfigProvider(mc))
        let ext = try kitPaneSource(e)
        let rt = KitRuntime(provider: e.provider, store: try KitStore(configHome: e.roots.configHome, extID: Self.ext),
                            isTrusted: { _ in true }, now: { Date() })
        let r = await rt.apply(ext)
        XCTAssertEqual(r.failures, [])
        reads.reset()
        let s = try XCTUnwrap(rt.status(ext))
        let inSettings = s.pieces.filter { $0.path.hasSuffix("/settings.json") }
        XCTAssertGreaterThanOrEqual(inSettings.count, 3, "\(s.pieces)")
        XCTAssertEqual(reads.count(suffix: "/settings.json"), 1)
        XCTAssertEqual(KitPaneModel.drifted(s), [])
    }
}
