import AppKit

/// `prosper agent` CLI: run a prompt against the coding agent in the main app.
///
///   ProsperApp agent [--cwd <dir>] <prompt…>
///
/// The invoking process never runs the model — it queues the prompt for the
/// running app instance and exits. Transport is a file inbox
/// (`~/.config/prosper/agent-inbox/*.json`, timestamp-ordered names) plus a
/// distributed-notification kick: files survive the app not running yet (the
/// inbox is drained at launch) and repeated invocations queue in order. Each
/// queued prompt runs in its OWN agent session, strictly after the previous one
/// finishes, and lands in the chat window's history menu like any other session
/// (see `AgentController.drainCLIInbox`).
enum AgentCLI {

    static let notificationName = Notification.Name("com.prosper.agent.cli")

    /// Tests point the inbox at a temp dir.
    nonisolated(unsafe) static var inboxOverride: URL?

    static var inboxURL: URL {
        inboxOverride
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".config/prosper/agent-inbox", isDirectory: true)
    }

    struct Job: Codable, Equatable {
        var prompt: String
        var cwd: String?
    }

    // MARK: - CLI process side

    /// Handle an `agent` subcommand and exit; returns (without side effects) when
    /// the process was started normally. Called from main.swift before the
    /// single-instance guard, so `prosper agent …` works while the app runs.
    static func runIfRequested() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "agent" else { return }
        args.removeFirst()
        var cwd: String?
        if let i = args.firstIndex(of: "--cwd") {
            guard i + 1 < args.count else {
                FileHandle.standardError.write(Data("usage: prosper agent [--cwd <dir>] <prompt…>\n".utf8))
                exit(2)
            }
            // Resolve symlinks up front: the cwd becomes the agent sandbox's
            // writable root, so it must point where the user thinks it points.
            let resolved = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
                .resolvingSymlinksInPath().path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
                FileHandle.standardError.write(Data("prosper: --cwd is not a directory: \(resolved)\n".utf8))
                exit(2)
            }
            cwd = resolved
            args.removeSubrange(i...(i + 1))
        }
        let prompt = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            FileHandle.standardError.write(Data("usage: prosper agent [--cwd <dir>] <prompt…>\n".utf8))
            exit(2)
        }
        do {
            try enqueue(Job(prompt: prompt, cwd: cwd))
        } catch {
            FileHandle.standardError.write(Data("prosper: failed to queue prompt: \(error.localizedDescription)\n".utf8))
            exit(1)
        }

        let bundleId = Bundle.main.bundleIdentifier
        let running = bundleId.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
                .contains { $0 != .current && !$0.isTerminated }
        } ?? false
        if running || bundleId == nil {
            // Kick the live instance (dev bare-binary runs always kick: the file
            // inbox makes a missed kick harmless — drained on next launch).
            DistributedNotificationCenter.default().postNotificationName(
                notificationName, object: nil, userInfo: nil, deliverImmediately: true)
        } else {
            // App not running: launch it; the inbox is drained at startup.
            let sema = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in sema.signal() }
            _ = sema.wait(timeout: .now() + 10)
        }
        print("prosper: queued agent prompt (\(prompt.count) chars)\(cwd.map { " in \($0)" } ?? "")")
        exit(0)
    }

    static func enqueue(_ job: Job) throws {
        let dir = inboxURL
        // Inbox files trigger workspace-write agent runs, so they are an attack
        // surface for any same-user process: keep the dir owner-only and the files
        // 0600 (takeInbox rejects anything looser or foreign-owned).
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        // Microsecond timestamp prefix keeps lexicographic order == submit order
        // (separate process invocations cannot realistically tie at µs scale).
        let us = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let name = String(format: "%018llu-%@.json", us, UUID().uuidString)
        let url = dir.appendingPathComponent(name)
        try JSONEncoder().encode(job).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - App side

    /// Install the notification listener and drain anything queued while the app
    /// was down. Call once from `applicationDidFinishLaunching`.
    @MainActor
    static func observeAndDrain() {
        DistributedNotificationCenter.default().addObserver(
            forName: notificationName, object: nil, queue: .main
        ) { _ in
            // Not assumeIsolated: traps if delivery ever leaves the main executor.
            Task { @MainActor in AgentController.shared.drainCLIInbox() }
        }
        AgentController.shared.drainCLIInbox()
    }

    /// Read + remove all queued jobs, in submit order. Junk (undecodable, empty,
    /// foreign-owned, or loose-permission) files are deleted and skipped; a file
    /// whose READ transiently fails is left for the next drain.
    static func takeInbox() -> [Job] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: inboxURL.path) else { return [] }
        var jobs: [Job] = []
        for name in names.filter({ $0.hasSuffix(".json") }).sorted() {
            let url = inboxURL.appendingPathComponent(name)
            // Jobs run the workspace-write agent: accept only files we wrote
            // ourselves — owned by this uid and not group/other-accessible.
            let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            let owner = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
            guard owner == getuid(), perms & 0o077 == 0 else {
                try? fm.removeItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }   // transient — retry next drain
            if let job = try? JSONDecoder().decode(Job.self, from: data),
               !job.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                jobs.append(job)
            }
            try? fm.removeItem(at: url)
        }
        return jobs
    }
}
