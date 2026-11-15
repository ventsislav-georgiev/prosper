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

    /// #1231 (N1227-a): a vault that starts with a UTF-8 mark is read as the same vault without it (since #1227;
    /// before, "not JSON"). Made-up vault in the row's tempDir, the in-memory secrets store, dummy tokens.
    func testCCPoolVaultThatStartsWithAMarkIsReadAsWithout() throws {
        let plain = try fixture()
        let marked = tempDir().appendingPathComponent(CCPoolMigration.vaultFileName)
        let bytes: [UInt8] = try [0xEF, 0xBB, 0xBF] + Array(Data(contentsOf: plain))
        try Data(bytes).write(to: marked)
        _ = try write(marked.deletingLastPathComponent(), CCPoolMigration.stateFileName, #"{"current": "beta"}"#)
        XCTAssertEqual(try CCPoolMigration.inspect(vault: marked, store: store()), try CCPoolMigration.inspect(vault: plain, store: store()))
        let st = store()
        let secrets = CCPoolMemorySecrets()
        let out = try CCPoolMigration.run(vault: marked, store: st, secrets: secrets, choices: [:], now: t0)
        XCTAssertEqual(out.imported, ["alpha", "beta"])
        XCTAssertEqual(out.failures, [.init(label: "gamma", reason: CCPoolMigration.reasonNoToken)])
        XCTAssertEqual(try secrets.token(id: try XCTUnwrap(st.snapshot.accounts["beta"]?.id)), "tok-beta")
        XCTAssertEqual(try secrets.token(id: try XCTUnwrap(st.snapshot.accounts["alpha"]?.id)), "tok-alpha")
        XCTAssertEqual(Array(try Data(contentsOf: marked)), bytes, "the vault is never written")
    }

    // QA #739 INFO-14 (A7): a Replace that fails keeps the old Keychain item and the old listing.
    func testCCPoolFailedReplaceKeepsTheOldItem() throws {
        let vault = try fixture()
        // The new item cannot be written.
        let st = store()
        let secrets = CCPoolMemorySecrets()
        try st.addAccount(label: "alpha", token: "tok-old", secrets: secrets)
        let oldID = try XCTUnwrap(st.snapshot.accounts["alpha"]?.id)
        secrets.refuseStore = true
        let out = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: ["alpha": .replace], now: t0)
        XCTAssertEqual(out.failures.first { $0.label == "alpha" }?.reason, CCPoolMigration.reasonKeychain)
        XCTAssertEqual(out.replaced, [])
        XCTAssertEqual(out.retiredIDs, [])
        XCTAssertEqual(st.snapshot.accounts["alpha"]?.id, oldID, "still listed under the old item")
        XCTAssertEqual(try secrets.token(id: oldID), "tok-old", "the old item survives")
        XCTAssertEqual(secrets.count, 1)

        // The new item reads back different.
        let trunc = TruncatingSecrets()
        let st2 = store()
        try st2.addAccount(label: "alpha", token: "tok-old", secrets: trunc.inner)
        let oldID2 = try XCTUnwrap(st2.snapshot.accounts["alpha"]?.id)
        let out2 = try CCPoolMigration.run(vault: vault, store: st2, secrets: trunc, choices: ["alpha": .replace], now: t0)
        XCTAssertEqual(out2.failures.first { $0.label == "alpha" }?.reason, CCPoolMigration.reasonReadBack)
        XCTAssertEqual(out2.replaced, [])
        XCTAssertEqual(st2.snapshot.accounts["alpha"]?.id, oldID2)
        XCTAssertEqual(try trunc.inner.token(id: oldID2), "tok-old", "the old item survives")
        XCTAssertEqual(trunc.inner.count, 1, "and only it: the truncated new items are removed")
    }

    // QA #739 INFO-5 (B5): an old item that cannot be deleted after a replace is logged, label only.
    func testCCPoolReplaceLogsAnOldItemItCannotDelete() throws {
        let vault = try fixture()
        let log = CCPoolCapturingLogger()
        let t = t0
        let st = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"), clock: { t }, logger: log)
        let secrets = CCPoolMemorySecrets()
        try st.addAccount(label: "alpha", token: "tok-old", secrets: secrets)
        let oldID = try XCTUnwrap(st.snapshot.accounts["alpha"]?.id)
        secrets.refuseRemove = true
        let out = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: ["alpha": .replace], now: t0)
        XCTAssertEqual(out.replaced, ["alpha"])
        XCTAssertEqual(try secrets.token(id: oldID), "tok-old", "the delete really failed")
        XCTAssertTrue(log.lines.contains("alpha: replaced; the old Keychain item could not be deleted"), "\(log.lines)")
        XCTAssertTrue(out.notes.contains { $0.hasPrefix("alpha: the replaced token") }, "\(out.notes)")
        for text in log.lines + out.notes { XCTAssertFalse(text.contains("tok-"), text) }
    }

    // QA #739 INFO-6 (B3): vault labels follow the typed-label rule; a bad one is refused with a
    // fixed reason and never shown, logged or stored as it is.
    // QA #751 INFO-2 (mutant h14): a Replace is a new token: the old one's benches and resets go,
    // and a hand hold stays to its own end.
    func testCCPoolReplaceDropsTheOldBenchesKeepsAHold() throws {
        let vault = try write(tempDir(), CCPoolMigration.vaultFileName,
                              #"{"accounts": {"alpha": {"token": "tok-a2"}, "beta": {"token": "tok-b2"}}}"#)
        let st = store()
        let secrets = CCPoolMemorySecrets()
        try st.addAccount(label: "alpha", token: "tok-a", secrets: secrets)
        try st.addAccount(label: "beta", token: "tok-b", secrets: secrets)
        st.mutate { s in
            s.bench("alpha", claim: "seven_day", until: Int(t0) + 86400, now: t0)
            s.accounts["alpha"]?.reset = ["seven_day": Int(t0) + 86400]
            s.hold("beta", hours: 2, now: t0)
            s.bench("beta", claim: "seven_day", until: Int(t0) + 86400, now: t0)
        }
        let out = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets,
                                          choices: ["alpha": .replace, "beta": .replace], now: t0)
        XCTAssertEqual(out.replaced, ["alpha", "beta"])
        let snap = st.snapshot
        XCTAssertEqual(snap.accounts["alpha"]?.cooldown, [:], "the old token's bench is not the new one's")
        XCTAssertEqual(snap.accounts["alpha"]?.reset, [:])
        XCTAssertEqual(snap.accounts["beta"]?.cooldown, [CCPoolCore.fiveHour: Int(t0) + 7200], "the hold stays, the bench goes")
        XCTAssertEqual(snap.accounts["beta"]?.held, Int(t0) + 7200)
    }

    // #1190 (mutant v7): a hand hold that already ended is not carried onto the new token.
    func testCCPoolReplaceDropsAHoldThatEnded() throws {
        let vault = try write(tempDir(), CCPoolMigration.vaultFileName, #"{"accounts": {"alpha": {"token": "tok-a2"}}}"#)
        let st = store()
        let secrets = CCPoolMemorySecrets()
        try st.addAccount(label: "alpha", token: "tok-a", secrets: secrets)
        st.mutate { s in s.hold("alpha", hours: 1, now: t0 - 7200) }   // ended an hour ago
        XCTAssertEqual(st.snapshot.accounts["alpha"]?.held, Int(t0) - 3600)
        let out = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: ["alpha": .replace], now: t0)
        XCTAssertEqual(out.replaced, ["alpha"])
        XCTAssertTrue(st.snapshot.accounts["alpha"]?.held == nil, "an ended hold is not the new token's")
        XCTAssertEqual(st.snapshot.accounts["alpha"]?.cooldown, [:])
    }

    // QA #751 INFO-5: a new item this import could not delete again is named in the notes, label only.
    func testCCPoolImportNamesAnItemItCouldNotDelete() throws {
        let vault = try fixture()
        let secrets = TruncatingSecrets()
        secrets.inner.refuseRemove = true
        let out = try CCPoolMigration.run(vault: vault, store: store(), secrets: secrets, choices: [:], now: t0)
        XCTAssertEqual(out.failures.map(\.label), ["alpha", "beta", "gamma"])
        XCTAssertEqual(out.notes, ["alpha: " + CCPoolMigration.noteOrphan, "beta: " + CCPoolMigration.noteOrphan])
        XCTAssertTrue(CCPoolPaneModel.summary(out).contains("alpha: " + CCPoolMigration.noteOrphan))
        XCTAssertEqual(secrets.inner.count, 2)
    }

    func testCCPoolVaultLabelsFollowTheLabelRule() async throws {
        let long = String(repeating: "x", count: CCPoolStore.labelMax + 1)
        let bad = ["bell\u{7}x", "zero\u{200B}width", "rtl\u{202E}abc", "line\u{2028}x", "tab\tx", long, "", "  "]
        for label in bad {
            XCTAssertNotNil(CCPoolStore.labelProblem(label), label.debugDescription)
        }
        // Mutant g13: default-ignorable scalars that are neither format characters nor whitespace,
        // caught only by isDefaultIgnorableCodePoint (U+3164 is a letter, U+034F a combining mark).
        for label in ["hangul\u{3164}filler", "cgj\u{034F}x", "\u{3164}"] {
            XCTAssertEqual(CCPoolStore.labelProblem(label), .badLabel, label.debugDescription)
        }
        // QA #751 INFO-8: U+00A0 (Zs) is caught only by the non-space whitespace clause, U+E000 (Co)
        // only by the private-use category. INFO-7: U+2800 (So) renders blank and is refused by name.
        for label in ["nbsp\u{00A0}x", "pua\u{E000}x", "\u{2800}", "blank\u{2800}x"] {
            XCTAssertEqual(CCPoolStore.labelProblem(label), .badLabel, label.debugDescription)
        }
        // Review INFO 8 (kept): emoji sequences carry U+200D or U+FE0F and are refused, and the hint
        // says so; a plain emoji and a flag (regional indicators) pass.
        for label in ["dev \u{1F469}\u{200D}\u{1F4BB}", "love \u{2764}\u{FE0F}"] {
            XCTAssertEqual(CCPoolStore.labelProblem(label), .badLabel, label.debugDescription)
        }
        for label in ["dev \u{1F4BB}", "flag \u{1F1E7}\u{1F1EC}"] { XCTAssertNil(CCPoolStore.labelProblem(label), label) }
        XCTAssertTrue(CCPoolStoreError.badLabel.description.contains("emoji"))
        for label in ["work-account@example.com", "personal", "Zoë 2", String(repeating: "x", count: CCPoolStore.labelMax)] {
            XCTAssertNil(CCPoolStore.labelProblem(label), label)
        }

        let dir = tempDir()
        let vault = dir.appendingPathComponent(CCPoolMigration.vaultFileName)
        let json = #"{"accounts": {"ok": {"token": "tok-ok"}, "bell\u0007x": {"token": "tok-1"}, "zero\u200bwidth": {"token": "tok-2"}, "#
            + #""rtl\u202eabc": {"token": "tok-3"}, "line\u2028x": {"token": "tok-4"}, "tab\tx": {"token": "tok-5"}, "#
            + #""\#(long)": {"token": "tok-6"}, "": {"token": "tok-7"}}}"#
        try Data(json.utf8).write(to: vault)
        let log = CCPoolCapturingLogger()
        let t = t0
        let st = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"), clock: { t }, logger: log)
        let secrets = CCPoolMemorySecrets()
        let shown = ["ok"] + (2...8).map { "entry \($0) (unusable label)" }
        XCTAssertEqual(try CCPoolMigration.inspect(vault: vault, store: st).labels, shown)
        let out = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: [:], now: t0)
        XCTAssertEqual(out.imported, ["ok"])
        // Review INFO 3: the empty label (entry 8) gets its own reason.
        XCTAssertEqual(out.failures, (2...7).map { CCPoolMigration.Failure(label: "entry \($0) (unusable label)", reason: CCPoolMigration.reasonBadLabel) }
            + [CCPoolMigration.Failure(label: "entry 8 (unusable label)", reason: CCPoolMigration.reasonEmptyLabel)])
        XCTAssertEqual(st.snapshot.order, ["ok"])
        XCTAssertEqual(secrets.count, 1, "no item for a refused entry")
        XCTAssertFalse(out.allHeld, "the vault keeps what was refused")
        let texts = ["\(out)"] + CCPoolPaneModel.summary(out) + log.lines
            + [try String(contentsOf: st.stateURL, encoding: .utf8)]
        for text in texts {
            for raw in ["bell", "zero", "rtl", "line", "tab", long] { XCTAssertFalse(text.contains(raw), "\(raw) in \(text.prefix(200))") }
        }

        // A typed label meets the same rule: refused before any probe or Keychain write.
        for label in ["a\u{200B}b", long] {
            XCTAssertThrowsError(try st.addAccount(label: label, token: "tok-typed", secrets: secrets)) {
                XCTAssertEqual($0 as? CCPoolStoreError, .badLabel)
            }
            let added = await CCPoolPaneModel.add(label: label, token: "tok-typed", store: st, secrets: secrets,
                                                  base: URL(string: "http://127.0.0.1:9")!)
            XCTAssertEqual(added, .failed(CCPoolStoreError.badLabel.description))
            XCTAssertThrowsError(try st.renameAccount("ok", to: label)) { XCTAssertEqual($0 as? CCPoolStoreError, .badLabel) }
        }
        XCTAssertEqual(secrets.count, 1)
        XCTAssertEqual(st.snapshot.order, ["ok"])
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

    // MARK: #1264 a person moving from the Python proxy

    /// A reference-shaped home: the vault in a custom order (C, A, B: the Python pick order is the vault's key
    /// order, there is no "order" key) and a state.json as the Python writes it (indent 2): current, a bench and a
    /// reset at a fixed time after `now`, and pins (one bad key, one to an account not in the vault, one not a text).
    private func referenceHome(vaultText: String? = nil, stateText: String? = nil) throws -> URL {
        let dir = tempDir()
        let until = Int(t0) + 7200
        let vault = try write(dir, CCPoolMigration.vaultFileName, vaultText ?? """
            {
              "accounts": {
                "Example Org C": {"token": "tok-example-c"},
                "Example Org A": {"token": "tok-example-a"},
                "Example Org B": {"token": "tok-example-b"}
              }
            }
            """)
        _ = try write(dir, CCPoolMigration.stateFileName, stateText ?? """
            {
              "current": "Example Org A",
              "accounts": {
                "Example Org B": {"cooldown": {"five_hour": \(until)}, "reset": {"five_hour": \(until)}}
              },
              "pins": {
                "sess-example-1/": "Example Org B",
                "sess-example-1/agent-example-1": "Example Org B",
                "sess-example-2/": "Example Org C",
                "sess-example-3/": "Example Org Z",
                "bad key/": "Example Org A",
                "sess-example-4/": 7
              }
            }
            """)
        return vault
    }

    private let referencePins = ["sess-example-1/": "Example Org B", "sess-example-1/agent-example-1": "Example Org B",
                                 "sess-example-2/": "Example Org C"]

    /// Order, benches and pins come over; tokens go to the (fake) secrets store only, never the state file or the log.
    func testCCPoolReferenceStateKeepsOrderBenchesAndPins() throws {
        let vault = try referenceHome()
        let log = CCPoolCapturingLogger()
        let t = t0
        let st = CCPoolStore(directory: tempDir().appendingPathComponent("ccpool"), clock: { t }, logger: log)
        let secrets = CCPoolMemorySecrets()
        let out = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: [:], now: t0)
        let names = ["Example Org C", "Example Org A", "Example Org B"]
        XCTAssertEqual(out.imported, names)
        XCTAssertEqual(out.notes, [])
        for snap in [st.snapshot, CCPoolStore(directory: st.directory).snapshot] {   // in memory, then read back from the file
            XCTAssertEqual(snap.order, names, "the vault's order is the pick order")
            XCTAssertEqual(snap.current, "Example Org A")
            XCTAssertEqual(snap.accounts["Example Org B"]?.cooldown, ["five_hour": Int(t0) + 7200])
            XCTAssertEqual(snap.accounts["Example Org B"]?.reset, ["five_hour": Int(t0) + 7200])
            XCTAssertEqual(snap.accounts["Example Org A"]?.cooldown, [:])
            XCTAssertEqual(snap.pins.mapValues(\.account), referencePins,
                           "valid keys to pool accounts only: the bad key, the unknown account and the number are dropped")
        }
        XCTAssertEqual(st.snapshot.pins["sess-example-2/"]?.seen, t0, "stamped at the import, as Python load_pins")
        XCTAssertEqual(secrets.count, 3)
        for (label, tok) in zip(names, ["tok-example-c", "tok-example-a", "tok-example-b"]) {
            XCTAssertEqual(try secrets.token(id: try XCTUnwrap(st.snapshot.accounts[label]?.id)), tok, label)
        }
        let file = try String(contentsOf: st.stateURL, encoding: .utf8)
        XCTAssertTrue(file.contains("sess-example-2"), "the pins are in the file (JSONEncoder writes / as \\/)")
        let texts = [file, "\(out)"] + CCPoolPaneModel.summary(out) + log.lines
        for text in texts { XCTAssertFalse(text.contains("tok-example"), "token leaked into: \(text.prefix(300))") }

        // The pool's own pin wins over the old file's on a second import.
        st.mutate { _ = $0.pin("sess-example-2/", to: "Example Org A", now: t0) }
        _ = try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: [:], now: t0)
        XCTAssertEqual(st.snapshot.pins["sess-example-2/"]?.account, "Example Org A")
    }

    /// A truncated vault is refused whole: the pool, its file and the secrets store stay as they were. A truncated
    /// state file: the accounts still come over, no bench and no pin from it, and the summary says so.
    func testCCPoolReferenceFilesTruncatedLeaveThePoolAlone() throws {
        let st = store()
        let secrets = CCPoolMemorySecrets()
        try st.addAccount(label: "Example Org A", token: "tok-example-old", secrets: secrets)
        st.mutate { _ = $0.pin("sess-example-9/", to: "Example Org A", now: t0) }
        let before = st.snapshot
        let fileBefore = try Data(contentsOf: st.stateURL)
        let good = try String(contentsOf: try referenceHome(), encoding: .utf8)
        let cut = try referenceHome(vaultText: String(good.prefix(good.count / 2)))
        XCTAssertThrowsError(try CCPoolMigration.run(vault: cut, store: st, secrets: secrets, choices: [:], now: t0)) {
            XCTAssertEqual($0 as? CCPoolMigration.ReadError, .notJSON)
            XCTAssertFalse("\($0)".contains("tok-"), "never quotes the file")
        }
        XCTAssertTrue(st.snapshot == before, "nothing changed in the pool")
        XCTAssertEqual(try Data(contentsOf: st.stateURL), fileBefore)
        XCTAssertEqual(secrets.count, 1)

        let fresh = store()
        let halfState = try referenceHome(stateText: #"{"current": "Example Org A", "pins": {"sess-example-1/": "Exam"#)
        let out = try CCPoolMigration.run(vault: halfState, store: fresh, secrets: CCPoolMemorySecrets(), choices: [:], now: t0)
        XCTAssertEqual(out.imported, ["Example Org C", "Example Org A", "Example Org B"])
        XCTAssertEqual(CCPoolPaneModel.summary(out).last, CCPoolMigration.noteStateUnreadable, "what the person reads")
        XCTAssertEqual(fresh.snapshot.pins.count, 0)
        XCTAssertEqual(fresh.snapshot.accounts["Example Org B"]?.cooldown, [:])
        XCTAssertTrue(fresh.snapshot.current == nil)
    }

    /// Files above the cap are refused, though both are valid JSON (padded with spaces): only cap + 1 bytes are read.
    func testCCPoolReferenceFilesAboveTheCapAreRefused() throws {
        let pad = { (text: String) -> Data in
            let d = Data(text.utf8)
            return d + Data(repeating: 0x20, count: CCPoolMigration.maxFileBytes + 1 - d.count)
        }
        let st = store()
        let secrets = CCPoolMemorySecrets()
        let vault = try referenceHome()
        try pad(try String(contentsOf: vault, encoding: .utf8)).write(to: vault)
        XCTAssertThrowsError(try CCPoolMigration.inspect(vault: vault, store: st)) {
            XCTAssertEqual($0 as? CCPoolMigration.ReadError, .tooLarge)
        }
        XCTAssertThrowsError(try CCPoolMigration.run(vault: vault, store: st, secrets: secrets, choices: [:], now: t0)) {
            XCTAssertEqual($0 as? CCPoolMigration.ReadError, .tooLarge)
        }
        XCTAssertEqual(st.snapshot.order, [])
        XCTAssertEqual(secrets.count, 0)

        let home = try referenceHome()
        let state = CCPoolMigration.stateURL(vault: home)
        try pad(try String(contentsOf: state, encoding: .utf8)).write(to: state)
        let out = try CCPoolMigration.run(vault: home, store: st, secrets: secrets, choices: [:], now: t0)
        XCTAssertEqual(out.imported.count, 3)
        XCTAssertEqual(out.notes, [CCPoolMigration.noteStateUnreadable])
        XCTAssertEqual(st.snapshot.pins.count, 0, "nothing carried from an oversized state file")
        XCTAssertTrue(st.snapshot.current == nil)
    }

    /// R1264-q1 (QA r1158): a pool already holding pinCap pins of its own imports none of the old file's 3 pins: an import
    /// is stamped newer than every own pin, and the cap evicts the oldest, so it would push out the pool's live pins.
    func testCCPoolImportNeverEvictsOwnPins() throws {
        let st = store()
        let secrets = CCPoolMemorySecrets()
        try st.addAccount(label: "Example Org A", token: "tok-example-own", secrets: secrets)
        st.mutate { s in for i in 0..<CCPoolState.pinCap { _ = s.pin("own-example-\(i)/", to: "Example Org A", now: t0 - 10) } }
        XCTAssertEqual(st.snapshot.pins.count, CCPoolState.pinCap)
        let out = try CCPoolMigration.run(vault: try referenceHome(), store: st, secrets: secrets, choices: [:], now: t0)
        XCTAssertEqual(out.imported, ["Example Org C", "Example Org B"])
        let pins = st.snapshot.pins
        XCTAssertEqual(pins.count, 512)
        XCTAssertEqual(pins["own-example-0/"]?.account, "Example Org A", "the oldest own pin is still there")
        XCTAssertEqual(pins.keys.filter { $0.hasPrefix("own-example-") }.count, 512)
        XCTAssertTrue(referencePins.keys.allSatisfy { pins[$0] == nil }, "no imported pin")
    }
}
