import AppKit
import Sparkle
import UserNotifications

/// Drives Sparkle in **fully unattended** mode: updates are checked, downloaded,
/// installed, and the app is relaunched automatically with **no dialogs**.
///
/// Instead of `SPUStandardUpdaterController` (which owns Sparkle's standard UI),
/// we drive a bare `SPUUpdater` with a custom `SPUUserDriver` (`SilentUserDriver`)
/// that auto-approves every prompt (`.install`) and shows nothing. The only user
/// feedback is a single notification when a *user-initiated* "Check for Updates…"
/// finds nothing or errors — background checks stay completely silent.
///
/// Runtime requires a hosted **appcast** feed and **EdDSA-signed** archives:
/// `SUFeedURL` + `SUPublicEDKey` in Info.plist. Without them the updater is inert
/// (start fails gracefully) but never crashes.
@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    private let driver = SilentUserDriver()

    /// Gates the `beta` appcast channel on `Preferences.allowBetaUpdates`. Kept as a
    /// stored property so Sparkle's weak `delegate` reference stays alive.
    private let channelDelegate = UpdaterChannelDelegate()

    private let updater: SPUUpdater

    /// Background appcast poll interval. Sparkle's own scheduler clamps small
    /// `updateCheckInterval` values to ~1h, so we drive a silent background check
    /// ourselves on this cadence. The check is just a small appcast XML fetch.
    private static let pollInterval: TimeInterval = 600 // 10 minutes

    private var pollTimer: Timer?

    /// When the next automatic background check will fire, or nil when automatic
    /// checks are off. Surfaced in the About pane as a live countdown.
    private(set) var nextCheckDate: Date?

    /// True while an update is being downloaded / extracted / staged for install.
    /// Surfaced in the menu bar's version row so the user sees an update is in
    /// flight. Updated by the silent driver's download/extract callbacks.
    private(set) var isDownloadingUpdate = false {
        didSet { if oldValue != isDownloadingUpdate { onActivityChanged?(isActive) } }
    }

    /// True while a *user-initiated* check is in flight. Surfaced as a
    /// "Checking for Updates…" label in the menu bar item and the About pane's
    /// button so a manual check is never a silent no-op while it runs.
    private(set) var isCheckingForUpdates = false {
        didSet { if oldValue != isCheckingForUpdates { onActivityChanged?(isActive) } }
    }

    /// Download/extract progress in 0…1, or nil while the size isn't known yet
    /// (indeterminate). Restarts when extraction begins — one bar covers both
    /// phases. Surfaced as the About pane's gradient progress bar.
    private(set) var downloadProgress: Double?

    /// True while the updater is doing anything user-visible (a manual check or
    /// a download/extract). Drives the menu bar icon's pulsing.
    var isActive: Bool { isCheckingForUpdates || isDownloadingUpdate }

    /// Fired (with the new `isActive`) whenever check/download activity starts
    /// or stops — the menu bar uses it to pulse the status icon.
    var onActivityChanged: ((Bool) -> Void)?

    override init() {
        updater = SPUUpdater(
            hostBundle: Bundle.main,
            applicationBundle: Bundle.main,
            userDriver: driver,
            delegate: channelDelegate
        )
        super.init()

        // Mirror the driver's download/extract state so the menu can show it.
        driver.onDownloadingChanged = { [weak self] downloading in
            self?.isDownloadingUpdate = downloading
            if !downloading { self?.downloadProgress = nil }
        }

        // Live download/extract fraction for the About pane's progress bar.
        driver.onProgressChanged = { [weak self] progress in
            self?.downloadProgress = progress
        }

        // The check resolved (update found / up to date / error) — clear the
        // "Checking…" label.
        driver.onCheckFinished = { [weak self] in
            self?.isCheckingForUpdates = false
        }

        // Unattended: check + download + install automatically.
        updater.automaticallyChecksForUpdates = Preferences.automaticUpdateChecks
        updater.automaticallyDownloadsUpdates = true
        updater.updateCheckInterval = Self.pollInterval

        do {
            try updater.start()
        } catch {
            NSLog("AppUpdater: startUpdater failed — \(error.localizedDescription)")
        }

        if Preferences.automaticUpdateChecks { startPolling() }
    }

    /// User-initiated update check. Still silent unless nothing is found / an
    /// error occurs, in which case the driver posts a single notification.
    /// Also resets the 10-minute background cadence — the manual check just
    /// covered it, so the next automatic check counts from now.
    func checkForUpdates() {
        driver.userInitiated = true
        isCheckingForUpdates = true
        updater.checkForUpdates()
        if automaticChecks { restartPolling() }
    }

    var automaticChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            updater.automaticallyChecksForUpdates = newValue
            Preferences.automaticUpdateChecks = newValue
            if newValue { startPolling() } else { stopPolling() }
        }
    }

    /// Whether pre-release (beta) builds are accepted. Toggling on triggers an
    /// immediate silent background check so a pending beta is picked up at once;
    /// the `beta` channel itself is gated by `UpdaterChannelDelegate`, which reads
    /// `Preferences.allowBetaUpdates` on every Sparkle check.
    var allowBetaUpdates: Bool {
        get { Preferences.allowBetaUpdates }
        set {
            Preferences.allowBetaUpdates = newValue
            if newValue {
                driver.userInitiated = false
                updater.checkForUpdatesInBackground()
            }
        }
    }

    /// Silent background check (no UI). Inert when no `SUFeedURL` is configured.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.driver.userInitiated = false
                self.updater.checkForUpdatesInBackground()
                self.nextCheckDate = Date().addingTimeInterval(Self.pollInterval)
            }
        }
        timer.tolerance = 60 // let macOS coalesce the wakeup — keeps it lightweight
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        nextCheckDate = Date().addingTimeInterval(Self.pollInterval)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        nextCheckDate = nil
    }

    /// Restarts the background cadence so the next automatic check fires a full
    /// interval from now (used after a manual check).
    private func restartPolling() {
        stopPolling()
        startPolling()
    }
}

// MARK: - Channel gate

/// Tells Sparkle which non-default appcast channels this install accepts. Stable
/// builds live in the default channel (no `<sparkle:channel>` tag) and are always
/// offered; beta builds carry `<sparkle:channel>beta</sparkle:channel>` and are
/// only offered when the user opted in. Sparkle calls this on every check, so the
/// toggle takes effect without a relaunch.
final class UpdaterChannelDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Preferences.allowBetaUpdates ? ["beta"] : []
    }
}

// MARK: - Silent user driver

/// An `SPUUserDriver` that runs Sparkle without any UI: it auto-approves finding,
/// downloading, installing, and relaunching. The sole exception is feedback for a
/// *user-initiated* check that finds no update or errors — surfaced as one
/// notification so the menu's "Check for Updates…" isn't a silent no-op.
@MainActor
final class SilentUserDriver: NSObject, SPUUserDriver {

    /// Set true right before a user-initiated check; gates the only notifications.
    var userInitiated = false

    /// Fired (with the new value) whenever a download/extract starts or ends, so
    /// the owning `AppUpdater` can surface "downloading" in the menu bar.
    var onDownloadingChanged: ((Bool) -> Void)?

    /// Fired when a check resolves — an update was found, none was found, or the
    /// check errored — so the owning `AppUpdater` can clear "Checking…".
    var onCheckFinished: (() -> Void)?

    /// Fired with the download/extract fraction (0…1) as bytes arrive, or nil
    /// while the total size is unknown (indeterminate).
    var onProgressChanged: ((Double?) -> Void)?

    /// Download byte accounting for the progress fraction.
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: true,
            automaticUpdateDownloading: true,
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // Information-only updates must not be installed — dismiss them.
        let install = !appcastItem.isInformationOnlyUpdate
        if install { onDownloadingChanged?(true) }
        onCheckFinished?()
        reply(install ? .install : .dismiss)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if userInitiated { Self.notify("Prosper is up to date", "You're running the latest version.") }
        userInitiated = false
        onDownloadingChanged?(false)
        onCheckFinished?()
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if userInitiated { Self.notify("Update check failed", error.localizedDescription) }
        userInitiated = false
        onDownloadingChanged?(false)
        onCheckFinished?()
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        onDownloadingChanged?(true)
        onProgressChanged?(nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        receivedLength = 0
        onProgressChanged?(expectedLength > 0 ? 0 : nil)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        if expectedLength > 0 {
            onProgressChanged?(min(1, Double(receivedLength) / Double(expectedLength)))
        } else {
            onProgressChanged?(nil)
        }
    }

    /// Extraction restarts the bar — one bar covers download then extract.
    func showDownloadDidStartExtractingUpdate() { onProgressChanged?(0) }
    func showExtractionReceivedProgress(_ progress: Double) {
        onProgressChanged?(min(1, max(0, progress)))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        NSLog("AppUpdater: update ready — installing + relaunching.")
        reply(.install) // install + relaunch immediately, no prompt
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        if applicationTerminated {
            NSLog("AppUpdater: app terminated — Sparkle is swapping the bundle.")
            return
        }
        // Sparkle sent a quit event but the app is still running — something is
        // delaying termination (a modal alert, an in-flight teardown). If we do
        // nothing, the staged bundle is never swapped and /Applications keeps the
        // OLD app, so a later manual relaunch starts the stale version. Re-send the
        // quit event on a timer until the app actually exits; a transient blocker
        // (e.g. a dismissed alert) lets a later retry through.
        // ponytail: bounded retry, NOT a forced exit() — exit() would skip the
        // SQLCipher / agent-harness teardown and risk a corrupt transcript DB.
        NSLog("AppUpdater: update staged but app still running — retrying termination.")
        retryTerminate(retryTerminatingApplication, attempt: 0)
    }

    /// Re-sends Sparkle's quit event every 2s (up to ~30s) so a momentary
    /// termination blocker doesn't strand the staged update. Each retry is queued
    /// on the main run loop, so it naturally waits out a modal alert before firing.
    private func retryTerminate(_ retry: @escaping () -> Void, attempt: Int) {
        guard attempt < 15 else {
            NSLog("AppUpdater: app still alive after \(attempt) retries — update will apply on next quit.")
            return
        }
        retry()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.retryTerminate(retry, attempt: attempt + 1)
        }
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        onDownloadingChanged?(false)
        acknowledgement()
    }

    func dismissUpdateInstallation() { onDownloadingChanged?(false) }

    // MARK: - Notification helper

    private static func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            if granted { center.add(request) }
        }
    }
}
