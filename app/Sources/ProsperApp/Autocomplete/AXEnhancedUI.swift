import AppKit
import ApplicationServices

/// Per-app, opt-in force-enable of the Accessibility attributes that unlock rich
/// caret geometry in apps that otherwise hide it from assistive tooling.
///
/// Two attributes matter:
/// - `AXEnhancedUserInterface` — the AppKit-wide switch VoiceOver sets to make an
///   app expose its full accessibility tree. Some Cocoa apps only report usable
///   `kAXBoundsForRange` caret rects once this is on. **It can change app layout /
///   behavior**, so it is OPT-IN per app (`AppOverrideResolver.forceEnhancedUI ==
///   true`) and is never set globally.
/// - `AXManualAccessibility` — the Chromium/Electron equivalent. Chromium ships
///   its accessibility tree lazily and only materializes it (including text-marker
///   caret geometry) once a client sets this attribute on the app element. Setting
///   it is the documented way to ask Chrome/Electron to turn its a11y tree on.
///
/// Both writes are idempotent and cached per-pid for the lifetime of the process
/// (and per-bundleId across pid recycles), so the unlock happens once per app
/// rather than on every keystroke. A successful enable also records a per-bundleId
/// "enhanced UI helped" feedback signal (see `recordCaretOutcome`) that a future
/// Settings hint can surface.
///
/// All calls touch AX, which is main-thread only; the type is `@MainActor`.
@MainActor
enum AXEnhancedUI {

    /// Pids we've already attempted to enable, so we never re-set the attributes
    /// on the hot path. A pid lands here after the first `enableIfNeeded` call,
    /// whether or not the writes succeeded — retrying every keystroke would be
    /// pointless churn (a refusing app keeps refusing).
    private static var enabledPids: Set<pid_t> = []

    /// Bundle ids we've enabled at least once, used to scope the
    /// `recordCaretOutcome` feedback to apps we actually tried to unlock.
    private static var enabledBundleIds: Set<String> = []

    /// Force-enables the enhanced-UI / manual-accessibility attributes on the
    /// frontmost app, once per pid. Resolves the pid from the supplied running
    /// application, builds its application-level `AXUIElement` via
    /// `AXUIElementCreateApplication`, and sets both attributes to `true`.
    ///
    /// Idempotent and cheap after the first call: a cached pid short-circuits
    /// immediately. Returns `true` when an enable was performed *this* call (the
    /// first time for a pid), `false` when it was already enabled / no pid.
    @discardableResult
    static func enableIfNeeded(for app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        let pid = app.processIdentifier
        guard pid > 0, !enabledPids.contains(pid) else { return false }
        enabledPids.insert(pid)
        if let bundleId = app.bundleIdentifier {
            enabledBundleIds.insert(bundleId)
        }

        let appElement = AXUIElementCreateApplication(pid)
        // AppKit's enhanced-UI switch — unlocks the full a11y tree in Cocoa apps.
        AXUIElementSetAttributeValue(
            appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
        )
        // Chromium/Electron manual-accessibility switch — materializes the lazily
        // built web a11y tree (and its text-marker caret geometry).
        AXUIElementSetAttributeValue(
            appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        return true
    }

    /// Records whether caret resolution succeeded *after* enhanced UI was forced
    /// on for an app, producing the one-boolean-per-bundleId "enhanced UI helped"
    /// feedback signal that drives a future "likely helped" Settings hint.
    ///
    /// Only apps we actually tried to unlock (`enabledBundleIds`) are recorded, and
    /// the flag latches `true` once it has helped — a later keystroke that happens
    /// to lack a caret (e.g. an empty field) must not erase evidence that the
    /// unlock works for this app. No-op for apps we never enabled.
    static func recordCaretOutcome(bundleId: String?, caretResolved: Bool) {
        guard let bundleId, enabledBundleIds.contains(bundleId) else { return }
        guard caretResolved else { return }
        if Preferences.enhancedUIHelped[bundleId] != true {
            Preferences.enhancedUIHelped[bundleId] = true
        }
    }

    /// Test hook: clears the per-process enable caches so each test starts from a
    /// clean slate.
    static func resetForTesting() {
        enabledPids.removeAll()
        enabledBundleIds.removeAll()
    }
}
