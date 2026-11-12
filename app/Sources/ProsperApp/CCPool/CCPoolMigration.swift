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

    /// The ONE production path rule, as the Python ccpool resolves it: `$CCPOOL_HOME/vault.json`,
    /// else `<home>/.ccpool/vault.json`. An empty variable counts as unset. Reads nothing.
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
    static let reasonKeychain = "the Keychain did not take the token"
    static let reasonReadBack = "the stored token did not read back intact; not imported"
    static let reasonState = "the account list could not be saved; not imported"
    static let noteStateUnreadable = "the old state file could not be read; cooldowns were not carried"

    // MARK: Read

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

    /// Reads the vault for its labels only. Nothing is written.
    static func inspect(vault: URL, store: CCPoolStore) throws -> Plan {
        let labels = try readVault(vault).map(\.label)
        let have = store.read { Set($0.accounts.keys) }
        return Plan(labels: labels, conflicts: labels.filter { have.contains($0) })
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
        if carried == nil, FileManager.default.fileExists(atPath: stateURL.path) { out.notes.append(noteStateUnreadable) }

        for (label, token) in entries {
            guard let token, !token.isEmpty, !label.isEmpty else {
                out.failures.append(Failure(label: label, reason: reasonNoToken))
                continue
            }
            if store.read({ $0.accounts[label] != nil }) {
                switch choices[label] {
                case nil: out.undecided.append(label); continue
                case .skip?: out.skipped.append(label); continue
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
                try? secrets.remove(id: id)
                out.failures.append(Failure(label: label, reason: reasonReadBack))
                continue
            }
            let (step, saved) = store.mutateOrUndo { st -> Step in
                let old = st.accounts[label]
                // Decided under the lock: a label that appeared since the check still asks.
                if old != nil, choices[label] != .replace { return .conflict }
                st.accounts[label] = CCPoolState.Account(id: id, cooldown: old?.cooldown ?? [:],
                                                         reset: old?.reset ?? [:], held: old?.held)
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
                try? secrets.remove(id: id)
                out.undecided.append(label)
            case (_, false):
                try? secrets.remove(id: id)
                out.failures.append(Failure(label: label, reason: reasonState))
            case (.added, true):
                out.imported.append(label)
            case (.replaced(let old), true):
                try? secrets.remove(id: old)
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
