import Darwin
import XCTest
@testable import ProsperApp

/// #2008: adding a Codex (ChatGPT) account. A fake runner stands for `codex login --device-auth` (no real codex, no
/// ~/.codex, no OpenAI host), memory secrets for the Keychain, a temp-dir store for state.json.
final class CodexLoginTests: XCTestCase {
    static let access = "fixture-access-token-2008"
    static let refresh = "fixture-refresh-token-2008"
    static let idToken = "fixture-id-token-2008"
    static let account = "acct-fixture-2008"
    /// Codex's own auth.json shape: tokens nested under "tokens", last_refresh at the top.
    static let authJSON = Data("""
    {"OPENAI_API_KEY": null, "tokens": {"id_token": "\(idToken)", "access_token": "\(access)", \
    "refresh_token": "\(refresh)", "account_id": "\(account)"}, "last_refresh": "2026-11-20T10:00:00.123456Z"}
    """.utf8)

    struct Rig: Sendable {
        let store: CCPoolStore
        let secrets: CCPoolMemorySecrets
        let log: CCPoolCapturingLogger
        let root: URL
    }

    func rig() -> Rig {
        let log = CCPoolCapturingLogger()
        let dir = tempDir()
        let store = CCPoolStore(directory: dir.appendingPathComponent("ccpool"), logger: log)
        return Rig(store: store, secrets: CCPoolMemorySecrets(), log: log,
                   root: store.directory.appendingPathComponent("codex-login", isDirectory: true))
    }

    /// What the fake saw while it ran.
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _argv: [String] = [], _home: String?, _mode: mode_t = 0
        func record(_ argv: [String], _ home: String?, _ mode: mode_t) { lock.withLock { _argv = argv; _home = home; _mode = mode } }
        var argv: [String] { lock.withLock { _argv } }
        var home: String? { lock.withLock { _home } }
        var mode: mode_t { lock.withLock { _mode } }
    }

    /// A runner that records its CODEX_HOME's mode, optionally writes `auth` there, prints a device-code text with ANSI
    /// colour, and exits with `status`.
    static func fake(_ seen: Seen, auth: Data?, status: Int32?) -> CodexLogin.Runner {
        { argv, env, started, output in
            let home = env["CODEX_HOME"]
            var st = stat()
            let mode: mode_t = home.map { lstat($0, &st) == 0 ? st.st_mode & 0o777 : 0 } ?? 0
            seen.record(argv, home, mode)
            guard let status else { return nil }
            started {}
            output("\u{1B}[1mOpen https://auth.example.test/codex/device\u{1B}[0m\r\nCode: ABCD-1234\n")
            if let auth, let home { try? auth.write(to: URL(fileURLWithPath: home).appendingPathComponent("auth.json")) }
            return status
        }
    }

    static func signIn(_ r: Rig, runner: @escaping CodexLogin.Runner, label: String = "codex-1",
                handle: CodexLogin.Handle = CodexLogin.Handle()) async -> CodexLogin.Outcome {
        await CodexLogin.signIn(label: label, command: ["codex"], scratchRoot: r.root, store: r.store, secrets: r.secrets,
                                logger: r.log, runner: runner, handle: handle, output: { _ in })
    }

    func scratchLeft(_ r: Rig) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: r.root.path)) ?? []
    }

    func assertNothingAdded(_ r: Rig, _ outcome: CodexLogin.Outcome, file: StaticString = #filePath, line: UInt = #line) {
        if case .added = outcome { XCTFail("added", file: file, line: line) }
        XCTAssertEqual(r.secrets.count, 0, "no Keychain item", file: file, line: line)
        XCTAssertTrue(r.store.snapshot.accounts.isEmpty, "no account", file: file, line: line)
        XCTAssertEqual(scratchLeft(r), [], "no scratch folder", file: file, line: line)
    }

    // MARK: Device login

    func testDeviceLoginStoresTheFlatItemAsACodexAccount() async throws {
        let r = rig(), seen = Seen()
        let outcome = await Self.signIn(r, runner: Self.fake(seen, auth: Self.authJSON, status: 0))
        XCTAssertEqual(outcome, .added("codex-1"))
        XCTAssertEqual(seen.argv, ["codex", "-c", #"cli_auth_credentials_store="file""#, "login", "--device-auth"],
                       "#2039: the store override is one word, before `login`")
        let home = try XCTUnwrap(seen.home)
        XCTAssertTrue(home.hasPrefix(r.root.path + "/"), "CODEX_HOME under the pool's own folder: \(home)")
        XCTAssertFalse(home.contains("/.codex"))
        XCTAssertEqual(seen.mode, 0o700, "the scratch CODEX_HOME is 0700 while the login runs")
        XCTAssertEqual(scratchLeft(r), [], "the scratch folder is gone afterwards")
        let acct = try XCTUnwrap(r.store.snapshot.accounts["codex-1"])
        XCTAssertEqual(acct.harness, CCPoolCodexHarness.id)
        XCTAssertEqual(acct.kind, CCPoolCodexHarness.chatgptKind)
        let item = try XCTUnwrap(try r.secrets.token(id: acct.id))
        XCTAssertFalse(item.contains("\"tokens\""), "flat, not Codex's nested auth.json")
        let cred = try XCTUnwrap(CodexCredential.decode(item))
        XCTAssertEqual(cred.accessToken, Self.access)
        XCTAssertEqual(cred.refreshToken, Self.refresh)
        XCTAssertEqual(cred.accountID, Self.account)
        XCTAssertTrue(r.store.hasCodexAccounts)
    }

    func testDefaultLabelIsTheNextFreeCodexN() {
        XCTAssertEqual(CodexLogin.defaultLabel(taken: []), "codex-1")
        XCTAssertEqual(CodexLogin.defaultLabel(taken: ["codex-1", "codex-3", "work"]), "codex-2")
    }

    // MARK: Failure paths: no item, no account, no scratch folder

    func testNonZeroExitAddsNothing() async {
        let r = rig()
        let outcome = await Self.signIn(r, runner: Self.fake(Seen(), auth: Self.authJSON, status: 1))
        XCTAssertEqual(outcome, .failed("Codex login ended with status 1; nothing added."))
        assertNothingAdded(r, outcome)
    }

    func testNoAuthJSONAddsNothing() async {
        let r = rig()
        let outcome = await Self.signIn(r, runner: Self.fake(Seen(), auth: nil, status: 0))
        XCTAssertEqual(outcome, .failed("Codex wrote no auth.json; nothing added."))
        assertNothingAdded(r, outcome)
    }

    func testAuthJSONWithoutTokensAddsNothing() async {
        let r = rig()
        let outcome = await Self.signIn(r, runner: Self.fake(Seen(), auth: Data(#"{"OPENAI_API_KEY": "sk-example"}"#.utf8), status: 0))
        XCTAssertEqual(outcome, .failed("That auth.json holds no ChatGPT login (no tokens); nothing added."))
        assertNothingAdded(r, outcome)
    }

    func testChildThatCannotStartAddsNothing() async {
        let r = rig()
        let outcome = await Self.signIn(r, runner: Self.fake(Seen(), auth: nil, status: nil))
        XCTAssertEqual(outcome, .failed("Codex could not be started; nothing added."))
        assertNothingAdded(r, outcome)
    }

    func testStoreFailureAddsNothing() async {
        let r = rig()
        r.secrets.refuseStore = true
        let outcome = await Self.signIn(r, runner: Self.fake(Seen(), auth: Self.authJSON, status: 0))
        guard case .failed(let why) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(why.hasPrefix("Agent Account Pool:"), why)
        assertNothingAdded(r, outcome)
    }

    /// Memory secrets whose read returns another text: the read-back check must undo the item.
    final class SkewedSecrets: CCPoolSecrets, @unchecked Sendable {
        let inner = CCPoolMemorySecrets()
        func store(token: String, id: String, label: String) throws { try inner.store(token: token, id: id, label: label) }
        func token(id: String) throws -> String? { try inner.token(id: id).map { $0 + " " } }
        func remove(id: String) throws { try inner.remove(id: id) }
        func relabel(id: String, label: String) throws { try inner.relabel(id: id, label: label) }
    }

    func testReadBackMismatchAddsNothing() async {
        let r = rig(), skewed = SkewedSecrets()
        let outcome = await CodexLogin.signIn(label: "codex-1", command: ["codex"], scratchRoot: r.root, store: r.store,
                                              secrets: skewed, logger: r.log,
                                              runner: Self.fake(Seen(), auth: Self.authJSON, status: 0),
                                              handle: CodexLogin.Handle(), output: { _ in })
        XCTAssertEqual(outcome, .failed(CCPoolStoreError.readBackMismatch.description))
        XCTAssertEqual(skewed.inner.count, 0, "the item written is removed again")
        XCTAssertTrue(r.store.snapshot.accounts.isEmpty)
        XCTAssertEqual(scratchLeft(r), [])
    }

    func testBadOrTakenLabelRunsNoChild() async throws {
        let r = rig(), seen = Seen()
        try r.store.addAccount(label: "work", token: "tok-work", secrets: r.secrets)
        let outcome = await Self.signIn(r, runner: Self.fake(seen, auth: Self.authJSON, status: 0), label: "work")
        XCTAssertEqual(outcome, .failed(CCPoolStoreError.duplicateLabel.description))
        XCTAssertEqual(seen.argv, [], "no child for a taken label")
        XCTAssertEqual(scratchLeft(r), [])
    }

    // MARK: Cancel

    /// A child that runs until its stop is called, then exits with SIGTERM's status.
    final class Hanging: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<Int32?, Never>?
        private var _stops = 0, _running = false
        var stops: Int { lock.withLock { _stops } }
        var running: Bool { lock.withLock { _running } }
        var runner: CodexLogin.Runner {
            { [self] _, _, started, _ in
                await withCheckedContinuation { c in
                    lock.withLock { cont = c; _running = true }
                    started { [self] in
                        let c = lock.withLock { () -> CheckedContinuation<Int32?, Never>? in
                            _stops += 1
                            defer { cont = nil }
                            return cont
                        }
                        c?.resume(returning: 143)
                    }
                }
            }
        }
    }

    func testCancelStopsTheChildAndCleansUp() async throws {
        let r = rig(), child = Hanging(), handle = CodexLogin.Handle()
        let task = Task { await Self.signIn(r, runner: child.runner, handle: handle) }
        let deadline = Date().addingTimeInterval(10)
        while !child.running, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(child.running)
        XCTAssertEqual(scratchLeft(r).count, 1, "the scratch folder exists while the login runs")
        handle.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(child.stops, 1, "the child's own stop was called once")
        assertNothingAdded(r, outcome)
    }

    // MARK: Import (through the pane model)

    @MainActor
    func testImportWarnsFirstThenStoresTheFlatItemAndDeletesOnlyAuthJSON() async throws {
        let p = try ccpoolPaneRig()
        let folder = tempDir().appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.authJSON.write(to: folder.appendingPathComponent("auth.json"))
        try Data("model = \"example\"\n".utf8).write(to: folder.appendingPathComponent("config.toml"))
        var picks = 0
        p.model.pickCodexFolder = { done in picks += 1; done(folder) }

        p.model.requestCodexImport()
        XCTAssertTrue(p.model.codexImportWarning, "R1 is shown first")
        XCTAssertEqual(picks, 0, "nothing picked or read before the warning's Continue")
        XCTAssertTrue(p.store.snapshot.accounts.isEmpty)
        XCTAssertTrue(p.model.importCodex(from: folder) == nil, "no import without the warning's Continue")

        p.model.continueCodexImport()
        XCTAssertEqual(picks, 1)
        XCTAssertFalse(p.model.codexImportWarning)
        let deadline = Date().addingTimeInterval(10)
        while p.model.busy, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let acct = try XCTUnwrap(p.store.snapshot.accounts["codex-1"], "the default label")
        XCTAssertEqual(acct.harness, CCPoolCodexHarness.id)
        XCTAssertEqual(acct.kind, CCPoolCodexHarness.chatgptKind)
        let item = try XCTUnwrap(try p.secrets.token(id: acct.id))
        XCTAssertFalse(item.contains("\"tokens\""))
        XCTAssertEqual(CodexCredential.decode(item)?.accessToken, Self.access)
        XCTAssertEqual(p.model.codexImportedFolder, folder, "the delete is offered")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("auth.json").path),
                      "nothing deleted before the click")

        p.model.deleteImportedAuth()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("auth.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.toml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(p.model.codexImportedFolder)
    }

    func testDeleteAuthNeverRemovesAFolderNamedAuthJSON() throws {
        let folder = tempDir()
        let inner = folder.appendingPathComponent("auth.json", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: inner.appendingPathComponent("keep"))
        XCTAssertFalse(CodexLogin.deleteAuth(in: folder))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inner.appendingPathComponent("keep").path))
    }

    @MainActor
    func testModelDeviceLoginUsesTheDefaultLabelAndShowsTheOutput() async throws {
        let p = try ccpoolPaneRig()
        let seen = Seen()
        p.model.codexRunner = Self.fake(seen, auth: Self.authJSON, status: 0)
        p.model.codexCommand = { ["codex"] }
        let task = try XCTUnwrap(p.model.addCodexAccount())
        await task.value
        XCTAssertNotNil(p.store.snapshot.accounts["codex-1"])
        XCTAssertEqual(p.model.notice, "Added codex-1.")
        XCTAssertFalse(p.model.busy)
        XCTAssertEqual(p.model.codexDefaultLabel, "codex-2")
    }

    // MARK: Output text

    func testOutputLinesDropANSIAndControlsAndFindTheLink() {
        let lines = CodexLogin.Lines()
        XCTAssertEqual(lines.feed("\u{1B}[94mhttps://auth.example.test/codex/device\u{1B}[0m\r\n"),
                       ["https://auth.example.test/codex/device"])
        XCTAssertEqual(lines.feed("Enter \u{1B}]8;;x\u{07}code\u{07}: AB"), ["https://auth.example.test/codex/device", "Enter code: AB"])
        XCTAssertEqual(lines.feed("CD-12\n"), ["https://auth.example.test/codex/device", "Enter code: ABCD-12"])
        XCTAssertEqual(CodexLogin.link(in: "Open https://auth.example.test/codex/device."),
                       URL(string: "https://auth.example.test/codex/device"))
        XCTAssertNil(CodexLogin.link(in: "Open http://auth.example.test/x"))
        let many = CodexLogin.Lines()
        var last: [String] = []
        for i in 0..<100 { last = many.feed("line \(i)\n") }
        XCTAssertEqual(last.count, CodexLogin.maxLines)
        XCTAssertEqual(last.last, "line 99")
    }

    // MARK: No token in any log line

    func testNoTokenInAnyLogLine() async throws {
        let r = rig()
        _ = await Self.signIn(r, runner: Self.fake(Seen(), auth: Self.authJSON, status: 0))
        _ = await Self.signIn(r, runner: Self.fake(Seen(), auth: Self.authJSON, status: 0), label: "codex-2")
        _ = await Self.signIn(r, runner: Self.fake(Seen(), auth: Self.authJSON, status: 3), label: "codex-3")
        r.secrets.refuseStore = true
        _ = await Self.signIn(r, runner: Self.fake(Seen(), auth: Self.authJSON, status: 0), label: "codex-4")
        XCTAssertFalse(r.log.lines.isEmpty)
        for secret in [Self.access, Self.refresh, Self.idToken, Self.account, "fixture-"] {
            XCTAssertFalse(r.log.lines.contains { $0.contains(secret) }, secret)
        }
    }

    // MARK: Downgrade guard (QA #2004 n1)

    /// The pre-#2004 decoder of state.json's top level (09747714^ CCPoolCore.swift: `current` is a String).
    struct PreHarnessState: Decodable {
        var current: String?
        var order: [String]
        private enum Keys: String, CodingKey { case current, order }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            current = try c.decodeIfPresent(String.self, forKey: .current)
            order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        }
    }

    func testOlderDecoderRefusesAStoreWithACodexAccount() async throws {
        let r = rig()
        try r.store.addAccount(label: "work", token: "tok-work", secrets: r.secrets)
        let claudeOnly = try Data(contentsOf: r.store.stateURL)
        XCTAssertNoThrow(try JSONDecoder().decode(PreHarnessState.self, from: claudeOnly), "a Claude-only store stays readable")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: claudeOnly) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["order", "accounts"], "the Claude-only file keeps its shape (no current map)")
        XCTAssertFalse(String(decoding: claudeOnly, as: UTF8.self).contains("harness"))
        r.store.mutate { $0.current = "work" }
        let withCurrent = try Data(contentsOf: r.store.stateURL)
        XCTAssertEqual(try JSONDecoder().decode(PreHarnessState.self, from: withCurrent).current, "work")

        _ = await Self.signIn(r, runner: Self.fake(Seen(), auth: Self.authJSON, status: 0))
        let mixed = try Data(contentsOf: r.store.stateURL)
        XCTAssertThrowsError(try JSONDecoder().decode(PreHarnessState.self, from: mixed),
                             "an older build cannot decode it, so its store sets the file aside")
        let back = try JSONDecoder().decode(CCPoolState.self, from: mixed)
        XCTAssertEqual(back.current, "work", "this build reads the map back")
        XCTAssertEqual(back.accounts["codex-1"]?.harness, CCPoolCodexHarness.id)
        let reopened = CCPoolStore(directory: r.store.directory, logger: r.log)
        XCTAssertFalse(reopened.unreadable)
        XCTAssertEqual(reopened.snapshot, r.store.snapshot)
    }

    func testCurrentOfAnotherTypeStillFailsTheDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(CCPoolState.self, from: Data(#"{"current": 3, "accounts": {}}"#.utf8)))
        XCTAssertEqual(try JSONDecoder().decode(CCPoolState.self, from: Data(#"{"current": null}"#.utf8)).currents, [:])
    }

    // MARK: #2039 sweep and quit

    func testStartSweepRemovesStaleChildrenAndNeverFollowsALink() throws {
        let r = rig(), fm = FileManager.default
        let outside = tempDir().appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        let stale = r.root.appendingPathComponent("stale-1", isDirectory: true)
        try fm.createDirectory(at: stale, withIntermediateDirectories: true)
        try Self.authJSON.write(to: stale.appendingPathComponent("auth.json"))
        try Data("x".utf8).write(to: r.root.appendingPathComponent("loose-file"))
        try fm.createSymbolicLink(at: r.root.appendingPathComponent("link"), withDestinationURL: outside)
        let sibling = r.store.directory.appendingPathComponent("sibling.txt")
        try Data("s".utf8).write(to: sibling)

        CodexLogin.sweep(root: r.root)

        XCTAssertEqual(scratchLeft(r), [], "every child of codex-login/ is gone, with what it held")
        XCTAssertTrue(fm.fileExists(atPath: r.root.path), "the folder itself stays")
        XCTAssertTrue(fm.fileExists(atPath: outside.appendingPathComponent("keep.txt").path), "the link's target stays")
        XCTAssertTrue(fm.fileExists(atPath: sibling.path), "siblings of codex-login/ stay")
    }

    func testSweepLeavesARootThatIsALinkAlone() throws {
        let fm = FileManager.default
        let target = tempDir().appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("k".utf8).write(to: target.appendingPathComponent("k.txt"))
        let root = tempDir().appendingPathComponent("codex-login")
        try fm.createSymbolicLink(at: root, withDestinationURL: target)
        CodexLogin.sweep(root: root)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("k.txt").path))
    }

    func testBeforeLoginSweepRemovesStaleScratchButNotTheLiveOne() async throws {
        let r = rig(), child = Hanging(), handle = CodexLogin.Handle()
        let stale = r.root.appendingPathComponent("stale", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let task = Task { await Self.signIn(r, runner: child.runner, handle: handle) }
        let deadline = Date().addingTimeInterval(10)
        while !child.running, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(child.running)
        XCTAssertEqual(scratchLeft(r).count, 1, "the stale one went before the login, the live one is there")
        XCTAssertFalse(scratchLeft(r).contains("stale"))
        CodexLogin.sweep(root: r.root)
        XCTAssertEqual(scratchLeft(r).count, 1, "a sweep while a login is live keeps its scratch")
        handle.cancel()
        _ = await task.value
        XCTAssertEqual(scratchLeft(r), [])
    }

    func testASweepWhileALoginHoldsTheSlotRemovesNothingNew() async throws {
        let r = rig(), child = Hanging(), handle = CodexLogin.Handle()
        let task = Task { await Self.signIn(r, runner: child.runner, handle: handle) }
        let deadline = Date().addingTimeInterval(10)
        while !child.running, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let live = scratchLeft(r)
        XCTAssertEqual(live.count, 1)
        try FileManager.default.createDirectory(at: r.root.appendingPathComponent("later", isDirectory: true), withIntermediateDirectories: true)
        CodexLogin.sweep(root: r.root)
        XCTAssertEqual(Set(scratchLeft(r)), Set(live + ["later"]), "a live login makes the whole sweep a no-op, its scratch included")
        handle.cancel()
        _ = await task.value
    }

    func testQuitHookStopsTheLiveChildAndRemovesItsScratch() async throws {
        let r = rig(), child = Hanging()
        let task = Task { await Self.signIn(r, runner: child.runner) }
        let deadline = Date().addingTimeInterval(10)
        while !child.running, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(scratchLeft(r).count, 1)
        CodexLogin.Live.terminate()
        XCTAssertEqual(child.stops, 1, "the live child got its stop (SIGTERM to its own pid)")
        XCTAssertEqual(scratchLeft(r), [], "the scratch is removed on the quit path itself")
        _ = await task.value
        XCTAssertFalse(CodexLogin.Live.isActive)
    }

    func testASecondSignInWhileOneIsLiveFailsAndLeavesTheFirstAlone() async throws {
        let r = rig(), child = Hanging(), second = Hanging()
        let task = Task { await Self.signIn(r, runner: child.runner) }
        let deadline = Date().addingTimeInterval(10)
        while !child.running, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(scratchLeft(r).count, 1)
        let outcome = await Self.signIn(r, runner: second.runner, label: "codex-2")
        XCTAssertEqual(outcome, .failed(CodexLogin.alreadyRunning))
        XCTAssertFalse(second.running, "no second child")
        XCTAssertEqual(scratchLeft(r).count, 1, "the first scratch stays")
        XCTAssertTrue(CodexLogin.Live.isActive, "the first slot stays")
        CodexLogin.Live.terminate()
        XCTAssertEqual(child.stops, 1, "quit still stops the first child")
        _ = await task.value
    }

    func testQuitHookWithNoLiveLoginIsANoOp() {
        XCTAssertFalse(CodexLogin.Live.isActive)
        CodexLogin.Live.terminate()
        XCTAssertFalse(CodexLogin.Live.isActive)
    }
}
