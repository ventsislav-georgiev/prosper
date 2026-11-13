import Foundation

/// #871 spec 3.7: the one-time import from the Python ccpool. The vault (`{accounts: {label:
/// {token}}}`) is read only on an explicit import call; each token goes into `CCPoolSecrets`, is
/// read back and compared by byte length in memory, then listed in the store under its label.
/// `cooldown`, `reset` and `current` are carried from the Python state file. Nothing here prints,
/// logs or returns a token: errors and outcomes name labels only, never quote the files.
///
/// Isolation: none (an enum of static functions). Blocking file and Keychain I/O: call off main.
enum CCPoolMigration {
    static let homeVariable = "CCPOOL_HOME"
    static let homeDirName = ".ccpool"
    static let vaultFileName = "vault.json"
    static let stateFileName = "state.json"

    /// The ONE production path rule: `$CCPOOL_HOME/vault.json`, else `<home>/.ccpool/vault.json`.
    /// Reads nothing. One deliberate difference from the Python ccpool (QA #739 INFO-7): Python's
    /// `Path(os.environ.get(...))` reads an EMPTY variable as "" = its current directory; here an
    /// empty variable counts as unset, since the app's current directory is never the one the
    /// user ran ccpool in. (A relative value resolves against the app's directory, not theirs.)
    static func vaultURL(home: URL, environment: [String: String]) -> URL {
        let dir = environment[homeVariable].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(homeDirName, isDirectory: true)
        return dir.appendingPathComponent(vaultFileName)
    }

    static func stateURL(vault: URL) -> URL {
        vault.deletingLastPathComponent().appendingPathComponent(stateFileName)
    }

    /// "Move the old vault to the Trash" seam. Production: recoverable, never unlink or rm.
    typealias Trash = @Sendable (URL) throws -> Void
    static let moveToTrash: Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    enum Choice: Equatable, Sendable { case replace, skip }

    /// What an import would do, labels only.
    struct Plan: Equatable, Sendable {
        var labels: [String]
        /// Labels the pool already has: each needs the caller's replace-or-skip choice.
        var conflicts: [String]
    }

    struct Failure: Equatable, Sendable, CustomStringConvertible {
        var label: String
        var reason: String
        var description: String { "\(label): \(reason)" }
    }

    struct Outcome: Equatable, Sendable {
        var imported: [String] = []
        var replaced: [String] = []
        var skipped: [String] = []
        /// Conflicts the caller gave no choice for: reported back, left untouched.
        var undecided: [String] = []
        var failures: [Failure] = []
        var notes: [String] = []
        /// Keychain ids a replaced token used to live under (now removed): drop their upstream sessions.
        var retiredIDs: [String] = []
        /// QA #739 INFO-2: skipped or left-alone labels whose token in the pool is not the vault's.
        var notHeld: [String] = []
        /// QA #739 INFO-3: where vault.json points when it is a symbolic link (path only).
        var vaultLink: String?
        /// Every vault token is now in the pool (imported, replaced, or the same token already
        /// listed): only then may the old vault go to the Trash.
        var allHeld: Bool { failures.isEmpty && notHeld.isEmpty }
    }

    /// Why nothing was imported. Never quotes the file.
    enum ReadError: Error, Equatable, CustomStringConvertible {
        case unreadable, notJSON, noAccounts

        var description: String {
            switch self {
            case .unreadable: return "ccpool import: the old vault could not be read; nothing imported"
            case .notJSON: return "ccpool import: the old vault is not valid JSON; nothing imported"
            case .noAccounts: return "ccpool import: the old vault has no accounts list; nothing imported"
            }
        }
    }

    static let reasonNoToken = "no token in the old vault"
    static let reasonBadLabel = "its label is too long or holds a control or invisible character; not imported"
    /// Review INFO 3: an empty or blank vault label is not "too long or invisible".
    static let reasonEmptyLabel = "its label is empty; not imported"
    static let reasonKeychain = "the Keychain did not take the token"
    static let reasonReadBack = "the stored token did not read back intact; not imported"
    static let reasonState = "the account list could not be saved; not imported"
    static let noteOrphan = "a Keychain item made for this import could not be deleted; it is listed nowhere"
    static let noteStateUnreadable = "the old state file could not be read; cooldowns were not carried"

    // MARK: Read

    /// QA #739 INFO-6: a vault label that fails the label rule is never shown or logged; the
    /// entry's place in the vault stands in for it.
    static func shownLabel(_ label: String, at index: Int) -> String {
        CCPoolStore.labelProblem(label) == nil ? label : "entry \(index + 1) (unusable label)"
    }

    /// Labels and tokens in vault order (the Python pick order breaks ties by it).
    private static func readVault(_ url: URL) throws -> [(label: String, token: String?)] {
        guard let data = try? Data(contentsOf: url) else { throw ReadError.unreadable }
        // OrderedJSON keeps the key order; its errors carry a line number and a reason, no content.
        guard let doc = try? OrderedJSON(bytes: Array(data)) else { throw ReadError.notJSON }
        guard case .object(let accounts)? = doc.node(at: ["accounts"])?.value else { throw ReadError.noAccounts }
        return accounts.map { m -> (label: String, token: String?) in
            guard case .object(let fields) = m.value.value,
                  case .string(let t)? = fields.first(where: { $0.key == "token" })?.value.value else { return (m.key, nil) }
            return (m.key, t.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    struct Carried {
        var current: String?
        var accounts: [String: (cooldown: [String: Int], reset: [String: Int])]
    }

    /// The Python state, or nil when there is none or it does not decode.
    static func readState(_ url: URL) -> Carried? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func epochs(_ any: Any?) -> [String: Int] {
            ((any as? [String: Any]) ?? [:]).compactMapValues { v in
                guard let d = (v as? NSNumber)?.doubleValue, d.isFinite, abs(d) < 1e12 else { return nil }
                return Int(d)
            }
        }
        var out = Carried(current: obj["current"] as? String, accounts: [:])
        for (label, rec) in (obj["accounts"] as? [String: Any]) ?? [:] {
            let r = rec as? [String: Any]
            out.accounts[label] = (epochs(r?["cooldown"]), epochs(r?["reset"]))
        }
        return out
    }

    // MARK: Import

    /// QA #751 INFO-6: at the Trash click, the vault again: every entry a valid label whose token
    /// the pool holds under it. Compared in memory; false when the vault cannot be read.
    static func allHeld(vault: URL, store: CCPoolStore, secrets: CCPoolSecrets) -> Bool {
        guard let entries = try? readVault(vault) else { return false }
        return entries.allSatisfy { label, token in
            guard CCPoolStore.labelProblem(label) == nil, let token, !token.isEmpty,
                  let id = store.read({ $0.accounts[label]?.id }) else { return false }
            return ((try? secrets.token(id: id)) ?? nil) == token
        }
    }

    /// Reads the vault for its labels only. Nothing is written.
    static func inspect(vault: URL, store: CCPoolStore) throws -> Plan {
        let labels = try readVault(vault).map(\.label)
        let have = store.read { Set($0.accounts.keys) }
        return Plan(labels: labels.enumerated().map { shownLabel($1, at: $0) },
                    conflicts: labels.filter { CCPoolStore.labelProblem($0) == nil && have.contains($0) })
    }

    private enum Step { case added, replaced(old: String), conflict }

    /// Import every vault account. A label the pool already has is replaced or skipped per
    /// `choices`; with no choice it is reported back in `undecided` and left alone.
    static func run(vault: URL, store: CCPoolStore, secrets: CCPoolSecrets,
                    choices: [String: Choice], now: Double) throws -> Outcome {
        let entries = try readVault(vault)
        let stateURL = stateURL(vault: vault)
        let carried = readState(stateURL)
        var out = Outcome()
        out.vaultLink = try? FileManager.default.destinationOfSymbolicLink(atPath: vault.path)
        if carried == nil, FileManager.default.fileExists(atPath: stateURL.path) { out.notes.append(noteStateUnreadable) }
        /// A label left as it is: does the pool already hold this very token? Compared in memory.
        func checkHeld(_ label: String, _ token: String) {
            let id = store.read { $0.accounts[label]?.id }
            let have = id.flatMap { (try? secrets.token(id: $0)) ?? nil }
            if have != token { out.notHeld.append(label) }
        }
        /// QA #751 INFO-5: a new item this import made and could not delete again is named, label only.
        func dropNew(_ id: String, _ label: String) {
            do { try secrets.remove(id: id) } catch {
                store.logger.note(label, "import undone; its new Keychain item could not be deleted")
                out.notes.append("\(label): \(noteOrphan)")
            }
        }

        for (i, (label, token)) in entries.enumerated() {
            if let problem = CCPoolStore.labelProblem(label) {
                out.failures.append(Failure(label: shownLabel(label, at: i),
                                            reason: problem == .emptyLabel ? reasonEmptyLabel : reasonBadLabel))
                continue
            }
            guard let token, !token.isEmpty else {
                out.failures.append(Failure(label: label, reason: reasonNoToken))
                continue
            }
            if store.read({ $0.accounts[label] != nil }) {
                switch choices[label] {
                case nil: out.undecided.append(label); checkHeld(label, token); continue
                case .skip?: out.skipped.append(label); checkHeld(label, token); continue
                case .replace?: break
                }
            }
            // A fresh id: a replaced account keeps its old item until the new one is proven.
            let id = UUID().uuidString
            do { try secrets.store(token: token, id: id, label: label) } catch {
                try? secrets.remove(id: id)
                out.failures.append(Failure(label: label, reason: reasonKeychain))
                continue
            }
            // Read back and compare lengths in memory; nothing is printed.
            let back = (try? secrets.token(id: id)) ?? nil
            guard back?.utf8.count == token.utf8.count else {
                dropNew(id, label)
                out.failures.append(Failure(label: label, reason: reasonReadBack))
                continue
            }
            let (step, saved) = store.mutateOrUndo { st -> Step in
                let old = st.accounts[label]
                // Decided under the lock: a label that appeared since the check still asks.
                if old != nil, choices[label] != .replace { return .conflict }
                // QA #751 INFO-2: a Replace is a new token, maybe another subscription: the old token's
                // benches and resets go. A hand hold (`held`, set only by Hold) is the user's choice
                // for the label and stays, to its own end.
                let hold = old?.held.flatMap { Double($0) > now ? $0 : nil }
                st.accounts[label] = CCPoolState.Account(id: id, cooldown: hold.map { [CCPoolCore.fiveHour: $0] } ?? [:],
                                                         held: hold)
                if old == nil { st.order.append(label) }
                if let c = carried?.accounts[label] {
                    for (claim, until) in c.cooldown where Double(until) > now {
                        st.bench(label, claim: claim, until: until, now: now)   // capped at 8 days (B3)
                    }
                    let fresh = c.reset.filter { Double($0.value) > now }
                    if !fresh.isEmpty { st.accounts[label]?.reset = fresh }
                }
                return old.map { Step.replaced(old: $0.id) } ?? .added
            }
            switch (step, saved) {
            case (.conflict, _):
                dropNew(id, label)
                out.undecided.append(label)
                checkHeld(label, token)
            case (_, false):
                dropNew(id, label)
                out.failures.append(Failure(label: label, reason: reasonState))
            case (.added, true):
                out.imported.append(label)
            case (.replaced(let old), true):
                // QA #739 F2: the old token's usage is not the new one's.
                store.forgetUsage(label)
                do { try secrets.remove(id: old) } catch {
                    // QA #739 INFO-5: label only, kept private by the live logger.
                    store.logger.note(label, "replaced; the old Keychain item could not be deleted")
                    out.notes.append("\(label): the replaced token's Keychain item could not be deleted; it is listed nowhere")
                }
                out.retiredIDs.append(old)
                out.replaced.append(label)
            }
        }
        // `current` carries when the pool has none of its own yet.
        if let cur = carried?.current {
            store.mutate { st in
                if st.accounts[cur] != nil, st.current.map({ st.accounts[$0] == nil }) ?? true { st.current = cur }
            }
        }
        return out
    }
}
