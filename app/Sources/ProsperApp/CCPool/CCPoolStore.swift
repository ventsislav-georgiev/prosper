import Darwin
import Foundation
import os.log

/// #871 log seam, category `ccpool`. Callers pass labels, claims and statuses only: never a header,
/// never a token, at most 200 bytes of an upstream error body. The label is a separate argument so
/// the live logger can keep it private (a label may be an email, errata C6).
protocol CCPoolLogger: Sendable {
    func note(_ label: String?, _ message: String)
    /// `detail` follows `message` but stays private in the unified log (QA #733 INFO-3: a client's
    /// model string, an upstream error body).
    func note(_ label: String?, _ message: String, private detail: String)
}

extension CCPoolLogger {
    func note(_ label: String?, _ message: String, private detail: String) { note(label, message + detail) }
}

struct CCPoolOSLog: CCPoolLogger {
    private let log = Logger(subsystem: "com.prosper.app", category: "ccpool")

    func note(_ label: String?, _ message: String) {
        if let label {
            log.notice("\(label, privacy: .private): \(message, privacy: .public)")
        } else {
            log.notice("\(message, privacy: .public)")
        }
    }

    func note(_ label: String?, _ message: String, private detail: String) {
        log.notice("\(label ?? "-", privacy: .private): \(message, privacy: .public)\(detail, privacy: .private)")
    }
}

enum CCPoolStoreError: Error, Equatable, CustomStringConvertible {
    case emptyLabel, duplicateLabel, emptyToken, noSuchAccount, stateWriteFailed
    /// QA #734 INFO-4: state.json exists but could not be read; this process never writes it.
    case stateUnreadable

    var description: String {
        switch self {
        case .emptyLabel: return "ccpool: an account needs a label"
        case .duplicateLabel: return "ccpool: an account with that label already exists"
        case .emptyToken: return "ccpool: empty token, nothing stored"
        case .noSuchAccount: return "ccpool: no such account"
        case .stateWriteFailed: return "ccpool: the account list could not be saved; nothing changed"
        case .stateUnreadable: return CCPoolStore.unreadableNote
        }
    }
}

/// P2a: the last utilisation Anthropic reported for one account, per claim, and when. Kept in
/// memory only (proxy traffic and Refresh both write it); never persisted, never a token.
struct CCPoolUsageSample: Equatable, Sendable {
    var util: [String: Double]
    var at: Double
}

/// The pool's state, shared by the proxy and Settings. Thread-safe; every change that alters the
/// state is written to `state.json` (0600, directory 0700) before the call returns. The file never
/// holds a token: tokens go through `CCPoolSecrets` under the account's opaque id.
///
/// Durability (QA #734 INFO-6): account-set changes (add, remove, rename, an import's replace) are
/// written or refused: a failed write leaves the state as it was and the caller gets the error.
/// Rotation state (benches, holds, current, resets, order) stays in memory when its write fails,
/// with a log line, and is written again with the next change that saves.
final class CCPoolStore: @unchecked Sendable {
    /// Writes the encoded state to `state.json`; false when nothing was written. A test seam.
    typealias Writer = @Sendable (_ data: Data, _ url: URL) -> Bool

    let directory: URL
    let clock: @Sendable () -> Double
    let logger: CCPoolLogger
    private let writer: Writer
    private let lock = NSLock()
    private var state: CCPoolState
    private var usage: [String: CCPoolUsageSample] = [:]
    /// Set when state.json exists but could not be read (QA #734 INFO-4): the store then starts
    /// empty in memory, never writes the file, and refuses account changes.
    let unreadable: Bool

    static let unreadableNote = "ccpool: the account list (state.json) exists but could not be read; "
        + "Prosper will not change it. Fix or move the file, then relaunch."

    /// Production default: ~/Library/Application Support/Prosper/ccpool. P1 has no caller.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Prosper/ccpool", isDirectory: true)
    }

    var stateURL: URL { directory.appendingPathComponent("state.json") }

    init(directory: URL, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
         logger: CCPoolLogger = CCPoolOSLog(), writer: @escaping Writer = CCPoolStore.atomicWrite) {
        self.directory = directory
        self.clock = clock
        self.logger = logger
        self.writer = writer
        let url = directory.appendingPathComponent("state.json")
        // Only "no such file" is the empty pool. Anything else that cannot be read (a directory in
        // its place, no permission, an I/O error) still lists accounts whose Keychain items a
        // rewrite would orphan (N1): leave it alone for the life of this process.
        var info = stat()
        if lstat(url.path, &info) != 0, errno == ENOENT || errno == ENOTDIR {
            state = CCPoolState()
            unreadable = false
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            state = CCPoolState()
            unreadable = true
            logger.note(nil, "state file exists but could not be read; left untouched, account changes refused")
            return
        }
        if let decoded = try? JSONDecoder().decode(CCPoolState.self, from: data) {
            state = decoded
            unreadable = false
            return
        }
        // N1: an undecodable file is moved aside, never overwritten: it lists the accounts whose
        // Keychain items would otherwise be orphaned. One that cannot be moved is never written.
        state = CCPoolState()
        let aside = directory.appendingPathComponent("state.json.corrupt-\(Int(clock()))")
        let moved = rename(url.path, aside.path) == 0
        unreadable = !moved
        logger.note(nil, moved ? "state file did not decode; moved aside, starting empty"
                               : "state file did not decode and could not be moved aside; left untouched, account changes refused")
    }

    var now: Double { clock() }

    func read<T>(_ body: (CCPoolState) -> T) -> T { lock.withLock { body(state) } }

    var snapshot: CCPoolState { read { $0 } }

    /// Apply `body` under the lock; write the file only when the state changed.
    @discardableResult
    func mutate<T>(_ body: (inout CCPoolState) -> T) -> T {
        lock.withLock {
            var next = state
            let out = body(&next)
            if next != state {
                state = next
                if !persist(next), !unreadable { logger.note(nil, "state write failed") }
            }
            return out
        }
    }

    /// Like `mutate`, but a change that cannot be written is undone in memory too: `saved` is false
    /// and the state is as before. For changes that pair with a Keychain write (P2a follow-up c).
    func mutateOrUndo<T>(_ body: (inout CCPoolState) -> T) -> (out: T, saved: Bool) {
        // Every account-set change comes through here (QA #734 INFO-6).
        lock.withLock {
            var next = state
            let out = body(&next)
            guard next != state else { return (out, true) }
            guard persist(next) else {
                logger.note(nil, "state write failed; change undone")
                return (out, false)
            }
            state = next
            return (out, true)
        }
    }

    // MARK: Usage (in memory)

    /// Record what a response or a probe said about `label`'s claims. Ignored without numbers.
    func recordUsage(_ label: String, limits: [String: CCPoolLimit]) {
        let util = CCPoolCore.utils(limits)
        guard !util.isEmpty else { return }
        let at = now
        lock.withLock { if state.accounts[label] != nil { usage[label] = CCPoolUsageSample(util: util, at: at) } }
    }

    func usageSample(_ label: String) -> CCPoolUsageSample? { lock.withLock { usage[label] } }

    // MARK: Accounts

    /// Why a state write failed, for callers that report it.
    private var writeFailure: CCPoolStoreError { unreadable ? .stateUnreadable : .stateWriteFailed }

    /// Store the token under a fresh opaque id, then list the account. Nothing is stored on error.
    func addAccount(label: String, token: String, secrets: CCPoolSecrets) throws {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unreadable else { throw CCPoolStoreError.stateUnreadable }
        guard !label.isEmpty else { throw CCPoolStoreError.emptyLabel }
        guard !token.isEmpty else { throw CCPoolStoreError.emptyToken }
        guard read({ $0.accounts[label] == nil }) else { throw CCPoolStoreError.duplicateLabel }
        let id = UUID().uuidString
        try secrets.store(token: token, id: id, label: label)
        // N2: the label is decided under the lock; a racing add of the same label wins, ours is undone.
        // P2a (c): the Keychain item is written first, then the state; a state that cannot be written
        // is undone in memory and the item is removed again, so no item exists that no state lists.
        let (added, saved) = mutateOrUndo { st -> Bool in
            guard st.accounts[label] == nil else { return false }
            st.accounts[label] = CCPoolState.Account(id: id)
            st.order.append(label)
            return true
        }
        if !added || !saved {
            try? secrets.remove(id: id)
            throw added ? writeFailure : CCPoolStoreError.duplicateLabel
        }
    }

    /// Returns the removed account's Keychain id (its upstream session is dropped by the service).
    @discardableResult
    /// The state change is written first: a failed write keeps both the account and its Keychain
    /// item (QA #734 INFO-6). A Keychain delete that fails after it is logged; the item stays,
    /// listed nowhere (known limit).
    func removeAccount(label: String, secrets: CCPoolSecrets) throws -> String {
        guard let id = read({ $0.accounts[label]?.id }) else { throw CCPoolStoreError.noSuchAccount }
        let (removed, saved) = mutateOrUndo { st -> Bool in
            guard st.accounts[label]?.id == id else { return false }
            st.accounts.removeValue(forKey: label)
            st.order.removeAll { $0 == label }
            if st.current == label { st.current = nil }
            return true
        }
        guard removed else { throw CCPoolStoreError.noSuchAccount }
        guard saved else { throw writeFailure }
        lock.withLock { _ = usage.removeValue(forKey: label) }
        do { try secrets.remove(id: id) } catch { logger.note(label, "removed; its Keychain item could not be deleted") }
        return id
    }

    /// Rename in place: same Keychain id (the secret is never rewritten), same pick-order slot,
    /// `current` and the usage sample follow.
    func renameAccount(_ label: String, to newLabel: String) throws {
        let to = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty else { throw CCPoolStoreError.emptyLabel }
        guard to != label else { return }
        let (outcome, saved) = mutateOrUndo { st -> CCPoolStoreError? in
            guard let acct = st.accounts[label] else { return .noSuchAccount }
            guard st.accounts[to] == nil else { return .duplicateLabel }
            st.accounts.removeValue(forKey: label)
            st.accounts[to] = acct
            st.order = st.order.map { $0 == label ? to : $0 }
            if st.current == label { st.current = to }
            return nil
        }
        if let outcome { throw outcome }
        guard saved else { throw writeFailure }
        lock.withLock { if let u = usage.removeValue(forKey: label) { usage[to] = u } }
    }

    /// Move `label` by `offset` places in the pick order (negative = up), clamped. False when it
    /// did not move.
    @discardableResult
    func moveAccount(_ label: String, by offset: Int) -> Bool {
        mutate { st in
            guard let i = st.order.firstIndex(of: label) else { return false }
            let j = max(0, min(st.order.count - 1, i + offset))
            guard j != i else { return false }
            st.order.remove(at: i)
            st.order.insert(label, at: j)
            return true
        }
    }

    // MARK: File

    private func persist(_ st: CCPoolState) -> Bool {
        if unreadable { return false }   // never over a file that could not be read (QA #734 INFO-4)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(st) else { return false }
        return writer(data, stateURL)
    }

    /// Atomic replace: write a 0600 temp file, fsync, rename over state.json.
    static let atomicWrite: Writer = { data, url in
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(atPath: directory.path, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let tmp = directory.appendingPathComponent(".state.json.\(UUID().uuidString.prefix(8)).tmp").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        let ok = data.withUnsafeBytes { buf in write(fd, buf.baseAddress, buf.count) == buf.count } && fsync(fd) == 0
        close(fd)
        if !ok || rename(tmp, url.path) != 0 {
            unlink(tmp)
            return false
        }
        return true
    }
}
