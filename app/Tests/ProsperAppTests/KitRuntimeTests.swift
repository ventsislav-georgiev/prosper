import Foundation
import XCTest
@testable import ProsperApp

// #1402 (#917 S6): KitRuntime over the real KitStore and a real ManagedConfig. Every root (claude:, the config home, the
// state dir, the kit sources) is under the row's own tempDir(); the consent is a recording fake; no kit file is ever run.

/// Records every sheet; answers from `answers` first, then `fallback`. `onAsk` runs with the ask's number (1-based).
final class KitRTConsent: ManagedConfigConsent, @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [ManagedConfigChangeSet] = []
    private var answers: [Bool]
    private let fallback: Bool
    private let onAsk: (@Sendable (Int) -> Void)?

    init(_ fallback: Bool = true, answers: [Bool] = [], onAsk: (@Sendable (Int) -> Void)? = nil) {
        self.fallback = fallback
        self.answers = answers
        self.onAsk = onAsk
    }

    func confirm(_ changes: ManagedConfigChangeSet) async -> Bool {
        let (n, yes) = lock.withLock { () -> (Int, Bool) in
            _seen.append(changes)
            return (_seen.count, answers.isEmpty ? fallback : answers.removeFirst())
        }
        onAsk?(n)
        return yes
    }

    var seen: [ManagedConfigChangeSet] { lock.withLock { _seen } }
}

final class KitRuntimeTests: XCTestCase {
    static let ext = "com.example.kit"
    static let slug = "calm-agent"

    struct Env {
        let root: URL
        let roots: ManagedConfigRoots
        let consent: KitRTConsent
        let provider: ManagedConfigProvider
        var claudeMD: URL { roots.claude.appendingPathComponent("CLAUDE.md") }
        var settings: URL { roots.claude.appendingPathComponent("settings.json") }
    }

    static let userMD = "# My own rules\n\nBe kind.\n"
    static let userSettings = """
    {
      "env": {
        "EXAMPLE_TOKEN": "dummy-value"
      },
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              { "type": "command", "command": "my-own-guard" }
            ]
          }
        ]
      },
      "permissions": {
        "allow": ["Bash(ls:*)"]
      },
      "statusLine": { "type": "command", "command": "my-own-status" }
    }

    """

    private func env(_ consent: KitRTConsent = KitRTConsent(), label: String = #function) throws -> Env {
        let root = tempDir(label)
        let roots = ManagedConfigRoots(claude: root.appendingPathComponent("claude home", isDirectory: true),
                                       configHome: root.appendingPathComponent("config", isDirectory: true),
                                       stateDir: root.appendingPathComponent("state", isDirectory: true))
        // the claude: root and the config home (~/.config) exist; Prosper creates only its own dirs under them
        for d in [roots.claude, roots.configHome] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data(Self.userMD.utf8).write(to: roots.claude.appendingPathComponent("CLAUDE.md"))
        try Data(Self.userSettings.utf8).write(to: roots.claude.appendingPathComponent("settings.json"))
        let clock = MCClock()
        let mc = ManagedConfig(roots: roots, consent: consent, writer: ManagedConfigPOSIXWriter(), now: { clock.now() })
        return Env(root: root, roots: roots, consent: consent, provider: ManagedConfigProvider(mc))
    }

    private func runtime(_ e: Env, _ id: String = KitRuntimeTests.ext, trusted: Bool = true) throws -> KitRuntime {
        KitRuntime(provider: e.provider, store: try KitStore(configHome: e.roots.configHome, extID: id),
                   isTrusted: { _ in trusted }, now: { Date() })
    }

    /// A kit source dir with every piece kind (KitFixture.kit), its own extension.toml, under the row's tempDir.
    private func source(_ e: Env, id: String = KitRuntimeTests.ext, name: String = KitRuntimeTests.slug, version: String,
                        timeout: Int = 10, seed: String = "# your notes\n") throws -> LoadedExtension {
        let dir = e.root.appendingPathComponent("sources/\(id)-\(name)-\(version)", isDirectory: true)
        let head = KitFixture.head.replacingOccurrences(of: "\"dev.example.kit.calm-agent\"", with: "\"\(id)\"")
            .replacingOccurrences(of: "\"calm-agent\"", with: "\"\(name)\"").replacingOccurrences(of: "\"1.0.0\"", with: "\"\(version)\"")
            .replacingOccurrences(of: "\"2.170.0\"", with: "\"0.0.1\"") // any host the test bundle reports loads it
        let kit = KitFixture.kit.replacingOccurrences(of: "timeout = 10", with: "timeout = \(timeout)")
        let files: [(String, String, Int)] = [
            ("extension.toml", head + "\n" + kit + "\n", 0o644), ("README.md", KitDirFixture.readme, 0o644),
            ("CLAUDE.md", KitDirFixture.claudeMD, 0o644), ("init.lua", "return {}\n", 0o644),
            ("hooks/guard.sh", KitDirFixture.guardScript, 0o755), ("statusline/hud.mjs", "console.log('calm')\n", 0o644),
            ("tools/calm-note", "#!/bin/sh\necho note\n", 0o755), ("seed/notes.toml", seed, 0o644)]
        for (rel, text, mode) in files {
            let u = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: u.path)
        }
        return LoadedExtension(manifest: try KitFixture.manifest(kit, head: head), directory: dir, isSystem: false)
    }

    private func bytes(_ u: URL) -> [UInt8]? { (try? Data(contentsOf: u)).map(Array.init) }
    /// every file under a store dir by relative path (a dir listed with no bytes)
    private func snapshot(_ dir: String) -> [String: Data] {
        var out: [String: Data] = [:]
        for case let rel as String in FileManager.default.enumerator(atPath: dir)?.allObjects ?? [] {
            out[rel] = (try? Data(contentsOf: URL(fileURLWithPath: dir + "/" + rel))) ?? Data()
        }
        return out
    }
    private func text(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    private func kind(_ path: String) -> KitFileKind { KitPOSIXFS().kind(path) }
    private func list(_ dir: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() }
    /// the version line of the extension.toml in a store dir (live, previous)
    private func version(_ dir: String) -> String? {
        text(dir + "/extension.toml")?.split(separator: "\n").first { $0.hasPrefix("version") }.map { String($0.split(separator: "\"").dropFirst().first ?? "") }
    }

    private func settings(_ e: Env) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: e.settings)) as? [String: Any])
    }

    private func statusCommand(_ e: Env) throws -> String? { (try settings(e)["statusLine"] as? [String: Any])?["command"] as? String }

    /// the kit's PreToolUse handler's timeout (the kit's group is appended after the person's own)
    private func kitHookTimeout(_ e: Env) throws -> Int? {
        let pre = try XCTUnwrap((try settings(e)["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        return ((pre.last?["hooks"] as? [[String: Any]])?.first)?["timeout"] as? Int
    }

    private func records(_ e: Env) throws -> [ManagedConfigRecord] {
        let b = try XCTUnwrap(bytes(e.roots.stateDir.appendingPathComponent("state.json")))
        return try XCTUnwrap(ManagedConfig.decodeState(b)).records
    }

    // MARK: rows

    func testUntrustedKitHasNoApply() async throws {
        let e = try env()
        let rt = try runtime(e, trusted: false)
        let ext = try source(e, version: "1.0.0")
        let (md, st) = (bytes(e.claudeMD), bytes(e.settings))
        let r = await rt.apply(ext)
        XCTAssertTrue(r.refused?.hasPrefix("untrusted") == true, "\(String(describing: r.refused))")
        XCTAssertTrue(r.state == nil)
        let rb = await rt.rollback(ext)
        XCTAssertTrue(rb.refused?.hasPrefix("untrusted") == true)
        let rp = await rt.repair(ext)
        XCTAssertTrue(rp.refused?.hasPrefix("untrusted") == true)
        XCTAssertEqual(e.consent.seen.count, 0, "no consent asked")
        XCTAssertEqual(kind(e.roots.configHome.path + "/prosper"), .missing, "no write to Prosper's own dirs")
        XCTAssertEqual(kind(e.roots.stateDir.path), .missing, "no managed-config state")
        XCTAssertEqual(bytes(e.claudeMD), md)
        XCTAssertEqual(bytes(e.settings), st)
    }

    func testApplyRemoveRoundTripIsByteIdentical() async throws {
        let e = try env()
        let rt = try runtime(e)
        let ext = try source(e, version: "1.0.0")
        let (md, st) = (bytes(e.claudeMD), bytes(e.settings))
        let layout = rt.store.layout
        let r = await rt.apply(ext)
        XCTAssertEqual(r.failures, [])
        XCTAssertEqual(r.state?.live.version, "1.0.0")
        XCTAssertEqual(r.state?.phase, .idle)
        XCTAssertEqual(version(layout.live), "1.0.0")
        // one sheet: asked at askConsent, it answered the wiring too; #1075's warning reads the hook and the status line
        XCTAssertEqual(e.consent.seen.count, 1)
        let sheet = try XCTUnwrap(e.consent.seen.first)
        XCTAssertEqual(sheet.owner, Self.ext)
        XCTAssertEqual(ManagedConfigCommandWarning.count(sheet), 2)
        let ctx = KitRenderContext.standard(extensionID: Self.ext, slug: Self.slug, kitDir: URL(fileURLWithPath: layout.live),
                                            home: e.root, configHome: e.roots.configHome)
        let newMD = try XCTUnwrap(text(e.claudeMD.path))
        XCTAssertTrue(newMD.hasPrefix(Self.userMD), newMD)
        XCTAssertTrue(newMD.contains("\n" + (KitRender.importLine(layout.live + "/CLAUDE.md") ?? "?") + "\n"), newMD)
        XCTAssertEqual(try statusCommand(e), KitRender.runnerLine(ctx, pieceID: "hud", name: "hud", target: layout.live + "/statusline/hud.mjs", interpreter: "node"))
        XCTAssertEqual(try kitHookTimeout(e), 10)
        let perms = try XCTUnwrap(try settings(e)["permissions"] as? [String: Any])
        XCTAssertEqual(perms["allow"] as? [String], ["Bash(ls:*)", "Bash(calm-note:*)"])
        XCTAssertEqual(perms["deny"] as? [String], ["Bash(rm -rf:*)"])
        XCTAssertEqual(text(layout.bin + "/calm-note"), KitRender.shimText(ctx, pieceID: "tools", name: "calm-note", target: layout.live + "/tools/calm-note"))
        let kitConfig = e.roots.configHome.appendingPathComponent(Self.slug)
        XCTAssertEqual(text(kitConfig.path + "/notes.toml"), "# your notes\n")
        XCTAssertEqual(text(kitConfig.path + "/local.md"), KitRender.localTemplate)
        // the live copy's Markdown is rendered with the recorded slug's kit config
        XCTAssertTrue(text(layout.live + "/CLAUDE.md")?.contains("@" + KitRender.escapeImport(kitConfig.path) + "/local.md") == true)

        let removed = await rt.remove(ext)
        XCTAssertEqual(removed.config?.status, .done, removed.config?.message ?? "")
        XCTAssertEqual(removed.failures, [])
        XCTAssertEqual(bytes(e.claudeMD), md)
        XCTAssertEqual(bytes(e.settings), st)
        XCTAssertEqual(kind(layout.bin + "/calm-note"), .missing, "the shim is deleted")
        XCTAssertEqual(kind(kitConfig.path + "/notes.toml"), .missing)
        XCTAssertEqual(kind(kitConfig.path + "/local.md"), .missing)
        XCTAssertEqual(e.consent.seen.count, 2)
    }

    func testConsentDeniedWritesNothing() async throws {
        let e = try env(KitRTConsent(false))
        let rt = try runtime(e)
        let ext = try source(e, version: "1.0.0")
        let (md, st) = (bytes(e.claudeMD), bytes(e.settings))
        let layout = rt.store.layout
        let r = await rt.apply(ext)
        XCTAssertEqual(e.consent.seen.count, 1)
        XCTAssertEqual(r.state?.lastRefusal, .consentDenied)
        XCTAssertEqual(r.state?.phase, .idle)
        XCTAssertEqual(kind(layout.live), .missing, "no swap")
        XCTAssertEqual(kind(layout.previous), .missing)
        XCTAssertEqual(list(layout.staged), [], "the staged copy is dropped")
        XCTAssertEqual(kind(layout.bin + "/calm-note"), .missing, "no shim")
        XCTAssertEqual(kind(layout.bin + "/" + KitStore.shimRecord), .missing)
        XCTAssertEqual(kind(layout.kitEnv), .missing, "no slug recorded")
        XCTAssertEqual(kind(layout.runner), .missing)
        XCTAssertEqual(kind(e.roots.configHome.path + "/" + Self.slug), .missing, "no seed")
        XCTAssertEqual(bytes(e.claudeMD), md)
        XCTAssertEqual(bytes(e.settings), st)
    }

    func testWiringFailureSwapsBack() async throws {
        // the second sheet (the update's) is answered yes, and while it is open settings.json turns unparsable: the
        // wiring after the swap is refused
        let settingsURL = LockedURL()
        let e = try env(KitRTConsent(true, onAsk: { n in if n == 2, let u = settingsURL.value { try? Data("{ not json".utf8).write(to: u) } }))
        settingsURL.value = e.settings
        let rt = try runtime(e)
        let layout = rt.store.layout
        let first = try await rt.apply(source(e, version: "1.0.0"))
        XCTAssertEqual(first.failures, [])
        let r = try await rt.apply(source(e, version: "2.0.0", timeout: 20))
        XCTAssertEqual(e.consent.seen.count, 2)
        XCTAssertFalse(r.failures.isEmpty, "the wiring failed")
        XCTAssertFalse(r.configRefusals.isEmpty)
        XCTAssertEqual(r.state?.live.version, "1.0.0")
        XCTAssertEqual(r.state?.phase, .idle)
        XCTAssertEqual(version(layout.live), "1.0.0", "swapped back")
        XCTAssertEqual(kind(layout.previous), .missing, "the failed new copy is gone")
        XCTAssertEqual(list(layout.staged), [])
        XCTAssertEqual(text(layout.bin + "/calm-note")?.contains(layout.live + "/tools/calm-note"), true, "the old version's shims")
    }

    /// #1408: a FIRST apply whose wiring fails ends with nothing applied (no rollback copy to swap back to).
    func testAFailedFirstApplyLeavesNothingApplied() async throws {
        let settingsURL = LockedURL()
        let e = try env(KitRTConsent(true, onAsk: { n in if n == 1, let u = settingsURL.value { try? Data("{ not json".utf8).write(to: u) } }))
        settingsURL.value = e.settings
        let rt = try runtime(e)
        let layout = rt.store.layout
        let md = bytes(e.claudeMD)
        let r = try await rt.apply(source(e, version: "1.0.0"))
        XCTAssertEqual(e.consent.seen.count, 1)
        XCTAssertTrue(r.failures.first?.hasPrefix("applyWiring") == true, "\(r.failures)")
        XCTAssertEqual(r.failures.count, 1, "nothing after the wiring failed: \(r.failures)")
        XCTAssertFalse(r.configRefusals.isEmpty)
        XCTAssertEqual(r.state?.live.version, "")
        XCTAssertTrue(r.state?.previous == nil)
        XCTAssertEqual(r.state?.phase, .idle)
        XCTAssertEqual(kind(layout.live), .missing, "the new copy is dropped")
        XCTAssertEqual(kind(layout.previous), .missing)
        XCTAssertEqual(list(layout.staged), [])
        XCTAssertEqual(kind(layout.bin + "/calm-note"), .missing, "no shim")
        XCTAssertEqual(bytes(e.claudeMD), md, "no wiring")
        // the store is back to nothing applied: a later apply runs as a first one
        try Data(Self.userSettings.utf8).write(to: e.settings)
        let again = try await rt.apply(source(e, version: "1.0.0"))
        XCTAssertEqual(again.failures, [])
        XCTAssertEqual(version(layout.live), "1.0.0")
        XCTAssertEqual(text(layout.bin + "/calm-note")?.contains(layout.live + "/tools/calm-note"), true)
    }

    /// #1408 N1, #1409: a relaunch restores the machine state, so an update after it is a real update; its failed wiring
    /// goes through the machine's own swapBack to the old copy (re-validated from live/ on disk), never leaves no live copy.
    func testAFailedUpdateAfterARelaunchKeepsTheOldCopyLive() async throws {
        let settingsURL = LockedURL()
        let e = try env(KitRTConsent(true, onAsk: { n in if n == 2, let u = settingsURL.value { try? Data("{ not json".utf8).write(to: u) } }))
        settingsURL.value = e.settings
        let before = try runtime(e)
        let layout = before.store.layout
        let first = try await before.apply(source(e, version: "1.0.0"))
        XCTAssertEqual(first.failures, [])
        let old = snapshot(layout.live)
        XCTAssertFalse(old.isEmpty)
        let shim = text(layout.bin + "/calm-note")
        let md = bytes(e.claudeMD)
        let rt = try runtime(e) // the relaunch: the state comes back from runtime.json
        XCTAssertEqual(rt.current?.live.version, "1.0.0")
        let r = try await rt.apply(source(e, version: "2.0.0", timeout: 20))
        XCTAssertEqual(e.consent.seen.count, 2)
        XCTAssertTrue(r.failures.first?.hasPrefix("applyWiring") == true, "\(r.failures)")
        XCTAssertEqual(r.failures.count, 1, "\(r.failures)")
        XCTAssertEqual(r.state?.live.version, "1.0.0", "the machine swapped back, not a first apply's drop")
        XCTAssertEqual(r.state?.previous?.version, "", "the retiring ref came back: the first apply's empty ref (#1408 N2)")
        XCTAssertEqual(r.notes, [], "the old copy validated again from live/")
        XCTAssertEqual(try runtime(e).current?.live.version, "1.0.0", "saved after the failed update")
        XCTAssertEqual(version(layout.live), "1.0.0", "the old copy is live again")
        XCTAssertEqual(snapshot(layout.live), old, "byte-identical")
        XCTAssertEqual(kind(layout.previous), .missing, "the failed new copy is gone")
        XCTAssertEqual(list(layout.staged), [])
        XCTAssertEqual(text(layout.bin + "/calm-note"), shim)
        XCTAssertEqual(bytes(e.claudeMD), md)
    }

    /// #1409: a new runtime over the same store sees live and previous, and its rollback works (the previous kit is
    /// validated again from previous/ on disk); the rollback's state is saved too.
    func testARelaunchKeepsLiveAndPreviousAndRollsBack() async throws {
        let e = try env()
        let first = try runtime(e)
        let layout = first.store.layout
        let ext = try source(e, version: "1.0.0")
        _ = await first.apply(ext)
        XCTAssertEqual(try runtime(e).current?.live.version, "1.0.0", "a first apply is saved")
        let up = try await first.apply(source(e, version: "2.0.0", timeout: 20))
        XCTAssertEqual(up.failures, [])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: layout.root + "/runtime.json")[.posixPermissions] as? Int, 0o600)
        let rt = try runtime(e) // the relaunch
        XCTAssertTrue(rt.restoreRefusal == nil)
        XCTAssertEqual(rt.current?.live.version, "2.0.0")
        XCTAssertEqual(rt.current?.previous?.version, "1.0.0")
        XCTAssertEqual(rt.current?.phase, .idle)
        let three = try source(e, version: "3.0.0")
        let updatable = await rt.updateAvailable(three)
        XCTAssertTrue(updatable)
        let back = await rt.rollback(ext)
        XCTAssertTrue(back.refused == nil, "\(String(describing: back.refused))")
        XCTAssertEqual(back.failures, [])
        XCTAssertEqual(back.notes, [])
        XCTAssertEqual(back.state?.live.version, "1.0.0")
        XCTAssertEqual(version(layout.live), "1.0.0")
        XCTAssertEqual(version(layout.previous), "2.0.0")
        XCTAssertEqual(try kitHookTimeout(e), 10)
        XCTAssertEqual(text(layout.bin + "/calm-note")?.contains(layout.live + "/tools/calm-note"), true)
        let again = try runtime(e) // a second relaunch sees the rollback
        XCTAssertEqual(again.current?.live.version, "1.0.0")
        XCTAssertEqual(again.current?.previous?.version, "2.0.0")
    }

    /// #1409: a corrupt, over-cap or wrong-schema runtime.json is refused: nothing applied, nothing run from it, nothing
    /// written, and the refusal is what rollback / remove / repair answer.
    func testABadStateFileIsRefused() async throws {
        let e = try env()
        let first = try runtime(e)
        let layout = first.store.layout
        let ext = try source(e, version: "1.0.0")
        _ = await first.apply(ext)
        let path = layout.root + "/runtime.json"
        let good = try XCTUnwrap(bytes(URL(fileURLWithPath: path)))
        let goodText = String(decoding: good, as: UTF8.self)
        XCTAssertTrue(goodText.contains("\"schema\":1"), goodText)
        let bad: [(String, Data)] = [
            ("corrupt", Data("{ not json".utf8)),
            ("over the cap", Data(good) + Data(repeating: 0x20, count: KitStore.runtimeStateCap + 1 - good.count)),
            ("wrong schema", Data(goodText.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":2").utf8))]
        for (label, d) in bad {
            try d.write(to: URL(fileURLWithPath: path))
            let (md, st, live, bin, seen) = (bytes(e.claudeMD), bytes(e.settings), snapshot(layout.live), snapshot(layout.bin), e.consent.seen.count)
            let rt = try runtime(e)
            XCTAssertTrue(rt.current == nil, label)
            XCTAssertTrue(rt.restoreRefusal?.hasPrefix("kit state") == true, "\(label): \(String(describing: rt.restoreRefusal))")
            let rb = await rt.rollback(ext)
            XCTAssertEqual(rb.refused, rt.restoreRefusal, label)
            let rm = await rt.remove(ext)
            XCTAssertEqual(rm.refused, rt.restoreRefusal, label)
            let rp = await rt.repair(ext)
            XCTAssertEqual(rp.refused, rt.restoreRefusal, label)
            XCTAssertEqual(rt.status(ext)?.live, nil, label)
            XCTAssertEqual(e.consent.seen.count, seen, label)
            XCTAssertEqual(bytes(e.claudeMD), md, label)
            XCTAssertEqual(bytes(e.settings), st, label)
            XCTAssertEqual(snapshot(layout.live), live, label)
            XCTAssertEqual(snapshot(layout.bin), bin, label)
            XCTAssertEqual(bytes(URL(fileURLWithPath: path)).map { Data($0) }, d, "\(label): the file is left as found")
        }
    }

    /// #1409: a state naming a live copy that is gone on disk is refused the same way.
    func testAStateWhoseLiveDirIsGoneIsRefused() async throws {
        let e = try env()
        let first = try runtime(e)
        let layout = first.store.layout
        let ext = try source(e, version: "1.0.0")
        _ = await first.apply(ext)
        try FileManager.default.moveItem(atPath: layout.live, toPath: e.root.appendingPathComponent("moved-live").path)
        let (md, st, seen) = (bytes(e.claudeMD), bytes(e.settings), e.consent.seen.count)
        let rt = try runtime(e)
        XCTAssertTrue(rt.current == nil)
        XCTAssertTrue(rt.restoreRefusal?.contains("\(layout.live) is gone") == true, "\(String(describing: rt.restoreRefusal))")
        let rb = await rt.rollback(ext)
        XCTAssertEqual(rb.refused, rt.restoreRefusal)
        let rp = await rt.repair(ext)
        XCTAssertEqual(rp.refused, rt.restoreRefusal)
        XCTAssertEqual(e.consent.seen.count, seen)
        XCTAssertEqual(bytes(e.claudeMD), md)
        XCTAssertEqual(bytes(e.settings), st)
        XCTAssertEqual(kind(layout.live), .missing)
    }

    /// QA R1408-i1: a failed first apply forgets the slug it recorded, so a kit renamed before its retry applies under the
    /// new name; the runner script stays (the next apply rewrites it).
    func testAFailedFirstApplyForgetsItsSlug() async throws {
        let settingsURL = LockedURL()
        let e = try env(KitRTConsent(true, onAsk: { n in if n == 1, let u = settingsURL.value { try? Data("{ not json".utf8).write(to: u) } }))
        settingsURL.value = e.settings
        let rt = try runtime(e)
        let layout = rt.store.layout
        let r = try await rt.apply(source(e, version: "1.0.0"))
        XCTAssertTrue(r.failures.first?.hasPrefix("applyWiring") == true, "\(r.failures)")
        XCTAssertEqual(r.failures.count, 1, "\(r.failures)")
        XCTAssertTrue(rt.store.recordedSlug() == nil, "the attempt's slug is not kept")
        XCTAssertEqual(kind(layout.kitEnv), .missing)
        XCTAssertNotEqual(kind(layout.runner), .missing, "the runner script stays")
        try Data(Self.userSettings.utf8).write(to: e.settings)
        let again = try await rt.apply(source(e, name: "calm-agent-two", version: "1.0.0"))
        XCTAssertEqual(again.failures, [])
        XCTAssertTrue(again.state?.lastRefusal == nil, "\(String(describing: again.state?.lastRefusal))")
        XCTAssertEqual(version(layout.live), "1.0.0")
        XCTAssertEqual(text(layout.kitEnv)?.hasPrefix("KIT_SLUG='calm-agent-two'\n"), true)
        XCTAssertEqual(try runtime(e).current?.live.slug, "calm-agent-two")
    }

    /// #1408 N5, #1409: a crash-leftover previous/ with no state is never promoted to live by a failed first apply: the new
    /// copy is dropped and the leftover stays where it was, untouched.
    func testAFailedFirstApplyNeverPromotesALeftoverPrevious() async throws {
        let settingsURL = LockedURL()
        let e = try env(KitRTConsent(true, onAsk: { n in if n == 1, let u = settingsURL.value { try? Data("{ not json".utf8).write(to: u) } }))
        let rt = try runtime(e)
        let layout = rt.store.layout
        try rt.store.ensureLayout()
        try FileManager.default.createDirectory(atPath: layout.previous, withIntermediateDirectories: false)
        try Data("leftover\n".utf8).write(to: URL(fileURLWithPath: layout.previous + "/marker"))
        settingsURL.value = e.settings
        let r = try await rt.apply(source(e, version: "1.0.0"))
        XCTAssertTrue(r.failures.first?.hasPrefix("applyWiring") == true, "\(r.failures)")
        XCTAssertEqual(r.state?.live.version, "")
        XCTAssertEqual(kind(layout.live), .missing, "nothing promoted to live")
        XCTAssertEqual(text(layout.previous + "/marker"), "leftover\n")
    }

    /// #1408 N2: a rollback right after a good first apply has nothing to roll back to and changes nothing.
    func testARollbackAfterAFirstApplyChangesNothing() async throws {
        let e = try env()
        let rt = try runtime(e)
        let layout = rt.store.layout
        let ext = try source(e, version: "1.0.0")
        let first = await rt.apply(ext)
        XCTAssertEqual(first.failures, [])
        let (live, md, st, shim) = (snapshot(layout.live), bytes(e.claudeMD), bytes(e.settings), text(layout.bin + "/calm-note"))
        let r = await rt.rollback(ext)
        XCTAssertEqual(r.refused, "nothing to roll back to")
        XCTAssertEqual(r.failures, [])
        XCTAssertEqual(r.state?.live.version, "1.0.0")
        XCTAssertEqual(e.consent.seen.count, 1, "no sheet")
        XCTAssertEqual(snapshot(layout.live), live)
        XCTAssertEqual(kind(layout.previous), .missing)
        XCTAssertEqual(text(layout.bin + "/calm-note"), shim)
        XCTAssertEqual(bytes(e.claudeMD), md)
        XCTAssertEqual(bytes(e.settings), st)
    }

    /// L4: a file changes under the update's sheet, so the wiring's change set is not the one approved: KitApprovedConsent
    /// falls back to the real consent, which is asked again, and that second answer for the update (a no) decides.
    func testTheWiringAsksAgainWhenTheChangeSetShifts() async throws {
        let settingsURL = LockedURL()
        let e = try env(KitRTConsent(true, answers: [true, true, false], onAsk: { n in
            guard n == 2, let u = settingsURL.value, let d = try? Data(contentsOf: u),
                  var doc = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
            doc["model"] = "example-model" // the person's own edit while the sheet is open
            if let out = try? JSONSerialization.data(withJSONObject: doc) { try? out.write(to: u) }
        }))
        settingsURL.value = e.settings
        let rt = try runtime(e)
        let layout = rt.store.layout
        let first = try await rt.apply(source(e, version: "1.0.0"))
        XCTAssertEqual(first.failures, [])
        XCTAssertEqual(e.consent.seen.count, 1, "an unchanged sheet answers the wiring itself")
        let r = try await rt.apply(source(e, version: "2.0.0", timeout: 20))
        XCTAssertEqual(e.consent.seen.count, 3, "asked at askConsent and again at the wiring")
        let shown = e.consent.seen.dropFirst()
        XCTAssertTrue(shown.first?.identity != nil && shown.first?.identity != shown.last?.identity, "the re-ask shows the shifted set")
        XCTAssertFalse(r.failures.isEmpty, "the re-ask's no fails the wiring")
        XCTAssertEqual(r.state?.live.version, "1.0.0")
        XCTAssertEqual(version(layout.live), "1.0.0", "swapped back")
        XCTAssertEqual(try kitHookTimeout(e), 10, "the update's wiring never landed")
        XCTAssertEqual(try settings(e)["model"] as? String, "example-model")
    }

    func testOffPieceSurvivesUpdate() async throws {
        let e = try env()
        let rt = try runtime(e)
        try rt.setOff(["hud"])
        let v1 = try source(e, version: "1.0.0"), v2 = try source(e, version: "2.0.0", timeout: 20)
        let first = await rt.apply(v1)
        XCTAssertEqual(first.failures, [])
        XCTAssertEqual(try statusCommand(e), "my-own-status")
        XCTAssertEqual(rt.status(v1)?.off, ["hud"])
        XCTAssertEqual(rt.status(v1)?.pieces.contains { $0.id == "hud" }, false)
        // reported, never applied
        let available = await rt.updateAvailable(v2)
        XCTAssertTrue(available)
        let same = await rt.updateAvailable(v1)
        XCTAssertFalse(same)
        XCTAssertEqual(rt.current?.live.version, "1.0.0")
        XCTAssertEqual(version(rt.store.layout.live), "1.0.0")
        XCTAssertEqual(e.consent.seen.count, 1)
        let r = await rt.apply(v2)
        XCTAssertEqual(r.failures, [])
        XCTAssertEqual(r.state?.live.version, "2.0.0")
        XCTAssertEqual(try kitHookTimeout(e), 20)
        XCTAssertEqual(try statusCommand(e), "my-own-status", "the off piece stays off")
        XCTAssertEqual(rt.status(v2)?.off, ["hud"])
        XCTAssertEqual(rt.status(v2)?.pieces.contains { $0.id == "hud" }, false)
    }

    func testSeedNeverOverwritten() async throws {
        let e = try env()
        let rt = try runtime(e)
        let first = try await rt.apply(source(e, version: "1.0.0"))
        XCTAssertEqual(first.failures, [])
        let notes = e.roots.configHome.appendingPathComponent(Self.slug + "/notes.toml")
        XCTAssertEqual(text(notes.path), "# your notes\n")
        try Data("# mine\n".utf8).write(to: notes)
        let r = try await rt.apply(source(e, version: "2.0.0", seed: "# v2 notes\n"))
        XCTAssertEqual(r.failures, [])
        XCTAssertEqual(r.state?.live.version, "2.0.0")
        XCTAssertEqual(text(notes.path), "# mine\n")
    }

    func testRenamedKitUpdateRefused() async throws {
        let e = try env()
        let rt = try runtime(e)
        let layout = rt.store.layout
        let first = try await rt.apply(source(e, version: "1.0.0"))
        XCTAssertEqual(first.failures, [])
        let r = try await rt.apply(source(e, name: "calm-agent-two", version: "2.0.0"))
        XCTAssertEqual(r.state?.lastRefusal, .slugChanged)
        XCTAssertEqual(r.state?.live.version, "1.0.0")
        XCTAssertEqual(version(layout.live), "1.0.0")
        XCTAssertEqual(list(layout.staged), [])
        XCTAssertEqual(e.consent.seen.count, 1)
        XCTAssertEqual(text(layout.kitEnv)?.hasPrefix("KIT_SLUG='calm-agent'\n"), true)
        XCTAssertEqual(kind(e.roots.configHome.path + "/calm-agent-two"), .missing)
    }

    func testTwoKitsStatusLineConflict() async throws {
        let e = try env()
        let a = try runtime(e), b = try runtime(e, "com.example.kit2")
        let extA = try source(e, version: "1.0.0")
        let extB = try source(e, id: "com.example.kit2", name: "calm-agent-b", version: "1.0.0")
        let ra = await a.apply(extA)
        XCTAssertEqual(ra.failures, [])
        let aStatus = try statusCommand(e)
        XCTAssertTrue(aStatus?.contains("'com.example.kit' 'hud'") == true, "\(String(describing: aStatus))")
        let rb = await b.apply(extB)
        XCTAssertTrue(rb.configRefusals.contains { $0.pieceID == "hud" && $0.reason == .conflict(owner: Self.ext) }, "\(rb.configRefusals)")
        XCTAssertEqual(rb.state?.lastRefusal, .consentDenied)
        XCTAssertEqual(e.consent.seen.count, 1, "a refused plan is never shown")
        XCTAssertEqual(kind(b.store.layout.live), .missing)
        XCTAssertEqual(try statusCommand(e), aStatus)
        // the person switches B's status line off: B applies, A keeps the slot
        try b.setOff(["hud"])
        let again = await b.apply(extB)
        XCTAssertEqual(again.failures, [])
        XCTAssertEqual(again.state?.live.version, "1.0.0")
        XCTAssertEqual(try statusCommand(e), aStatus)
        XCTAssertEqual(a.status(extA)?.pieces.first { $0.id == "hud" }?.state, .applied)
        XCTAssertEqual(b.status(extB)?.pieces.contains { $0.id == "hud" }, false)
        XCTAssertEqual(b.status(extB)?.off, ["hud"])
    }

    func testOwnerMatchesLoadedExtension() async throws {
        let e = try env()
        let rt = try runtime(e)
        let ext = try source(e, version: "1.0.0")
        let r = await rt.apply(ext)
        XCTAssertEqual(r.failures, [])
        XCTAssertEqual(Set(try records(e).map(\.owner)), [ext.id])
        let st = try XCTUnwrap(rt.status(ext))
        XCTAssertFalse(st.pieces.isEmpty)
        XCTAssertEqual(Set(st.pieces.map(\.state)), [.applied])
        // another extension's id never runs on this kit's store
        let other = try source(e, id: "com.example.other", version: "1.0.0")
        let refused = await rt.apply(other)
        XCTAssertEqual(refused.refused, "not this runtime's kit")
        XCTAssertEqual(e.consent.seen.count, 1)
        XCTAssertEqual(kind(e.roots.configHome.path + "/prosper/kits/com.example.other"), .missing)
    }

    func testRollbackTwice() async throws {
        let e = try env()
        let rt = try runtime(e)
        let layout = rt.store.layout
        let ext = try source(e, version: "1.0.0")
        _ = await rt.apply(ext)
        let up = try await rt.apply(source(e, version: "2.0.0", timeout: 20))
        XCTAssertEqual(up.failures, [])
        XCTAssertEqual(try kitHookTimeout(e), 20)
        XCTAssertEqual(e.consent.seen.count, 2)
        let back = await rt.rollback(ext)
        XCTAssertEqual(back.failures, [])
        XCTAssertEqual(e.consent.seen.count, 3, "a rollback has no askConsent: its wiring asks (R1402-s1)")
        XCTAssertEqual(back.state?.live.version, "1.0.0")
        XCTAssertEqual(back.state?.previous?.version, "2.0.0")
        XCTAssertEqual(version(layout.live), "1.0.0")
        XCTAssertEqual(version(layout.previous), "2.0.0")
        XCTAssertEqual(try kitHookTimeout(e), 10)
        let forth = await rt.rollback(ext)
        XCTAssertEqual(forth.failures, [])
        XCTAssertEqual(e.consent.seen.count, 4)
        XCTAssertEqual(forth.state?.live.version, "2.0.0")
        XCTAssertEqual(version(layout.live), "2.0.0")
        XCTAssertEqual(version(layout.previous), "1.0.0")
        XCTAssertEqual(try kitHookTimeout(e), 20)
    }

    /// R1402-s1: a rollback answered no at its one sheet leaves the copies, the shims and the person's files as they were.
    func testARollbackAnsweredNoChangesNothing() async throws {
        let e = try env(KitRTConsent(true, answers: [true, true, false]))
        let rt = try runtime(e)
        let layout = rt.store.layout
        let ext = try source(e, version: "1.0.0")
        _ = await rt.apply(ext)
        let up = try await rt.apply(source(e, version: "2.0.0", timeout: 20))
        XCTAssertEqual(up.failures, [])
        let (md, st, shim) = (bytes(e.claudeMD), bytes(e.settings), text(layout.bin + "/calm-note"))
        let no = await rt.rollback(ext)
        XCTAssertEqual(e.consent.seen.count, 3, "the rollback asked once")
        XCTAssertFalse(no.failures.isEmpty, "the no fails the rollback's wiring")
        XCTAssertEqual(no.state?.live.version, "2.0.0")
        XCTAssertEqual(no.state?.previous?.version, "1.0.0")
        XCTAssertEqual(version(layout.live), "2.0.0")
        XCTAssertEqual(version(layout.previous), "1.0.0")
        XCTAssertEqual(text(layout.bin + "/calm-note"), shim)
        XCTAssertEqual(bytes(e.claudeMD), md)
        XCTAssertEqual(bytes(e.settings), st)
    }

    func testNoEnvKeyEverPlanned() async throws {
        let e = try env()
        let rt = try runtime(e)
        let r = try await rt.apply(source(e, version: "1.0.0"))
        XCTAssertEqual(r.failures, [])
        // every settings.json path the kit wrote, against a literal list
        let paths = Set(try records(e).compactMap(\.piece.path))
        XCTAssertEqual(paths, [["hooks", "PreToolUse"], ["statusLine"], ["permissions", "allow"], ["permissions", "deny"]])
        let doc = try settings(e)
        XCTAssertEqual(Set(doc.keys), ["env", "hooks", "permissions", "statusLine"])
        XCTAssertEqual(doc["env"] as? [String: String], ["EXAMPLE_TOKEN": "dummy-value"])
        XCTAssertEqual(kind(e.roots.configHome.path + "/" + Self.slug + "/.settings.env"), .missing)
    }
}

/// A URL set after the consent fake is built (the fake needs the env's path, the env needs the fake).
final class LockedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: URL?
    var value: URL? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
