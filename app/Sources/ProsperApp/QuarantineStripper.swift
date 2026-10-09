import AppKit
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

    /// Strip the quarantine xattr from this app bundle, recursively, off the
    /// main thread. Safe to call unconditionally on every launch.
    static func stripSelf() {
        DispatchQueue.global(qos: .utility).async { _ = stripped }
    }

    /// Blocks until the strip has finished, running it now if launch hasn't yet.
    /// OFF-MAIN ONLY. Every SMAppService.daemon register calls this first: launchd
    /// on macOS 27 refuses to load a daemon plist that carries the quarantine
    /// xattr, and the async launch strip could otherwise still be running.
    static func waitForStrip() { _ = stripped }

    /// Runs once per process. A Swift static let is initialized under swift_once,
    /// so a concurrent caller blocks until the first one finishes. A full recursive
    /// xattr read of the ~400-file bundle takes about 0.1 s.
    private static let stripped: Void = {
        let bundlePath = Bundle.main.bundlePath
        // Only meaningful for an installed `.app`; skip the dev binary path.
        guard bundlePath.hasSuffix(".app"),
              pathsToCheck(bundlePath: bundlePath).contains(where: hasQuarantine) else { return }
        run(["/usr/bin/xattr", "-dr", attribute, bundlePath])
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

    @discardableResult
    private static func run(_ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }
}
