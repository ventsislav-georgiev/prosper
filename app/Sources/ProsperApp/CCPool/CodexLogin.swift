import Darwin
import Foundation

/// #2008 (design #2003 section 4, "Adding a ChatGPT account"): a Codex (ChatGPT) account for the pool, by Codex's own
/// device login in a CODEX_HOME Prosper owns, or by importing an existing CODEX_HOME's auth.json (risk R1 warned first).
/// The login's auth.json is flattened (CodexCredential.flatItem), stored through CCPoolStore.addAccount (written, read
/// back, listed; undone on failure) and the scratch folder is removed on every path. Nothing logs the item or the
/// login's output: log lines carry the label and the outcome only.
enum CodexLogin {
    /// The words after the Codex command (checked against Codex 0.167.2's strings: `login`, `--device-auth`,
    /// `cli_auth_credentials_store`). #2039: the `-c` override is a top-level option, so it goes before `login`; one argv
    /// word (no shell), so it asks Codex for the file store. A managed config can still override it; that shows as "wrote no auth.json".
    static let loginArgs = ["-c", "cli_auth_credentials_store=\"file\"", "login", "--device-auth"]
    /// An auth.json is a few KB; anything above this is not one (outside data: a picked folder).
    static let maxAuthBytes = 1 << 20
    /// The login's lines kept for the pane (the code and the URL are in the first few).
    static let maxLines = 40

    /// R1: shown before an import reads anything.
    static let importWarning = "Import shares one ChatGPT login between that folder's Codex and the pool. Each refresh "
        + "replaces the login's refresh token, so the two fight over it and one side gets signed out. After the import, "
        + "delete that folder's auth.json (offered next), or sign in again there with another account."

    enum Outcome: Equatable, Sendable {
        case added(String)
        case failed(String)
        case cancelled
    }

    /// Runs one child: `argv` (the Codex command's words, then loginArgs) with `env` added to Prosper's own. Hands its
    /// own stop (SIGTERM to its pid) to `started`, streams its text to `output`, and returns the exit status, nil when
    /// it could not start. Tests inject a fake that writes a fixture auth.json into env["CODEX_HOME"].
    typealias Runner = @Sendable (_ argv: [String], _ env: [String: String],
                                  _ started: @escaping @Sendable (_ stop: @escaping @Sendable () -> Void) -> Void,
                                  _ output: @escaping @Sendable (String) -> Void) async -> Int32?

    /// The cancel of one login: a cancel before the child started stops it as soon as it starts.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var stop: (@Sendable () -> Void)?
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func cancel() {
            let s = lock.withLock { () -> (@Sendable () -> Void)? in cancelled = true; return stop }
            s?()
        }

        func started(_ s: @escaping @Sendable () -> Void) {
            let now = lock.withLock { () -> Bool in stop = s; return cancelled }
            if now { s() }
        }
    }

    /// The login's output as the pane shows it: whole lines, ANSI sequences and unseen characters dropped (OutsideText),
    /// blank lines skipped, the last maxLines kept. Fed off main; `feed` returns the lines to publish.
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var partial = ""
        private var lines: [String] = []

        func feed(_ chunk: String) -> [String] {
            lock.withLock {
                var parts = (partial + chunk).components(separatedBy: .newlines)
                partial = parts.removeLast()
                // shortcut: a partial line longer than 4 KB is cut there; the login prints short lines.
                if partial.utf8.count > 4096 { parts.append(partial); partial = "" }
                lines += parts.map(CodexLogin.shown).filter { !$0.isEmpty }
                if lines.count > CodexLogin.maxLines { lines.removeFirst(lines.count - CodexLogin.maxLines) }
                return lines + (partial.isEmpty ? [] : [CodexLogin.shown(partial)].filter { !$0.isEmpty })
            }
        }
    }

    /// One line of the login's output, shown: CSI/OSC escape sequences out, then the tree's outside-text rule.
    static func shown(_ line: String) -> String {
        let plain = line.replacingOccurrences(of: #"\x{1B}(\[[0-?]*[ -/]*[@-~]|\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)?|.)"#,
                                              with: "", options: .regularExpression)
        return OutsideText.shown(plain, max: 300).trimmingCharacters(in: .whitespaces)
    }

    /// The first https URL in a shown line, for a clickable link; nil when there is none.
    static func link(in line: String) -> URL? {
        guard let r = line.range(of: #"https://[^\s<>"']+"#, options: .regularExpression) else { return nil }
        let text = String(line[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]"))
        guard let url = URL(string: text), url.scheme == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The next free "codex-N" (N from 1), the label an empty field takes.
    static func defaultLabel(taken: Set<String>) -> String {
        var n = 1
        while taken.contains("codex-\(n)") { n += 1 }
        return "codex-\(n)"
    }

    static let alreadyRunning = "A Codex sign-in is already running."

    /// #2039: the one login of this process that is running (its scratch and its own stop), reachable by the quit hook
    /// whatever pane model started it. Set after the scratch is made, cleared on every exit of signIn.
    enum Live {
        fileprivate static let lock = NSLock()
        nonisolated(unsafe) fileprivate static var scratch: URL?
        nonisolated(unsafe) private static var stop: (@Sendable () -> Void)?

        static var isActive: Bool { lock.withLock { scratch != nil } }
        enum Claim { case taken, noFolder, ok(URL) }
        /// One lock for the slot and the sweep: refuse when taken, sweep `root`, make the scratch, store it. A sweep from
        /// elsewhere (sweep(root:) takes the same lock) can neither miss this scratch nor delete it.
        static func claim(root: URL) -> Claim {
            lock.withLock {
                if scratch != nil { return .taken }
                removeChildren(of: root)
                guard let dir = makeScratch(root: root) else { return .noFolder }
                scratch = dir; stop = nil
                return .ok(dir)
            }
        }
        static func started(_ s: @escaping @Sendable () -> Void) { lock.withLock { if scratch != nil { stop = s } } }
        static func end() { lock.withLock { scratch = nil; stop = nil } }

        /// applicationWillTerminate: SIGTERM to the live child (its own pid, through its stop), then its scratch goes.
        /// Synchronous, no wait; a no-op with no login live.
        static func terminate() {
            let (dir, s) = lock.withLock { () -> (URL?, (@Sendable () -> Void)?) in
                defer { scratch = nil; stop = nil }
                return (scratch, stop)
            }
            s?()
            if let dir { try? FileManager.default.removeItem(at: dir) }
        }
    }

    /// #2039: removes every child of `root` (stale scratch folders of a quit or crash, with whatever they hold) unless a
    /// login of this process is live (it keeps its scratch: the sweep is skipped while busy). A symlink child is
    /// unlinked, never followed; a `root` that is not a plain folder is left alone. Run off main.
    static func sweep(root: URL) {
        Live.lock.withLock { if Live.scratch == nil { removeChildren(of: root) } }
    }

    /// The sweep's body, for callers already holding Live's lock (NSLock is not recursive).
    private static func removeChildren(of root: URL) {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: root.path))?[.type] as? FileAttributeType == .typeDirectory,
              let names = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for name in names { try? fm.removeItem(atPath: root.appendingPathComponent(name).path) }
    }

    /// A fresh 0700 folder under `root` (Prosper's own support folder, never ~/.codex); nil when it cannot be made.
    static func makeScratch(root: URL) -> URL? {
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])) != nil,
              mkdir(dir.path, 0o700) == 0 else { return nil }
        return dir
    }

    /// The device login: scratch CODEX_HOME, `<codex> login --device-auth` through `runner`, then auth.json to the pool.
    /// Every path that adds nothing leaves no item, no account and no scratch folder.
    static func signIn(label: String, command: [String], scratchRoot: URL, store: CCPoolStore, secrets: CCPoolSecrets,
                       logger: CCPoolLogger, runner: Runner, handle: Handle,
                       output: @escaping @Sendable (String) -> Void) async -> Outcome {
        if let why = labelRefusal(label, store: store) { return .failed(why) }
        guard !command.isEmpty else { return .failed("No Codex command is set.") }
        let scratch: URL
        switch Live.claim(root: scratchRoot) {
        case .taken: return .failed(alreadyRunning)
        case .noFolder: return .failed("Could not make a private folder for the login.")
        case .ok(let dir): scratch = dir
        }
        defer { Live.end(); try? FileManager.default.removeItem(at: scratch) }
        let status = await runner(command + loginArgs, ["CODEX_HOME": scratch.path], { s in Live.started(s); handle.started(s) },
                                  output)
        if handle.isCancelled {
            logger.note(label, "codex login cancelled; nothing added")
            return .cancelled
        }
        guard let status else { return .failed("Codex could not be started; nothing added.") }
        guard status == 0 else {
            logger.note(label, "codex login exited \(status); nothing added")
            return .failed("Codex login ended with status \(status); nothing added.")
        }
        guard let data = readAuth(scratch) else { return .failed("Codex wrote no auth.json; nothing added.") }
        return add(label: label, authJSON: data, store: store, secrets: secrets, logger: logger)
    }

    /// Import: `folder`'s auth.json to the pool. The folder's file is left as it is (deleteAuth is a separate click).
    static func importFolder(_ folder: URL, label: String, store: CCPoolStore, secrets: CCPoolSecrets,
                             logger: CCPoolLogger) -> Outcome {
        if let why = labelRefusal(label, store: store) { return .failed(why) }
        guard let data = readAuth(folder) else { return .failed("No readable auth.json in that folder; nothing added.") }
        return add(label: label, authJSON: data, store: store, secrets: secrets, logger: logger)
    }

    /// Removes `folder`/auth.json and nothing else: unlink never removes a folder, and a link goes, not its target.
    static func deleteAuth(in folder: URL) -> Bool {
        unlink(folder.appendingPathComponent("auth.json").path) == 0
    }

    /// The Claude add's checks (CCPoolPaneModel.add), before any child runs or any file is read.
    private static func labelRefusal(_ label: String, store: CCPoolStore) -> String? {
        if let problem = CCPoolStore.labelProblem(label) { return problem.description }
        guard !store.unreadable else { return CCPoolStoreError.stateUnreadable.description }
        guard store.read({ $0.accounts[label] == nil }) else { return CCPoolStoreError.duplicateLabel.description }
        return nil
    }

    /// A regular auth.json of at most maxAuthBytes; nil otherwise.
    private static func readAuth(_ folder: URL) -> Data? {
        let url = folder.appendingPathComponent("auth.json")
        guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true,
              let size = v.fileSize, size <= maxAuthBytes else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func add(label: String, authJSON: Data, store: CCPoolStore, secrets: CCPoolSecrets,
                            logger: CCPoolLogger) -> Outcome {
        guard let item = CodexCredential.flatItem(fromAuthJSON: authJSON) else {
            return .failed("That auth.json holds no ChatGPT login (no tokens); nothing added.")
        }
        do {
            try store.addAccount(label: label, token: item, secrets: secrets, harness: CCPoolCodexHarness.id,
                                 kind: CCPoolCodexHarness.chatgptKind)
        } catch let e as CCPoolStoreError {
            return .failed(e.description)
        } catch let e as CCPoolSecretsError {
            return .failed("ccpool: \(e.description)")
        } catch {
            return .failed("ccpool: the account could not be stored")
        }
        logger.note(label, "codex account added")
        return .added(label)
    }

    // MARK: Production seams

    /// The real child: `/usr/bin/env <argv>` with the login PATH (LoginPath, the one New session's spawns get), off main.
    static let processRunner: Runner = { argv, extra, started, output in
        guard NSClassFromString("XCTestCase") == nil else { return nil }   // tests inject a fake: never a real codex
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LoginPath.path(login: LoginPath.read(), process: env["PATH"] ?? "", home: env["HOME"] ?? NSHomeDirectory())
        env.merge(extra) { _, new in new }
        let child = Child()
        return await withCheckedContinuation { cont in
            child.start(argv: argv, env: env, output: output, done: { cont.resume(returning: $0) })
            if let pid = child.pid { started { child.stop(pid) } }
        }
    }

    /// The Process behind processRunner; its terminate signals the child's own pid only.
    private final class Child: @unchecked Sendable {
        private let proc = Process()
        private let lock = NSLock()
        private var exited = false
        private(set) var pid: pid_t?

        func start(argv: [String], env: [String: String], output: @escaping @Sendable (String) -> Void,
                   done: @escaping @Sendable (Int32?) -> Void) {
            let pipe = Pipe()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = argv
            proc.environment = env
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = pipe
            proc.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { output(String(decoding: d, as: UTF8.self)) }
            }
            proc.terminationHandler = { [weak self] p in
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.lock.withLock { self?.exited = true }
                done(p.terminationStatus)
            }
            do {
                try proc.run()
                pid = proc.processIdentifier
            } catch {
                proc.terminationHandler = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                done(nil)
            }
        }

        /// SIGTERM to the child's own pid, only while it has not exited (a reaped pid may be another process's).
        func stop(_ pid: pid_t) {
            lock.withLock { if !exited { kill(pid, SIGTERM) } }
        }
    }
}
