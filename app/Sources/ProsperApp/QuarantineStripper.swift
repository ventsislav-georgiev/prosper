import AppKit
import os
import ProsperHelperProtocol

/// Removes the `com.apple.quarantine` extended attribute from the app's own
/// bundle at launch.
///
/// Why: Prosper ships ad-hoc signed (not Apple-notarized), so a freshly
/// downloaded build — and every Sparkle auto-update archive — arrives with the
/// quarantine flag set. macOS Gatekeeper shows the "unidentified developer /
/// app is damaged" dialog for quarantined, un-notarized apps.
///
/// Stripping our own quarantine flag on launch means: after the *first* manual
/// launch (right-click → Open, or the one-line `xattr` from the README), every
/// subsequent launch — including the relaunch Sparkle performs after installing
/// an update — is clean and prompt-free. It cannot bypass the very first launch
/// (the app must run before this code can execute), which is why the README
/// documents the one-time manual step.
///
/// This is a no-op when there is no quarantine flag (e.g. running from
/// `.build`, or already stripped), and never blocks launch.
enum QuarantineStripper {
    static let attribute = "com.apple.quarantine"
    /// A hung /usr/bin/xattr must not hold registerLock forever.
    static let xattrTimeout: TimeInterval = 10
    private static let log = Logger(subsystem: "eu.illegible.prosper", category: "quarantine")

    enum Outcome: Equatable {
        case notNeeded, stripped, failed(String), timedOut
        var isClean: Bool { self == .notNeeded || self == .stripped }
    }

    /// Strip the quarantine xattr from this app bundle, recursively, off the
    /// main thread. Safe to call unconditionally on every launch.
    static func stripSelf() {
        DispatchQueue.global(qos: .utility).async { _ = outcome }
    }

    /// Blocks until the strip has finished, running it now if launch hasn't yet.
    /// OFF-MAIN ONLY. Every SMAppService.daemon register calls this first: launchd
    /// on macOS 27 refuses to load a daemon plist that carries the quarantine
    /// xattr, and the async launch strip could otherwise still be running.
    /// Returns the strip outcome; never blocks longer than `xattrTimeout`.
    @discardableResult
    static func waitForStrip() -> Outcome { outcome }

    /// Runs once per process. A Swift static let is initialized under swift_once,
    /// so a concurrent caller blocks until the first one finishes. A full recursive
    /// xattr read of the ~400-file bundle takes about 0.1 s.
    private static let outcome: Outcome = {
        let bundlePath = Bundle.main.bundlePath
        // Only meaningful for an installed `.app`; skip the dev binary path.
        guard bundlePath.hasSuffix(".app"),
              pathsToCheck(bundlePath: bundlePath).contains(where: hasQuarantine) else { return .notNeeded }
        let result = run(["/usr/bin/xattr", "-dr", attribute, bundlePath], timeout: xattrTimeout)
        if !result.isClean { log.error("quarantine strip of \(bundlePath, privacy: .public) failed: \(String(describing: result), privacy: .public)") }
        return result
    }()

    /// The bundle root plus what launchd loads for the helper daemon. A copy can
    /// leave the root clean while nested files keep the xattr, so the root alone
    /// is not a sufficient probe.
    static func pathsToCheck(bundlePath: String) -> [String] {
        [bundlePath,
         "\(bundlePath)/Contents/Library/LaunchDaemons/\(helperLabel).plist",
         "\(bundlePath)/Contents/MacOS/ProsperHelper"]
    }

    private static func hasQuarantine(at path: String) -> Bool {
        getxattr(path, attribute, nil, 0, 0, 0) >= 0
    }

    /// Runs the command, terminating it after `timeout` seconds.
    static func run(_ args: [String], timeout: TimeInterval) -> Outcome {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do {
            try proc.run()
        } catch {
            return .failed("launch: \(error.localizedDescription)")
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            proc.terminate()
            return .timedOut
        }
        return proc.terminationStatus == 0 ? .stripped : .failed("exit \(proc.terminationStatus)")
    }
}
