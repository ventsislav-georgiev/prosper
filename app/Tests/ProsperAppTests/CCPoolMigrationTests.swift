import XCTest
@testable import ProsperApp

/// #871 spec 3.7: the one-time import from the Python ccpool, against a fixture vault in a temp
/// dir. Never the real ccpool home, never the Keychain (CCPoolMemorySecrets), dummy tokens only.
final class CCPoolMigrationTests: XCTestCase {
    private let t0 = 1_800_000_000.0

    /// Stores a shortened token: the read-back must catch it.
    private final class TruncatingSecrets: CCPoolSecrets, @unchecked Sendable {
        let inner = CCPoolMemorySecrets()
        func store(token: String, id: String, label: String) throws { try inner.store(token: String(token.dropLast()), id: id, label: label) }
        func token(id: String) throws -> String? { try inner.token(id: id) }
        func remove(id: String) throws { try inner.remove(id: id) }
    }

    private final class RefusingSecrets: CCPoolSecrets, @unchecked Sendable {
        func store(token: String, id: String, label: String) throws { throw CCPoolSecretsError.unavailable }
        func token(id: String) throws -> String? { nil }
        func remove(id: String) throws {}
    }

    private func write(_ dir: URL, _ name: String, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// alpha, beta (padded token), gamma (no token), in that order; state with cooldowns and current.
    private func fixture(state: String? = nil) throws -> URL {
        let dir = tempDir()
        let vault = try write(dir, CCPoolMigration.vaultFileName, """
            {"accounts": {"alpha": {"token": "tok-alpha"}, "beta": {"token": " tok-beta\\n"}, "gamma": {}}}
            """)
        let s = state ?? """
            {"current": "beta", "accounts": {"alpha": {"cooldown": {"five_hour": \(Int(t0) + 3600), "seven_day": \(Int(t0) + 30 * 86400),
             "seven_day_opus": \(Int(t0) - 60)}, "reset": {"five_hour": \(Int(t0) + 3600), "seven_day": \(Int(t0) - 10)}}}}
            """
        _ = try write(dir, CCPoolMigration.stateFileName, s)
        return vault
    }

    private func store() -> CCPoolStore {
        let t = t0
        return CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"), clock: { t })
    }

    func testCCPoolVaultPathRule() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let v = CCPoolMigration.homeVariable
        XCTAssertEqual(CCPoolMigration.vaultURL(home: home, environment: [:]).path,
                       "/Users/someone/" + CCPoolMigration.homeDirName + "/" + CCPoolMigration.vaultFileName)
        XCTAssertEqual(CCPoolMigration.vaultURL(home: home, environment: [v: ""]),
                       CCPoolMigration.vaultURL(home: home, environment: [:]), "an empty variable counts as unset")
        XCTAssertEqual(CCPoolMigration.vaultURL(home: home, environment: [v: "/opt/pool"]).path,
                       "/opt/pool/" + CCPoolMigration.vaultFileName)
        XCTAssertEqual(CCPoolMigration.stateURL(vault: URL(fileURLWithPath: "/opt/pool/x")).path, "/opt/pool/" + CCPoolMigration.stateFileName)
    }

    func testCCPoolImportCarriesTokensOrderCooldownsAndCurrent() throws {
        let vault = try fixture()
        let before = try Data(contentsOf: vault)
        let st = store()
        let secrets = CCPoolMemorySecrets()
        XCTAssertEqual(try CCPoolMigration.inspect(vault: vault, store: st), .init(labels: ["alpha", "beta", "gamma"], conflicts: []))
        XCTAssertEqual(secrets.count, 0, "inspect writes nothing")

        let out = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: [:], now: t0)
        XCTAssertEqual(out.imported, ["alpha", "beta"])
        XCTAssertEqual(out.failures, [.init(label: "gamma", reason: CCPoolMigration.reasonNoToken)])
        XCTAssertEqual(out.retiredIDs, [])
        let snap = st.snapshot
        XCTAssertEqual(snap.order, ["alpha", "beta"], "vault order kept")
        XCTAssertEqual(snap.current, "beta", "current carried")
        XCTAssertEqual(try secrets.token(id: try XCTUnwrap(snap.accounts["beta"]?.id)), "tok-beta", "trimmed like the Python")
        XCTAssertEqual(try secrets.token(id: try XCTUnwrap(snap.accounts["alpha"]?.id)), "tok-alpha")
        XCTAssertEqual(secrets.count, 2)
        let cd = try XCTUnwrap(snap.accounts["alpha"]?.cooldown)
        XCTAssertEqual(cd["five_hour"], Int(t0) + 3600)
        XCTAssertEqual(cd["seven_day"], Int(t0) + 8 * 86400, "capped at 8 days (B3)")
        XCTAssertNil(cd["seven_day_opus"], "an expired cooldown is not carried")
        XCTAssertEqual(snap.accounts["alpha"]?.reset, ["five_hour": Int(t0) + 3600], "only resets still ahead")
        XCTAssertEqual(snap.accounts["beta"]?.cooldown, [:])
        XCTAssertEqual(try Data(contentsOf: vault), before, "the vault is never written")
        XCTAssertEqual(CCPoolStore(directory: st.directory).snapshot.order, ["alpha", "beta"], "persisted")
    }

    func testCCPoolImportConflictsAskReplaceOrSkip() throws {
        let vault = try fixture()
        let st = store()
        let secrets = CCPoolMemorySecrets()
        try st.addAccount(label: "alpha", token: "tok-old", secrets: secrets)
        st.mutate { $0.current = "alpha" }
        let oldID = try XCTUnwrap(st.snapshot.accounts["alpha"]?.id)
        XCTAssertEqual(try CCPoolMigration.inspect(vault: vault, store: st).conflicts, ["alpha"])

        var out = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: [:], now: t0)
        XCTAssertEqual(out.undecided, ["alpha"], "no choice: reported back, left alone")
        XCTAssertEqual(out.imported, ["beta"])
        XCTAssertEqual(st.snapshot.accounts["alpha"]?.id, oldID)
        XCTAssertEqual(try secrets.token(id: oldID), "tok-old")
        XCTAssertEqual(st.snapshot.current, "alpha", "the pool's own current wins")

        out = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: ["alpha": .skip, "beta": .skip], now: t0)
        XCTAssertEqual(out.skipped, ["alpha", "beta"])
        XCTAssertEqual(try secrets.token(id: oldID), "tok-old")
        XCTAssertEqual(secrets.count, 2)

        out = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: ["alpha": .replace], now: t0)
        XCTAssertEqual(out.replaced, ["alpha"])
        XCTAssertEqual(out.retiredIDs, [oldID])
        XCTAssertEqual(out.undecided, ["beta"])
        let newID = try XCTUnwrap(st.snapshot.accounts["alpha"]?.id)
        XCTAssertNotEqual(newID, oldID)
        XCTAssertNil(try secrets.token(id: oldID), "the old item is removed once the new one is proven")
        XCTAssertEqual(try secrets.token(id: newID), "tok-alpha")
        XCTAssertEqual(st.snapshot.order, ["alpha", "beta"], "a replace keeps the pick-order slot")
        XCTAssertEqual(st.snapshot.accounts["alpha"]?.cooldown["five_hour"], Int(t0) + 3600)
        XCTAssertEqual(secrets.count, 2)
    }

    func testCCPoolImportFailuresLeaveNoItemBehind() throws {
        let vault = try fixture()
        let trunc = TruncatingSecrets()
        var st = store()
        var out = try CCPoolMigration.run(vault: vault, store: st, secrets: trunc, choices: [:], now: t0)
        XCTAssertEqual(out.failures.map(\.reason), [CCPoolMigration.reasonReadBack, CCPoolMigration.reasonReadBack, CCPoolMigration.reasonNoToken])
        XCTAssertEqual(trunc.inner.count, 0)
        XCTAssertEqual(st.snapshot.order, [])

        st = store()
        out = try CCPoolMigration.run(vault: vault, store: st, secrets: RefusingSecrets(), choices: [:], now: t0)
        XCTAssertEqual(out.failures.filter { $0.reason == CCPoolMigration.reasonKeychain }.map(\.label), ["alpha", "beta"])
        XCTAssertEqual(st.snapshot.order, [])

        // The state cannot be written: the item goes again, the label is reported.
        let blocker = tempDir().appendingPathComponent("blocker")
        try Data().write(to: blocker)
        st = CCPoolStore(directory: blocker.appendingPathComponent("ccpool"))
        let secrets = CCPoolMemorySecrets()
        out = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: [:], now: t0)
        XCTAssertEqual(out.failures.filter { $0.reason == CCPoolMigration.reasonState }.map(\.label), ["alpha", "beta"])
        XCTAssertEqual(secrets.count, 0)
        XCTAssertEqual(st.snapshot.order, [])
    }

    func testCCPoolImportBadVaultOrState() throws {
        let dir = tempDir()
        let st = store()
        let secrets = CCPoolMemorySecrets()
        let cases: [(String?, CCPoolMigration.ReadError)] = [
            (nil, .unreadable),
            ("tok-in-a-broken-file {", .notJSON),
            (#"{"other": {"tok-x": 1}}"#, .noAccounts),
            (#"{"accounts": ["tok-x"]}"#, .noAccounts),
        ]
        for (i, (text, want)) in cases.enumerated() {
            let sub = dir.appendingPathComponent("\(i)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let vault = sub.appendingPathComponent(CCPoolMigration.vaultFileName)
            if let text { try Data(text.utf8).write(to: vault) }
            XCTAssertThrowsError(try CCPoolMigration.inspect(vault: vault, store: st)) { XCTAssertEqual($0 as? CCPoolMigration.ReadError, want) }
            XCTAssertThrowsError(try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: [:], now: t0)) {
                XCTAssertEqual($0 as? CCPoolMigration.ReadError, want)
                XCTAssertFalse("\($0)".contains("tok-"), "never quotes the file")
            }
        }
        XCTAssertEqual(secrets.count, 0)

        // An unreadable state file: tokens still import, the cooldowns do not, and it says so.
        let vault = try fixture(state: "not json tok-zzz")
        let out = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: [:], now: t0)
        XCTAssertEqual(out.imported, ["alpha", "beta"])
        XCTAssertEqual(out.notes, [CCPoolMigration.noteStateUnreadable])
        XCTAssertEqual(st.snapshot.accounts["alpha"]?.cooldown, [:])
        XCTAssertNil(st.snapshot.current)
    }

    // Leak guard: no outcome, error, summary line, log line or state file holds a token.
    func testCCPoolImportLeakGuard() throws {
        let vault = try fixture()
        let log = CCPoolCapturingLogger()
        let t = t0
        let st = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"), clock: { t }, logger: log)
        let secrets = CCPoolMemorySecrets()
        try st.addAccount(label: "alpha", token: "tok-old", secrets: secrets)
        var texts: [String] = []
        let a = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: [:], now: t0)
        let b = try CCPoolMigration.run(vault: vault, store: st, secrets: TruncatingSecrets(), choices: ["alpha": .replace], now: t0)
        for o in [a, b] {
            texts.append("\(o)")
            texts += CCPoolPaneModel.summary(o)
        }
        texts += [CCPoolMigration.ReadError.unreadable, .notJSON, .noAccounts].map { "\($0)" }
        texts += log.lines
        texts.append(try String(contentsOf: st.stateURL, encoding: .utf8))
        XCTAssertTrue(texts.contains { $0.contains("alpha") }, "the texts are real")
        for text in texts { XCTAssertFalse(text.contains("tok-"), "token leaked into: \(text.prefix(300))") }
    }
}
