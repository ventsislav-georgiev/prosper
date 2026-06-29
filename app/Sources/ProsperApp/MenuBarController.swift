import AppKit

/// Owns the status-bar item and its menu.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let versionItem: NSMenuItem
    private let secureInputItem: NSMenuItem
    private let agentStatusItem: NSMenuItem
    private let agentItem: NSMenuItem
    private let runnerItem: NSMenuItem
    private let clipboardOpenItem: NSMenuItem
    private let settingsItem: NSMenuItem
    private let focusedAppItem: NSMenuItem
    private let setupItem: NSMenuItem
    private let updateItem: NSMenuItem

    /// Last non-Prosper app the user focused, tracked via workspace activation
    /// notifications. Read when the menu opens to label/target the per-app
    /// completions toggle. We can't read `frontmostApplication` at menu-open time
    /// because clicking the status item may have just activated Prosper itself.
    private var lastFocusedApp: (bundleId: String, name: String)?
    private var focusObserver: NSObjectProtocol?

    private let onOpenRunner: () -> Void
    private let onOpenClipboard: () -> Void
    private let onOpenSettings: () -> Void
    private let onCheckForUpdates: () -> Void
    private let onRerunSetup: () -> Void
    private let onRestart: () -> Void
    private let onQuit: () -> Void

    init(
        onOpenRunner: @escaping () -> Void,
        onOpenClipboard: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onCheckForUpdates: @escaping () -> Void,
        onRerunSetup: @escaping () -> Void,
        onRestart: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onOpenRunner = onOpenRunner
        self.onOpenClipboard = onOpenClipboard
        self.onOpenSettings = onOpenSettings
        self.onCheckForUpdates = onCheckForUpdates
        self.onRerunSetup = onRerunSetup
        self.onRestart = onRestart
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // CONTENT, not chrome: the launcher is a real user-facing icon, so it belongs
        // in the order list (named + previewed) and can be arranged/hidden like any
        // other. Only the chevron + dividers (the management mechanism) are .control.
        ProsperStatusItems.register(statusItem, role: .content, name: "Prosper")
        versionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        secureInputItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        secureInputItem.isEnabled = false
        secureInputItem.isHidden = true
        agentStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        agentStatusItem.isEnabled = false
        agentStatusItem.isHidden = true
        agentItem = NSMenuItem(
            title: "Coding Agent\u{2026}",
            action: nil,
            keyEquivalent: ""
        )
        runnerItem = NSMenuItem(
            title: "Command Runner\u{2026}",
            action: nil,
            keyEquivalent: ""
        )
        clipboardOpenItem = NSMenuItem(
            title: "Clipboard History\u{2026}",
            action: nil,
            keyEquivalent: ""
        )
        settingsItem = NSMenuItem(
            title: "Settings\u{2026}",
            action: nil,
            keyEquivalent: ""
        )
        focusedAppItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        focusedAppItem.isHidden = true
        setupItem = NSMenuItem(
            title: "Re-run Setup\u{2026}",
            action: nil,
            keyEquivalent: ""
        )
        updateItem = NSMenuItem(
            title: "Check for Updates\u{2026}",
            action: nil,
            keyEquivalent: ""
        )

        super.init()

        setMenuBarImage(nil)   // bundled default; a theme can swap it later

        statusItem.menu = buildMenu()
        statusItem.isVisible = Preferences.showMenuBarIcon

        // Seed + track the last non-Prosper focused app for the per-app toggle.
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier,
           let id = app.bundleIdentifier {
            lastFocusedApp = (id, app.localizedName ?? id)
        }
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                self?.lastFocusedApp = (id, app.localizedName ?? id)
            }
        }

        // Pulse the status icon while the updater is busy (manual check or
        // download/extract) — a lightweight "something is happening" cue.
        AppUpdater.shared.onActivityChanged = { [weak self] active in
            self?.setIconPulsing(active)
        }
        setIconPulsing(AppUpdater.shared.isActive)
    }

    /// Sets the status-bar button image. Pass a theme-provided image to override
    /// the bundled Neon-Vulcan hand; pass nil to use the bundled default (or the
    /// SF Symbol fallback if even that is missing). Either way it's scaled to fill
    /// the bar height. Not a template image — we want the color/glow, not a flat
    /// glyph. The bundled PNG ships in Contents/Resources via scripts/bundle.sh.
    func setMenuBarImage(_ themed: NSImage?) {
        guard let button = statusItem.button else { return }
        // Copy: `themed` is the cached NSImage owned by ThemeStore; resizing it in
        // place would corrupt the shared instance (also used for the dock icon path).
        let icon = (themed?.copy() as? NSImage)
            ?? Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png")
                .flatMap { NSImage(contentsOf: $0) }
        if let icon {
            let h = NSStatusBar.system.thickness
            let w = h * (icon.size.width / max(icon.size.height, 1))
            icon.size = NSSize(width: w, height: h)
            icon.isTemplate = false
            button.image = icon
        } else {
            button.image = NSImage(systemSymbolName: "character.bubble",
                                   accessibilityDescription: "Prosper")
            button.image?.isTemplate = true
        }
    }

    /// Starts/stops a slow opacity pulse on the status-bar button. Idempotent:
    /// re-adding while already pulsing is a no-op, and stopping restores full
    /// opacity.
    private func setIconPulsing(_ on: Bool) {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        let key = "prosper.updatePulse"
        if on {
            guard layer.animation(forKey: key) == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: key)
        } else {
            layer.removeAnimation(forKey: key)
            layer.opacity = 1
        }
    }

    /// Shows/hides the status-bar icon (Settings → General). When hidden the app
    /// keeps running and stays reachable via global hotkeys + accessory button.
    func setIconVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    /// "Re-run Setup" only makes sense when inline autocomplete is ON but the
    /// permissions it needs are missing. Turning autocomplete OFF is unrelated to
    /// setup, so it must NOT resurface this item — when the feature is off there
    /// is nothing to set up.
    /// Top menu row: app name + version, with a live "downloading update" hint
    /// while Sparkle is fetching/staging a new build.
    private var versionTitle: String {
        let base = "Prosper v\(AppInfo.shortVersion)"
        return AppUpdater.shared.isDownloadingUpdate ? "\(base) — Downloading update\u{2026}" : base
    }

    private var shouldShowSetup: Bool {
        // "Re-run Setup…" runs the MODEL download (onRerunSetup -> runModelSetup),
        // so it must gate on the model, not a TCC grant: show it only when inline
        // autocomplete is on but the local model isn't on disk (completions can't
        // run without it). The Accessibility grant is surfaced separately — as the
        // inline warning in General settings (see GeneralPane.PermissionWarningRow),
        // not here — so the two concerns don't cross-wire (the old gate showed a
        // model-download item whenever Accessibility was missing, and hid it when
        // the model was genuinely absent).
        //
        // Check the SELECTED completion model, not "any model on disk": a user who
        // switched to an undownloaded model still needs setup even with another
        // model cached. The id-keyed lookup also walks a single snapshots tree
        // instead of enumerating every cached model — cheaper on this per-open
        // menu-refresh path (the no-arg `isModelDownloaded` scans the whole hub).
        Preferences.autocompleteEnabled && !ModelFiles.isModelDownloaded(Preferences.coreModel)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        versionItem.title = versionTitle
        menu.addItem(versionItem)
        menu.addItem(secureInputItem)
        menu.addItem(agentStatusItem)
        menu.addItem(.separator())

        runnerItem.action = #selector(openRunnerSelected)
        runnerItem.target = self
        menu.addItem(runnerItem)

        clipboardOpenItem.action = #selector(openClipboardSelected)
        clipboardOpenItem.target = self
        menu.addItem(clipboardOpenItem)

        // "Coding Agent…" — hidden while the coding agent is disabled in Settings.
        agentItem.action = #selector(openCodingAgentSelected)
        agentItem.target = self
        agentItem.isHidden = !Preferences.agentEnabled
        menu.addItem(agentItem)

        menu.addItem(.separator())

        // Per-app inline-completions toggle. Inline autocomplete is enabled/disabled
        // globally from Settings now; this row stays for the focused-app override.
        focusedAppItem.action = #selector(toggleFocusedAppSelected)
        focusedAppItem.target = self
        menu.addItem(focusedAppItem)

        menu.addItem(.separator())

        settingsItem.action = #selector(openSettingsSelected)
        settingsItem.target = self
        menu.addItem(settingsItem)

        setupItem.action = #selector(rerunSetupSelected)
        setupItem.target = self
        setupItem.isHidden = !shouldShowSetup
        menu.addItem(setupItem)

        updateItem.action = #selector(checkForUpdatesSelected)
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let restartItem = NSMenuItem(
            title: "Restart",
            action: #selector(restartSelected),
            keyEquivalent: ""
        )
        restartItem.target = self
        menu.addItem(restartItem)

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitSelected),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        syncShortcutKeyEquivalents()
        return menu
    }

    /// Mirrors the menu rows' key equivalents onto the *configured* global
    /// shortcuts (Settings → Shortcuts), instead of the old hardcoded glyphs that
    /// drifted from the real bindings. Re-run on every menu open so a rebind shows
    /// immediately. An unset combo clears the equivalent (no bogus glyph).
    private func syncShortcutKeyEquivalents() {
        func apply(_ item: NSMenuItem, _ action: ShortcutAction) {
            let combo = ShortcutStore.combo(for: action)
            item.keyEquivalent = combo.menuKeyEquivalent ?? ""
            item.keyEquivalentModifierMask = combo.menuModifierMask
        }
        apply(runnerItem, .runner)
        apply(clipboardOpenItem, .clipboard)
        apply(agentItem, .agent)
        apply(settingsItem, .settings)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        // Keep checkboxes in sync with persisted prefs / OS state.
        versionItem.title = versionTitle
        // Secure Input row: surfaces why completions died (a password field — or a
        // stuck app holding Secure Input forever) and names the culprit when known.
        if SecureInput.isActive {
            let culprit = SecureInput.culpritName()
            secureInputItem.title = culprit.map {
                "\u{1F512} Secure Input on (\($0)) — completions paused"
            } ?? "\u{1F512} Secure Input on — completions paused"
            secureInputItem.isHidden = false
        } else {
            secureInputItem.isHidden = true
        }
        // Coding-agent status: while the agent owns the model, inline suggestions are
        // paused (residency swap). Surface it so the paused completions aren't a mystery.
        switch AgentController.shared.phase {
        case .idle, .error:
            agentStatusItem.isHidden = true
        case .loadingModel:
            agentStatusItem.title = "\u{1F916} Loading coding model — suggestions paused"
            agentStatusItem.isHidden = false
        case .running, .awaitingApproval:
            agentStatusItem.title = "\u{1F916} Coding agent running — suggestions paused"
            agentStatusItem.isHidden = false
        }
        agentItem.isHidden = !Preferences.agentEnabled
        syncShortcutKeyEquivalents()
        refreshFocusedAppItem()
        setupItem.isHidden = !shouldShowSetup
        // Live label: a manual check in flight reads "Checking…" until Sparkle
        // resolves (found / up to date / error).
        updateItem.title = AppUpdater.shared.isCheckingForUpdates
            ? "Checking for Updates\u{2026}" : "Check for Updates\u{2026}"
    }

    /// Syncs the per-app completions row with the currently focused app.
    /// Visible only while inline autocomplete is globally ON and a real
    /// (non-Prosper) app has focus; reflects the *effective* per-app gate from
    /// `AppOverrideResolver` (user override → seed → secure → Preferences).
    /// Apps where inline completion cannot work at all (terminals, password
    /// managers — `AppProfile.supportsInlineCompletion`) render as a disabled
    /// "not supported" row instead of a toggle, so the menu never claims
    /// completions are on in an app we can't complete into.
    private func refreshFocusedAppItem() {
        guard Preferences.autocompleteEnabled, let app = lastFocusedApp else {
            focusedAppItem.isHidden = true
            return
        }
        focusedAppItem.isHidden = false
        if !AppProfile.profile(for: app.bundleId).supportsInlineCompletion {
            focusedAppItem.title = "\(app.name) not supported"
            focusedAppItem.state = .off
            // nil action -> NSMenu auto-disables (grays out) the row.
            focusedAppItem.action = nil
            return
        }
        focusedAppItem.title = "Completions in \(app.name)"
        focusedAppItem.action = #selector(toggleFocusedAppSelected)
        focusedAppItem.state =
            AppOverrideResolver.isEnabled(forBundleId: app.bundleId) ? .on : .off
    }

    // MARK: - Actions

    @objc private func openRunnerSelected() {
        onOpenRunner()
    }

    @objc private func openCodingAgentSelected() {
        ChatWindow.shared.show()
    }

    /// Toggles inline completions for the focused app by writing an explicit
    /// `enabled` user override — the top of the resolver's priority chain, so it
    /// wins over seeds and the legacy Preferences lists either way. Other per-app
    /// knobs (custom instructions, Tab, …) on an existing override are preserved.
    @objc private func toggleFocusedAppSelected() {
        guard let app = lastFocusedApp,
              AppProfile.profile(for: app.bundleId).supportsInlineCompletion
        else { return }
        let newValue = !AppOverrideResolver.isEnabled(forBundleId: app.bundleId)
        focusedAppItem.state = newValue ? .on : .off
        var override = AppOverrideCache.shared.override(for: app.bundleId)
            ?? AppOverride(bundleId: app.bundleId)
        override.enabled = newValue
        Task.detached(priority: .userInitiated) {
            await AppOverrideStore.shared.setOverride(override)
        }
    }

    @objc private func openClipboardSelected() {
        onOpenClipboard()
    }

    @objc private func openSettingsSelected() {
        onOpenSettings()
    }

    @objc private func rerunSetupSelected() {
        onRerunSetup()
    }

    @objc private func checkForUpdatesSelected() {
        onCheckForUpdates()
        // Reflect the in-flight state immediately — the menu is closing, but a
        // quick re-open should already read "Checking…".
        updateItem.title = "Checking for Updates\u{2026}"
    }

    @objc private func restartSelected() {
        onRestart()
    }

    @objc private func quitSelected() {
        onQuit()
    }
}
