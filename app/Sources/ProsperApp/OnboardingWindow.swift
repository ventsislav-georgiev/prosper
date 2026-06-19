import AppKit
import SwiftUI

/// First-run onboarding: welcome → Accessibility → Input Monitoring → model
/// download → done. Shown once (gated by `Preferences.onboardingCompleted`).
@MainActor
final class OnboardingWindow {

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private let onFinished: () -> Void

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
    }

    func show() {
        if let window {
            DockPolicy.windowDidShow(window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = OnboardingRootView(onFinish: { [weak self] in self?.finish() })
        let hosting = NSHostingController(rootView: Themed { root })
        let win = NSWindow(contentViewController: hosting)
        win.title = "Welcome to Prosper"
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.backgroundColor = NSColor(Neon.bgTop)
        win.appearance = NSAppearance(named: .darkAqua)
        win.setContentSize(NSSize(width: 560, height: 440))
        win.isReleasedWhenClosed = false
        win.centerOnScreen()
        window = win
        // Window can close via the title-bar button (willClose) or our finish()
        // path (close()) — both post willClose, so hide the Dock icon from here.
        // Also drop the window: the hosting view of a closed-but-referenced
        // window keeps rendering (its 1 s permission poll would run forever).
        // Reopening rebuilds it; the step persists via Preferences.onboardingStep.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                DockPolicy.windowDidHide(win)
                guard let self else { return }
                if let obs = self.closeObserver {
                    NotificationCenter.default.removeObserver(obs)
                }
                self.closeObserver = nil
                self.window = nil
                // Detach the hosting controller once the close finishes: even a
                // dereferenced window can be kept alive by stale stack/autorelease
                // references, and its hosting view would keep polling permissions.
                DispatchQueue.main.async { win.contentViewController = nil }
            }
        }
        DockPolicy.windowDidShow(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        Preferences.onboardingCompleted = true
        window?.close()
        window = nil
        onFinished()
    }
}

// MARK: - Views

private enum OnboardingStep: Int, CaseIterable {
    case welcome, autocomplete, accessibility, inputMonitoring, model, done
}

private struct OnboardingRootView: View {
    let onFinish: () -> Void
    // Resume on the step the user last reached. Granting a TCC permission often
    // forces a quit-and-reopen; persisting the step means we land back here and
    // (with live polling below) immediately reflect the now-granted permission.
    @State private var step: OnboardingStep =
        OnboardingStep(rawValue: Preferences.onboardingStep) ?? .welcome
    @State private var accessibilityTrusted = PermissionsManager.isAccessibilityTrusted()
    @State private var inputMonitoringTrusted = PermissionsManager.isInputMonitoringTrusted()
    // Stable tick anchor for the permission poller below. Inline `.now` would re-anchor
    // the schedule each time a permission flip rebuilds this body — a stored Date keeps
    // the 1 Hz cadence fixed across rebuilds.
    @State private var clock = Date()
    // Inline autocomplete is opt-in: off by default. Only when enabled does the
    // wizard show (and gate on) the Accessibility + Input Monitoring steps —
    // those permissions exist solely to drive autocomplete. Declining skips them.
    @State private var enableAutocomplete = Preferences.autocompleteEnabled
    @State private var modelStatus = "Not started"
    @State private var modelDownloading = false
    // Seed from disk so a user who already has the model isn't gated/forced to
    // re-download on the model step.
    @State private var modelReady = ModelFiles.isModelDownloaded

    var body: some View {
        // Polls permission state every second (granting happens out-of-process in
        // System Settings, so there is no callback to observe). TimelineView's
        // periodic schedule pauses while the view is offscreen — a Timer.publish
        // ticker here would keep polling the AX trust APIs at 1 Hz for as long
        // as the closed window's hosting view stays alive.
        TimelineView(.periodic(from: clock, by: 1)) { timeline in
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(30)
                Divider()
                footer.padding()
            }
            .onChange(of: timeline.date) { _, _ in
                accessibilityTrusted = PermissionsManager.isAccessibilityTrusted()
                inputMonitoringTrusted = PermissionsManager.isInputMonitoringTrusted()
            }
        }
        .frame(width: 560, height: 440)
        .background(SettingsBackground())
        .foregroundStyle(Neon.textPrimary)
        .tint(Neon.blue)
        .preferredColorScheme(.dark)
        .onChange(of: step) { _, newValue in
            Preferences.onboardingStep = newValue.rawValue
        }
        .onChange(of: enableAutocomplete) { _, newValue in
            Preferences.autocompleteEnabled = newValue
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            stepBody(icon: "character.bubble", title: "Welcome to Prosper") {
                Text("System-wide inline autocomplete, a command runner (calc, units, currency, translate), and clipboard history — all powered by a local AI model. Nothing leaves your Mac.")
                    .multilineTextAlignment(.center).foregroundColor(Neon.textSecondary)
            }
        case .autocomplete:
            stepBody(icon: "wand.and.stars", title: "Inline Autocomplete") {
                VStack(spacing: 12) {
                    Text("Prosper can suggest completions as you type in any app, accepted with Tab. This is optional and off by default — turning it on needs Accessibility and Input Monitoring access.")
                        .multilineTextAlignment(.center).foregroundColor(Neon.textSecondary)
                    Toggle("Enable inline autocomplete", isOn: $enableAutocomplete)
                        .toggleStyle(.switch)
                    Text(enableAutocomplete
                         ? "Next, grant the two permissions it needs."
                         : "No extra permissions needed. You can turn this on anytime in Settings.")
                        .font(.caption).foregroundColor(Neon.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        case .accessibility:
            stepBody(icon: accessibilityTrusted ? "checkmark.shield.fill" : "shield",
                     title: "Accessibility Access") {
                VStack(spacing: 10) {
                    Text("Prosper reads the caret position and inserts completions via the Accessibility API. Grant access in System Settings.")
                        .multilineTextAlignment(.center).foregroundColor(Neon.textSecondary)
                    permissionStatus(granted: accessibilityTrusted)
                    if !accessibilityTrusted {
                        HStack(spacing: 8) {
                            Button("Open Accessibility Settings") {
                                PermissionsManager.ensureAccessibilityTrust(prompt: true)
                                PermissionsManager.openAccessibilitySettings()
                            }
                            Button("Re-check") {
                                accessibilityTrusted = PermissionsManager.isAccessibilityTrusted()
                            }
                        }
                        Text("After enabling it (you may be asked to quit & reopen), this updates automatically.")
                            .font(.caption2).foregroundColor(Neon.textSecondary)
                            .multilineTextAlignment(.center)
                        Text("Already enabled but still not detected? An ad-hoc-signed rebuild changes the app's signature, so macOS's old grant no longer matches. Reset it and re-grant in one step:")
                            .font(.caption2).foregroundColor(Neon.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("Reset & re-add Prosper") {
                            PermissionsManager.resetPrivacyGrant(service: "Accessibility")
                            PermissionsManager.ensureAccessibilityTrust(prompt: true)
                            PermissionsManager.openAccessibilitySettings()
                        }
                        .font(.caption)
                    }
                }
            }
        case .inputMonitoring:
            stepBody(icon: inputMonitoringTrusted ? "checkmark.circle.fill" : "keyboard",
                     title: "Input Monitoring") {
                VStack(spacing: 10) {
                    Text("To watch keystrokes for inline completion, Prosper needs Input Monitoring access.")
                        .multilineTextAlignment(.center).foregroundColor(Neon.textSecondary)
                    permissionStatus(granted: inputMonitoringTrusted)
                    if !inputMonitoringTrusted {
                        HStack(spacing: 8) {
                            Button("Open Input Monitoring Settings") {
                                PermissionsManager.requestInputMonitoring()
                                PermissionsManager.openInputMonitoringSettings()
                            }
                            Button("Re-check") {
                                inputMonitoringTrusted = PermissionsManager.isInputMonitoringTrusted()
                            }
                        }
                        Text("After enabling it (you may be asked to quit & reopen), this updates automatically.")
                            .font(.caption2).foregroundColor(Neon.textSecondary)
                            .multilineTextAlignment(.center)
                        Text("Already enabled but still not detected? An ad-hoc-signed rebuild changes the app's signature, so macOS's old grant no longer matches. Reset it and re-grant in one step:")
                            .font(.caption2).foregroundColor(Neon.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("Reset & re-add Prosper") {
                            PermissionsManager.resetPrivacyGrant(service: "ListenEvent")
                            PermissionsManager.requestInputMonitoring()
                            PermissionsManager.openInputMonitoringSettings()
                        }
                        .font(.caption)
                    }
                }
            }
        case .model:
            stepBody(icon: "arrow.down.circle", title: "Download the AI Model") {
                VStack(spacing: 10) {
                    Text("Prosper runs Gemma 4 E2B locally via Apple MLX. The model downloads once (~3.6 GB) — on a typical connection this takes several minutes.")
                        .multilineTextAlignment(.center).foregroundColor(Neon.textSecondary)
                    Text(modelStatus).font(.caption).foregroundColor(Neon.textSecondary)
                    if modelReady {
                        Label("Model ready", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                    } else if modelDownloading {
                        ProgressView()
                    } else {
                        Button("Download Now") { startModelDownload() }
                        if enableAutocomplete {
                            Text("Required for inline autocomplete — finish the download to continue.")
                                .font(.caption2).foregroundColor(Neon.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
        case .done:
            stepBody(icon: "checkmark.seal.fill", title: "You're all set") {
                Text("Open the command runner with ⌥Space, clipboard history with ⇧⌥A, and tweak everything in Settings (⌘,).")
                    .multilineTextAlignment(.center).foregroundColor(Neon.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func stepBody<C: View>(icon: String, title: String, @ViewBuilder body: () -> C) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 52)).foregroundColor(Neon.blue)
                .shadow(color: Neon.blue.opacity(0.5), radius: 12)
            Text(title).font(.title).bold().foregroundStyle(Neon.textPrimary)
            body()
            Spacer()
        }
    }

    /// Green check when granted, red ✗ otherwise. Drives the per-step gate.
    @ViewBuilder
    private func permissionStatus(granted: Bool) -> some View {
        if granted {
            Label("Granted", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        } else {
            Label("Not granted yet", systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { back() }
            }
            Spacer()
            stepIndicator
            Spacer()
            Button(primaryTitle) { next() }
                .keyboardShortcut(.defaultAction)
                .disabled(primaryDisabled)
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s.rawValue <= step.rawValue ? Neon.blue : Neon.textSecondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .shadow(color: s.rawValue <= step.rawValue ? Neon.blue.opacity(0.7) : .clear, radius: 3)
            }
        }
    }

    private var primaryTitle: String { step == .done ? "Finish" : "Continue" }

    /// Block advancing until the current step's requirement is met.
    /// Accessibility + Input Monitoring are hard gates (the app is non-functional
    /// without them). The model step is a hard gate too *when autocomplete is
    /// enabled* — inline completion can't run without the model, so the user must
    /// finish the download before continuing. Other steps are always advanceable.
    private var primaryDisabled: Bool {
        switch step {
        case .accessibility: return !accessibilityTrusted
        case .inputMonitoring: return !inputMonitoringTrusted
        case .model: return enableAutocomplete && !modelReady
        default: return false
        }
    }

    /// Accessibility + Input Monitoring only exist to power autocomplete, so we
    /// skip both steps entirely when the user declined it.
    private func isSkipped(_ s: OnboardingStep) -> Bool {
        (s == .accessibility || s == .inputMonitoring) && !enableAutocomplete
    }

    private func back() {
        var raw = step.rawValue - 1
        while let s = OnboardingStep(rawValue: raw), isSkipped(s) { raw -= 1 }
        if let prev = OnboardingStep(rawValue: raw) { step = prev }
    }

    private func next() {
        if step == .done {
            Preferences.onboardingStep = OnboardingStep.welcome.rawValue
            onFinish()
            return
        }
        var raw = step.rawValue + 1
        while let s = OnboardingStep(rawValue: raw), isSkipped(s) { raw += 1 }
        if let nxt = OnboardingStep(rawValue: raw) { step = nxt }
    }

    private func startModelDownload() {
        modelDownloading = true
        modelStatus = "Starting\u{2026}"
        CoreBridge.ensureModel(
            progress: { p in
                // Once bytes are done (100%) the wait is the in-memory load, which
                // carries its own status and no meaningful percent — show it plain.
                if let pct = p.percent, pct < 100 {
                    modelStatus = "\(p.status) (\(Int(pct))%)"
                } else {
                    modelStatus = p.status
                }
            },
            completion: { success in
                modelDownloading = false
                modelReady = success
                modelStatus = success ? "Model ready." : "Download failed — retry from the menu later."
            }
        )
    }
}
