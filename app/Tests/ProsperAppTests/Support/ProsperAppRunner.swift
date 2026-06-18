#if canImport(WebKit)
import AppKit
import XCTest

/// Launches the REAL Prosper app from source (`.build/<cfg>/ProsperApp`, built by
/// scripts/e2e.sh) for true end-to-end tests. The running app installs its own
/// keystroke tap, so expansion + inline autocomplete are exercised exactly as a
/// user would hit them — no in-process stubs.
///
/// Safety + speed:
///  - Isolated throwaway HOME → the app reads/writes a temp `~/.config/prosper`,
///    so it CANNOT touch your real snippets or the installed app's data.
///  - Auto-update OFF (`-automaticUpdateChecks NO`) so the dev build can't
///    Sparkle-replace itself with the official build mid-test.
///  - The model cache (`~/.config/prosper/hf`) is symlinked to your real one, so
///    the real model loads without a multi-GB download.
///
/// `nonisolated` so suites can stop it from the nonisolated tearDown override.
final class ProsperAppRunner: @unchecked Sendable {   // mutable state guarded by `lock`
    struct Snippet { let name: String; let keyword: String; let text: String }

    private var process: Process?
    private var home: URL?
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var sawReady = false
    private(set) var accessibilityTrusted = false
    private(set) var tapLive = false

    static func binaryURL() -> URL {
        Bundle(for: ProsperAppRunner.self).bundleURL   // …/debug/ProsperPackageTests.xctest
            .deletingLastPathComponent()               // …/debug
            .appendingPathComponent("ProsperApp")
    }

    /// Launches the app with the given snippets seeded. Returns `tapLive` — false
    /// means the dev binary wasn't granted Accessibility (its tap never came up);
    /// the caller should skip with a clear reason. Throws/skips if not built.
    @discardableResult
    func launch(snippets: [Snippet], timeout: TimeInterval = 90) throws -> Bool {
        let fm = FileManager.default
        let bin = Self.binaryURL()
        try XCTSkipUnless(fm.isExecutableFile(atPath: bin.path),
                          "ProsperApp not built at \(bin.path); run scripts/e2e.sh (swift build) first.")

        // Isolated HOME with a seeded config; share the real model cache via symlink.
        let home = fm.temporaryDirectory.appendingPathComponent("prosper-e2e-\(UUID().uuidString)", isDirectory: true)
        let cfg = home.appendingPathComponent(".config/prosper", isDirectory: true)
        try fm.createDirectory(at: cfg, withIntermediateDirectories: true)
        self.home = home

        let realHF = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config/prosper/hf")
        if fm.fileExists(atPath: realHF.path) {
            try? fm.createSymbolicLink(at: cfg.appendingPathComponent("hf"), withDestinationURL: realHF)
        } else {
            FileHandle.standardError.write(Data("[prosper-runner] WARNING: no model cache at \(realHF.path); the model may download.\n".utf8))
        }

        try seedSnippets(snippets, into: cfg)

        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        // macOS resolves homeDirectoryForCurrentUser / UserDefaults via getpwuid +
        // cfprefsd, both ignoring $HOME — so the app needs this explicit override to
        // isolate its config (snippets.json + UserDefaults mirror). See E2EConfig.
        env["PROSPER_HOME"] = home.path
        env["PROSPER_E2E"] = "1"

        let p = Process()
        p.executableURL = bin
        p.environment = env
        // Argument domain (highest-priority UserDefaults) seeds the prefs that gate
        // the tap, expansion, and auto-update.
        p.arguments = [
            "-onboardingCompleted", "YES",
            "-automaticUpdateChecks", "NO",
            "-autocompleteEnabled", "YES",         // installs the keystroke tap (snippets ride on it)
            "-snippetsEnabled", "YES",
            "-snippetsAutoExpand", "YES",
            "-snippetsExpandOnWordBoundary", "NO",
            "-snippetsRestoreClipboard", "YES",
            // Use the clipboard-paste insertion path for the E2EHost field. The default
            // `typeString` posts a single keycode-0 + keyboardSetUnicodeString CGEvent;
            // a minimal NSTextView routes that through TSM, which re-translates by
            // keycode and drops the attached unicode string, so nothing inserts. The
            // compat path (⌘V) inserts deterministically — a real Prosper insertion path.
            "-improveCompatBundleIds", "(\"com.prosper.e2ehost\")",
        ]
        let pipe = Pipe()
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            FileHandle.standardError.write(Data(s.split(separator: "\n", omittingEmptySubsequences: true)
                .map { "[prosper] \($0)\n" }.joined().utf8))
            self?.scanForReady(s)
        }
        try p.run()
        process = p

        if ready.wait(timeout: .now() + timeout) == .timedOut {
            FileHandle.standardError.write(Data("[prosper-runner] timed out waiting for PROSPER_E2E_READY.\n".utf8))
        }
        return tapLive
    }

    private func scanForReady(_ chunk: String) {
        guard chunk.contains("PROSPER_E2E_READY") else { return }
        for line in chunk.split(separator: "\n") where line.contains("PROSPER_E2E_READY") {
            lock.lock()
            accessibilityTrusted = line.contains("accessibility=true")
            tapLive = line.contains("tap=true")
            if !sawReady { sawReady = true; ready.signal() }
            lock.unlock()
        }
    }

    private func seedSnippets(_ snippets: [Snippet], into cfg: URL) throws {
        // Matches SnippetStore.Document / Entry on-disk shape; bootstrap() imports it.
        let entries = snippets.map { ["name": $0.name, "keyword": $0.keyword, "text": $0.text] }
        let doc: [String: Any] = ["version": 1, "snippets": entries]
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted])
        try data.write(to: cfg.appendingPathComponent("snippets.json"))
    }

    func stop() {
        if let p = process {
            process = nil
            (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        if let home { try? FileManager.default.removeItem(at: home); self.home = nil }
    }
}
#endif
