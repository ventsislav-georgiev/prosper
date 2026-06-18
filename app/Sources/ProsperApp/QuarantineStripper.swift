import AppKit

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
        let bundlePath = Bundle.main.bundlePath
        // Only meaningful for an installed `.app`; skip the dev binary path.
        guard bundlePath.hasSuffix(".app") else { return }

        DispatchQueue.global(qos: .utility).async {
            guard hasQuarantine(at: bundlePath) else { return }
            run(["/usr/bin/xattr", "-dr", attribute, bundlePath])
        }
    }

    private static func hasQuarantine(at path: String) -> Bool {
        // `xattr -p` exits non-zero when the attribute is absent.
        run(["/usr/bin/xattr", "-p", attribute, path], quiet: true) == 0
    }

    @discardableResult
    private static func run(_ args: [String], quiet: Bool = false) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: args[0])
        proc.arguments = Array(args.dropFirst())
        if quiet {
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
        }
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }
}
