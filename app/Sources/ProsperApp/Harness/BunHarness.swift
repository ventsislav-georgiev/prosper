import Foundation
import CryptoKit
import os.log

/// Supervises the Bun "plugin host" subprocess that runs opencode JS/TS plugins and
/// bridges them to codex's lifecycle hooks (see `plugin-host/plugin-host.js`). Started at
/// app launch only when the plugins dir holds at least one plugin. codex talks to the
/// host over a unix socket via `nc -U` hook commands, so there is no Bun cold-start per
/// tool call — the 90 MB runtime is launched once and stays resident.
///
/// Bun delivery is on-demand (the base app stays slim, like the codex helper): a bundled
/// `Contents/Helpers/bun` wins, else a PATH copy for dev, else a one-time download of the
/// pinned release into Application Support.
@MainActor
final class BunHarness {
    static let shared = BunHarness()
    private let log = Logger(subsystem: "com.prosper.app", category: "BunHarness")
    private var process: Process?
    private var stderrPipe: Pipe?
    /// Set synchronously at `start()` entry so a second call during the `await`
    /// (resolveBun download / waitForEventsFile) can't spawn a second host.
    private var starting = false
    /// Re-applies the agent config when the host rewrites `.events.json` (plugins
    /// added/removed at runtime → the host reloads and the new event set must wire in).
    private var eventsWatcher: FileWatcher?

    // MARK: - Paths (nonisolated so the codex actor can read them in writeConfig)

    nonisolated static var pluginsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/prosper/plugins", isDirectory: true)
    }
    nonisolated static var socketURL: URL { pluginsDir.appendingPathComponent(".host.sock") }
    nonisolated static var eventsFileURL: URL { pluginsDir.appendingPathComponent(".events.json") }

    /// At least one non-hidden `.js/.ts/.mjs/.mts` plugin file is present.
    nonisolated static func hasPlugins() -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: pluginsDir.path)
        else { return false }
        return names.contains { !$0.hasPrefix(".") && $0.range(of: #"\.(m?[jt]s)$"#, options: .regularExpression) != nil }
    }

    /// codex events any loaded plugin handles, from the host's `.events.json`. Empty when
    /// the host isn't running yet — `writeConfig` then emits no bridge hooks (zero
    /// per-tool overhead). Subset of PreToolUse/PostToolUse/PermissionRequest.
    nonisolated static func neededEvents() -> [HookRule.Event] {
        guard let data = try? Data(contentsOf: eventsFileURL),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names.compactMap { HookRule.Event(rawValue: $0) }
    }

    /// The codex hook command that pipes the event JSON to the host over the socket and
    /// relays the decision. `nc -U` avoids re-spawning Bun per call.
    nonisolated static func bridgeCommand() -> String {
        "exec nc -U \(MCPServer.q(socketURL.path))"
    }

    // MARK: - Lifecycle

    func start() async {
        guard process == nil, !starting, Self.hasPlugins() else { return }
        starting = true
        defer { starting = false }
        let bun: URL
        do { bun = try await Self.resolveBun() }
        catch { log.error("bun unavailable, plugins disabled: \(String(describing: error))"); return }

        guard let script = Self.resolveHostScript() else {
            log.error("plugin-host.js not found; plugins disabled")
            return
        }
        guard process == nil else { return }   // a concurrent start() may have won the await race
        // Plugins are executed as the user's own code; keep the dir owner-only so another
        // local account can't drop a plugin that runs inside our agent. 0700 = rwx user-only.
        try? FileManager.default.createDirectory(
            at: Self.pluginsDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let proc = Process()
        proc.executableURL = bun
        proc.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["PROSPER_PLUGINS_DIR"] = Self.pluginsDir.path
        env["PROSPER_PLUGIN_SOCKET"] = Self.socketURL.path
        proc.environment = env
        proc.currentDirectoryURL = Self.pluginsDir

        let stderr = Pipe()
        proc.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { [log] h in
            let d = h.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) { log.info("bun: \(s, privacy: .public)") }
        }
        // Clear `process` on exit so a later `start()` can relaunch a crashed host
        // (otherwise the `guard process == nil` wedges plugins off until app restart).
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in if self?.process == proc { self?.cleanupProcess() } }
        }
        do { try proc.run() } catch {
            log.error("failed to launch plugin host: \(String(describing: error))"); return
        }
        process = proc
        stderrPipe = stderr
        log.info("plugin host launched")

        // The host rewrites `.events.json` whenever it (re)loads plugins. Watch it so a
        // runtime plugin add/remove re-applies the agent config (wires the new event set
        // into the next codex spawn) — not just the one-shot apply below.
        if eventsWatcher == nil {
            eventsWatcher = FileWatcher(url: Self.eventsFileURL) {
                Task { @MainActor in AgentController.shared.applyAgentConfigChange() }
            }
        }

        // codex reads bridge hooks at spawn; the host writes .events.json shortly after
        // launch. Once it lands, respawn the (idle) agent harness so the bridge wires in
        // for the next run instead of waiting for an unrelated config change.
        await waitForEventsFile()
        if !Self.neededEvents().isEmpty { AgentController.shared.applyAgentConfigChange() }
    }

    /// Detach the stderr handler before dropping the process — the handler fires on the
    /// closed fd at EOF, and the `Pipe` would otherwise be released with its read source
    /// still armed. Idempotent.
    private func cleanupProcess() {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        process = nil
    }

    /// Poll briefly for the host's events file (it writes it on startup after loading
    /// plugins). ponytail: a short bounded poll beats a socket handshake for a file the
    /// host writes within tens of ms of launch.
    private func waitForEventsFile() async {
        for _ in 0..<50 {  // ~5s ceiling
            if FileManager.default.fileExists(atPath: Self.eventsFileURL.path) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func shutdown() {
        eventsWatcher?.stop()
        eventsWatcher = nil
        process?.terminationHandler = nil   // this teardown owns the exit
        process?.terminate()
        cleanupProcess()
        try? FileManager.default.removeItem(at: Self.socketURL)
    }

    // MARK: - Resolution

    private static func resolveHostScript() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/plugin-host.js")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        // Dev: explicit override, then the repo source.
        if let p = ProcessInfo.processInfo.environment["PROSPER_PLUGIN_HOST"] { return URL(fileURLWithPath: p) }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plugin-host/plugin-host.js")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    /// Bundled `Contents/Helpers/bun` → PATH → cached download → fresh download.
    /// `nonisolated` so the synchronous unzip/sign work in `downloadBun` runs off the
    /// main actor (it would otherwise freeze the UI for seconds on first plugin use).
    nonisolated private static func resolveBun() async throws -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bun")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for c in ["/opt/homebrew/bin/bun", "/usr/local/bin/bun",
                  NSHomeDirectory() + "/.bun/bin/bun"] {
            if FileManager.default.isExecutableFile(atPath: c) { return URL(fileURLWithPath: c) }
        }
        let cached = appSupportBun()
        if FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
        return try await downloadBun(to: cached)
    }

    nonisolated private static func appSupportBun() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Prosper/bun", isDirectory: false)
    }

    /// One-time download of the pinned Bun release for this arch into Application Support.
    nonisolated private static func downloadBun(to dest: URL) async throws -> URL {
        let arch = (try? archString()) ?? "aarch64"
        let asset = "bun-darwin-\(arch)"
        let url = URL(string: "https://github.com/oven-sh/bun/releases/download/\(bunVersion)/\(asset).zip")!
        let (tmpZip, _) = try await URLSession.shared.download(from: url)

        // Verify the zip against the pinned SHA-256 before we strip quarantine, ad-hoc
        // sign, and exec it — a compromised release / MITM / DNS hijack would otherwise
        // be arbitrary code execution as the user. Bump `bunSHA256` with `bunVersion`.
        let digest = SHA256.hash(data: try Data(contentsOf: tmpZip))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex == bunSHA256[arch] else {
            try? FileManager.default.removeItem(at: tmpZip)
            throw HarnessError.spawnFailed("bun download checksum mismatch (\(hex))")
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("prosper-bun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", tmpZip.path, "-d", work.path]
        try unzip.run(); unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw HarnessError.spawnFailed("unzip failed") }

        let extracted = work.appendingPathComponent("\(asset)/bun")
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: extracted, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)

        // A downloaded binary carries quarantine + no signature; strip + ad-hoc sign so
        // it execs without a Gatekeeper prompt or a kill from the hardened runtime.
        run("/usr/bin/xattr", ["-d", "com.apple.quarantine", dest.path])
        run("/usr/bin/codesign", ["--force", "--sign", "-", dest.path])
        return dest
    }

    nonisolated private static func archString() throws -> String {
        var sysinfo = utsname(); uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return machine == "arm64" ? "aarch64" : "x64"
    }

    @discardableResult
    nonisolated private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardError = Pipe(); p.standardOutput = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Pinned Bun release. Bump deliberately (the plugin host is tested against it).
    nonisolated private static let bunVersion = "bun-v1.3.14"

    /// SHA-256 of each arch's release zip (from the release's `SHASUMS256.txt`). Bump
    /// in lockstep with `bunVersion` — a stale hash fails the download closed.
    nonisolated private static let bunSHA256: [String: String] = [
        "aarch64": "d8b96221828ad6f97ac7ac0ab7e95872341af763001e8803e8267652c2652620",
        "x64": "4183df3374623e5bab315c547cfa0974533cd457d86b73b639f7a87974cd6633",
    ]
}
