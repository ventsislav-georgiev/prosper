import Darwin
import Foundation
import os.log

/// #871 log seam, category `ccpool`. Callers pass labels, claims and statuses only: never a header,
/// never a token, at most 200 bytes of an upstream error body. The label is a separate argument so
/// the live logger can keep it private (a label may be an email, errata C6).
protocol CCPoolLogger: Sendable {
    func note(_ label: String?, _ message: String)
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
}

enum CCPoolStoreError: Error, Equatable, CustomStringConvertible {
    case emptyLabel, duplicateLabel, emptyToken, noSuchAccount

    var description: String {
        switch self {
        case .emptyLabel: return "ccpool: an account needs a label"
        case .duplicateLabel: return "ccpool: an account with that label already exists"
        case .emptyToken: return "ccpool: empty token, nothing stored"
        case .noSuchAccount: return "ccpool: no such account"
        }
    }
}

/// The pool's state, shared by the proxy and (later) Settings. Thread-safe; every change that alters
/// the state is written to `state.json` (0600, directory 0700) before the call returns. The file
/// never holds a token: tokens go through `CCPoolSecrets` under the account's opaque id.
final class CCPoolStore: @unchecked Sendable {
    let directory: URL
    let clock: @Sendable () -> Double
    let logger: CCPoolLogger
    private let lock = NSLock()
    private var state: CCPoolState

    /// Production default: ~/Library/Application Support/Prosper/ccpool. P1 has no caller.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Prosper/ccpool", isDirectory: true)
    }

    var stateURL: URL { directory.appendingPathComponent("state.json") }

    init(directory: URL, clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
         logger: CCPoolLogger = CCPoolOSLog()) {
        self.directory = directory
        self.clock = clock
        self.logger = logger
        let url = directory.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url) else { state = CCPoolState(); return }
        if let decoded = try? JSONDecoder().decode(CCPoolState.self, from: data) {
            state = decoded
            return
        }
        // N1: an undecodable file is moved aside, never overwritten: it lists the accounts whose
        // Keychain items would otherwise be orphaned.
        state = CCPoolState()
        let aside = directory.appendingPathComponent("state.json.corrupt-\(Int(clock()))")
        let moved = rename(url.path, aside.path) == 0
        logger.note(nil, moved ? "state file did not decode; moved aside, starting empty"
                               : "state file did not decode and could not be moved aside")
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
                if !persist(next) { logger.note(nil, "state write failed") }
            }
            return out
        }
    }

    // MARK: Accounts

    /// Store the token under a fresh opaque id, then list the account. Nothing is stored on error.
    func addAccount(label: String, token: String, secrets: CCPoolSecrets) throws {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { throw CCPoolStoreError.emptyLabel }
        guard !token.isEmpty else { throw CCPoolStoreError.emptyToken }
        guard read({ $0.accounts[label] == nil }) else { throw CCPoolStoreError.duplicateLabel }
        let id = UUID().uuidString
        try secrets.store(token: token, id: id, label: label)
        // N2: the label is decided under the lock; a racing add of the same label wins, ours is undone.
        let added = mutate { st -> Bool in
            guard st.accounts[label] == nil else { return false }
            st.accounts[label] = CCPoolState.Account(id: id)
            st.order.append(label)
            return true
        }
        if !added {
            try? secrets.remove(id: id)
            throw CCPoolStoreError.duplicateLabel
        }
    }

    func removeAccount(label: String, secrets: CCPoolSecrets) throws {
        guard let id = read({ $0.accounts[label]?.id }) else { throw CCPoolStoreError.noSuchAccount }
        try secrets.remove(id: id)
        mutate { st in
            st.accounts.removeValue(forKey: label)
            st.order.removeAll { $0 == label }
            if st.current == label { st.current = nil }
        }
    }

    // MARK: File

    /// Atomic replace: write a 0600 temp file, fsync, rename over state.json.
    private func persist(_ st: CCPoolState) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(st) else { return false }
        let dir = directory.path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let tmp = directory.appendingPathComponent(".state.json.\(UUID().uuidString.prefix(8)).tmp").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        let ok = data.withUnsafeBytes { buf in write(fd, buf.baseAddress, buf.count) == buf.count } && fsync(fd) == 0
        close(fd)
        if !ok || rename(tmp, stateURL.path) != 0 {
            unlink(tmp)
            return false
        }
        return true
    }
}
