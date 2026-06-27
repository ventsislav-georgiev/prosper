import AppKit
import Carbon
import CoreServices
import UserNotifications

/// Owns the app's long-lived objects and wires them together on launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController?
    private var hotKeys: [GlobalHotKey] = []
    private var runnerPanel: RunnerPanel?
    private var clipboardPanel: ClipboardPanel?
    private var settingsWindow: SettingsWindow?
    /// Reusable host for `host.window.open` (extension-driven standalone windows,
    /// e.g. the Base64 converter). Lazily presented; survives close.
    private let extensionViewPanel = ExtensionViewPanel()
    private var modelSetup: ModelSetup?
    /// Watches `~/.config/prosper/mcp.json` for external edits/imports. App-lifetime.
    private var mcpConfigWatcher: FileWatcher?
    private var hooksConfigWatcher: FileWatcher?
    private var syncAppliedObserver: NSObjectProtocol?
    private let autocomplete = AutocompleteEngine()
    /// Extension system. Discovers bundled system extensions (calc, …) + any
    /// user-installed ones, and backs the migrated command-router handlers.
    /// The async host-call ceiling is raised well past the 5 s default: a
    /// model-backed command (e.g. Translate) runs on-device generation that can
    /// take tens of seconds, and a short timeout would silently drop the result.
    private let extensions = ExtensionRegistry(callTimeout: 60)
    /// Native watchers (battery / network / wake / lid) → extension events.
    private let systemEventWatchers = SystemEventWatchers()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a pipe whose reader died (a crashed codex/bun subprocess) raises
        // SIGPIPE, whose default action terminates the app. Ignore it process-wide so
        // the write fails with EPIPE instead — our pipe writes already handle the throw.
        signal(SIGPIPE, SIG_IGN)

        // Strip our own quarantine flag so post-update relaunches (and every
        // launch after the first) skip the Gatekeeper "unidentified developer"
        // dialog. No-op in dev (.build) and when already clean. See README.
        QuarantineStripper.stripSelf()

        // Refresh our LaunchServices registration for the CURRENT bundle path so the
        // http/https URL-scheme declaration (CFBundleURLTypes) is indexed and Prosper
        // shows up in System Settings → Default web browser. A bundle that moved /
        // updated / was renamed can leave a stale handler record keyed to the old path
        // (see ExtensionSystemServices.defaultBrowserBundleID's dangling-id note); a
        // self-register on launch heals it. Skipped for bare-binary dev runs so we
        // never index a throwaway .build/ or /tmp path.
        registerAsURLHandler()

        // Install a standard Edit menu so Cut/Copy/Paste/Select All/Undo/Redo
        // work in every text field across the app. We're an accessory (no menu
        // bar is shown), but NSApplication still routes a main menu's key
        // equivalents to whatever responder is key — without one, ⌘C/⌘V/⌘X/⌘Z
        // are dropped in our borderless panels (runner, clipboard, settings,
        // quicklink form, shortcut recorder). Set before any window appears.
        installEditMenu()

        // `prosper agent <prompt>` CLI: listen for kicks from CLI invocations and
        // drain prompts queued while the app was down. See AgentCLI.
        AgentCLI.observeAndDrain()

        // Warm the bundled completion lexicon (prefix/bigram/typo dictionaries)
        // off the main thread so it's ready before the first keystroke. Degrades
        // to the OS lexicon if the bundle is missing. See Autocomplete/Lexicon.
        Lexicon.warmUp()

        // Open the per-app override store (WS3), run the one-time migration of the
        // legacy scattered per-app prefs, and prime its synchronous read cache — all
        // off the main thread — so the first keystroke resolves overrides against a
        // warm cache instead of an empty one. See Autocomplete/AppOverrideStore.
        Task.detached(priority: .utility) { await AppOverrideStore.shared.warmUp() }

        // Install the off-peak LoRA training scheduler (WS6). Fires periodically; each
        // fire trains only when the machine is idle + on wall power AND the feature is
        // enabled with enough samples — otherwise a cheap no-op. See LoRATrainer.
        LoRATrainer.startScheduler()

        // Initialize the core with the persisted/default connection settings.
        CoreBridge.initialize(
            host: Preferences.coreHost,
            model: Preferences.coreModel,
            timeoutMs: Preferences.coreTimeoutMs
        )

        // Discover extensions and expose the registry to the command router so
        // migrated system extensions (calc, …) handle their queries, with the
        // native engines as fallback. See docs/ADR-002-extensibility.md.
        extensions.discover()
        // Headless self-check of the settings code paths (ordering + bookmarks FDA
        // gate). Set PROSPER_VERIFY=1 to dump and exit — used to verify on a locked
        // display where windows won't render. No effect on normal launches.
        if ProcessInfo.processInfo.environment["PROSPER_VERIFY"] != nil {
            // Async so Tier-B Lua renders can be awaited; the NSApp run loop
            // executes this Task once didFinishLaunching returns. Skip normal setup.
            Task { @MainActor in
                await ProsperVerify.run(registry: extensions)
                exit(0)
            }
            return
        }
        // Poll user extensions' update_url for newer versions (throttled to once
        // a day inside checkForUpdates). Off the launch critical path.
        Task { await extensions.checkForUpdates() }
        CommandRouter.registry = extensions
        SettingsHooks.shared.extensionRegistry = extensions
        // Opt-in resident event-tap VM (hammerspoon-compat raw eventtaps). Set the
        // registry ref before any extension's system.launch handler installs rules,
        // so the keysSetRules → refresh hook can build/evict the VM as needed.
        EventTapHost.shared.registry = extensions
        // Opt-out usage analytics (default ON; gated on Preferences.analyticsEnabled).
        AnalyticsService.shared.start()
        // Apply any cached supporter status (fail-open to free) and refresh it best-effort.
        SupporterClient.shared.startup()
        // Self-heal a stale privileged-helper registration left by a Sparkle in-place
        // update (SMAppService pins the daemon to the bundle version at register()
        // time → launchd refuses the updated binary, EX_CONFIG crash-loop, lid sleep
        // + remote wake silently dead). No-op unless the helper is already enabled.
        LidSleepHelper.healStaleRegistrationOnLaunch()
        // Cross-device settings sync (no-op unless signed in + enabled).
        SyncCoordinator.shared.startup()
        // After a pulled snapshot is written to disk, reconcile live subsystems
        // (hotkeys, extensions, agent config, UI toggles) to the synced values.
        syncAppliedObserver = NotificationCenter.default.addObserver(
            forName: .prosperSyncApplied, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reapplyAfterSync() }
        }
        // Let extensions open their own host-rendered windows (host.window.open).
        // The runner is dismissed first (the new window takes over), and the
        // window's controls dispatch back into the owning extension's VM:
        // converter panes transform synchronously; button actions run on the
        // async lane and may return a new component tree.
        LiveExtensionHostServices.shared.windowPresenter = { [weak self] extID, node in
            guard let self else { return }
            self.runnerPanel?.dismiss()
            self.extensionViewPanel.present(
                node: node,
                transform: { fn, input in
                    self.extensions.callExtensionString(extensionID: extID, function: fn, arg: input) ?? ""
                },
                onAction: { id, value, form in
                    let formJSON = (try? JSONEncoder().encode(form))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return await self.extensions.callExtensionViewAsync(
                        extensionID: extID, function: id, args: [value ?? "", formJSON])
                })
        }
        // host.window.close → dismiss the open extension window (form/dialog submit).
        LiveExtensionHostServices.shared.windowCloser = { [weak self] in
            self?.extensionViewPanel.close()
        }
        // host.settings.open(section) → restore the target sidebar pane, then show
        // the window. SettingsRootView binds the selection via @AppStorage, so
        // writing the default selects the pane whether the window is new or reused.
        LiveExtensionHostServices.shared.settingsOpener = { [weak self] selection in
            UserDefaults.standard.set(selection, forKey: "settingsSelectedPane")
            self?.openSettings()
        }
        // Snippet auto-expand toggling on (with inline autocomplete off) must bring
        // the keystroke tap up — it's the surface snippet expansion rides.
        LiveExtensionHostServices.shared.snippetConfigChanged = { [weak self] in
            self?.reconcileKeyTap()
        }
        // Durable timers: deliver a fired timer's "timer.fired" event into the
        // owning extension's serialized invoke lane, then re-arm persisted timers
        // (overdue one-shots fire once — openlid's expiry depends on it).
        TimerScheduler.shared.deliver = { [weak self] extID, handler, payload in
            Task { @MainActor in
                await self?.extensions.deliverEvent(
                    extensionID: extID, handler: handler, payloadJSON: payload)
            }
        }
        TimerScheduler.shared.restore()
        // Native system watchers (battery / network / wake / lid) broadcast their
        // events to subscribing extensions. Started once; each watcher is cheap and
        // the broadcast is a no-op when nothing subscribes.
        systemEventWatchers.emit = { [weak self] event, payload in
            self?.extensions.broadcastEvent(event, payloadJSON: payload)
        }
        // Skip building the per-switch app.activated payload when no extension wants it.
        systemEventWatchers.shouldEmit = { [weak self] event in
            self?.extensions.hasSubscribers(event) ?? false
        }
        systemEventWatchers.start()
        // A host-rendered menubar item's menu click re-invokes the extension's
        // named Lua handler on its serialized lane (stateless, like timers/events).
        ExtensionMenuBar.shared.invoke = { [weak self] extID, handler, payload in
            Task { @MainActor in
                await self?.extensions.deliverEvent(
                    extensionID: extID, handler: handler, payloadJSON: payload)
            }
        }
        // A filesystem watch (§Q) re-invokes its named handler the same way.
        ExtensionFSWatch.shared.invoke = { [weak self] extID, handler, payload in
            Task { @MainActor in
                await self?.extensions.deliverEvent(
                    extensionID: extID, handler: handler, payloadJSON: payload)
            }
        }
        // An `.invoke` key rule (hammerspoon-compat hotkeys) re-invokes its named Lua
        // handler off-main on the owning extension's lane, exactly like a timer/event.
        ExtensionKeyRules.shared.invoke = { [weak self] extID, handler, payload in
            Task { @MainActor in
                await self?.extensions.deliverEvent(
                    extensionID: extID, handler: handler, payloadJSON: payload)
            }
        }
        // Rules register during extension activation (possibly after the launch-time
        // tap check, and off-main on an extension lane). Re-reconcile the tap on every
        // change so the first key-rule extension brings the tap up regardless of order.
        ExtensionKeyRules.shared.onRulesChanged = { [weak self] in
            Task { @MainActor in self?.reconcileKeyTap() }
        }
        // A resident eventtap (hammerspoon-compat) activates AFTER its rules are set
        // (the probe runs once rules install). Re-reconcile when that flips so the tap
        // comes up for a pure-eventtap config even with inline autocomplete off.
        EventTapHost.shared.onActiveChanged = { [weak self] in
            Task { @MainActor in self?.reconcileKeyTap() }
        }
        // When Prosper is the default browser, opened links arrive as a GURL Apple
        // Event — forward them to extensions as the `url.open` event ({ url }).
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        // One-shot startup event so a stateless extension can render its menubar /
        // restore its session at launch (the equivalent of openlid's M.start()).
        extensions.broadcastEvent("system.launch")
        // Bring up the Remote Terminal (DchTerm) server if the user left it enabled.
        // No-op + harmless when off or when Tailscale isn't running.
        DchSessionServer.shared.syncToPreference()
        // Each configured quickdir contributes its own runtime mode prefix (e.g.
        // `p ` → browse ~/projects) on top of the static `qd ` trigger.
        extensions.dynamicModeProvider = { QuickdirStore.modeSpecs() }
        // An LLM-using extension toggling on/off changes whether the local model
        // must stay resident — reconcile load/unload when it does. Also re-register
        // global hotkeys: an extension-owned shortcut (e.g. Translate's ⌥L) must
        // register/unregister live as its extension is enabled/disabled.
        extensions.onEnabledChanged = { [weak self] in
            guard let self else { return }
            self.reconcileModelResidency()
            self.registerHotKeys()
            // Trust/untrust/enable/disable changes which extensions are live, so the
            // set of contributed themes changes too. Re-push it so a just-trusted
            // theme appears in the selector immediately (no relaunch). setAvailable
            // re-applies the persisted selection and suppresses no-op rebuilds.
            ThemeStore.shared.setAvailable(self.extensions.contributedThemes())
            // Drag-snap is a window-extension feature: enabling/disabling that ext
            // must start/stop its passive monitors.
            DragSnapController.shared.windowExtLive = self.windowExtLive
            DragSnapController.shared.reconcile()
        }

        // Reconcile quicklinks with their human-editable file
        // (~/.config/prosper/quicklinks.json) so external edits / imports are
        // picked up and in-app changes are mirrored back out.
        QuicklinkStore.bootstrap()
        // Same reconciliation for quickdirs (~/.config/prosper/quickdirs.json).
        QuickdirStore.bootstrap()
        // Same reconciliation for snippets (~/.config/prosper/snippets.json).
        SnippetStore.bootstrap()

        // Coding-agent MCP servers mirror to a human-editable
        // (~/.config/prosper/mcp.json), reconciled at launch and hot-reloaded on an
        // external edit/import: a clean parse replaces the loaded servers and respawns
        // the agent harness so they start/stop on the next run. A broken file is ignored.
        MCPConfigStore.bootstrap()
        mcpConfigWatcher = FileWatcher(url: MCPConfigStore.fileURL) {
            guard let servers = MCPConfigStore.reloadIfChanged() else { return }
            NotificationCenter.default.post(name: .mcpServersReloadedExternally, object: servers)
            Task { @MainActor in AgentController.shared.applyAgentConfigChange() }
        }

        // Agent personas (~/.config/prosper/agents) and slash-commands
        // (~/.config/prosper/commands) — ensure the dirs exist for external editing.
        AgentPersonaStore.bootstrap()
        CommandStore.bootstrap()

        // Same lifecycle for the agent's lifecycle hooks (~/.config/prosper/hooks.json).
        HooksConfigStore.bootstrap()
        hooksConfigWatcher = FileWatcher(url: HooksConfigStore.fileURL) {
            guard let hooks = HooksConfigStore.reloadIfChanged() else { return }
            NotificationCenter.default.post(name: .hooksReloadedExternally, object: hooks)
            Task { @MainActor in AgentController.shared.applyAgentConfigChange() }
        }

        // Bun plugin host: run opencode JS/TS plugins dropped in ~/.config/prosper/plugins
        // and bridge them to codex hooks. No-op (and no Bun download) when none present.
        if BunHarness.hasPlugins() { Task { await BunHarness.shared.start() } }

        // Status-bar menu.
        let menuBar = MenuBarController(
            onOpenRunner: { [weak self] in self?.toggleRunnerPanel() },
            onOpenClipboard: { [weak self] in self?.toggleClipboardPanel() },
            onOpenSettings: { [weak self] in self?.openSettings() },
            onCheckForUpdates: { AppUpdater.shared.checkForUpdates() },
            onRerunSetup: { [weak self] in self?.runModelSetup(force: true) },
            onQuit: { NSApp.terminate(nil) }
        )
        self.menuBar = menuBar

        // Theming. SwiftUI windows redraw themselves (the Themed{} root wrapper
        // observes ThemeStore); this hook re-skins the AppKit-only surfaces — the
        // menu-bar icon, the dock/app icon, and any open opaque window background.
        // App appearance (aqua/darkAqua) is set inside ThemeStore.apply itself.
        // setAvailable restores the persisted selection and fires onChange once.
        ThemeStore.shared.onChange = { [weak self] in self?.applyThemeToAppKit() }
        ThemeStore.shared.setAvailable(extensions.contributedThemes())

        // Settings-window side effects: keep engines/login item in sync with the
        // SwiftUI panes.
        SettingsHooks.shared.onAutocompleteChanged = { [weak self] on in self?.setAutocomplete(enabled: on) }
        // Idle auto-unload of the lazily-loaded model (Translate / host.llm) reads its
        // window from the Translate extension's settings; defaults to 2 min if unset.
        ModelIdleUnloader.shared.minutesProvider = { [weak self] in
            let raw = self?.extensions.prefValue(
                extensionID: "com.prosper.translate", key: "idle_unload_minutes")
            return ModelIdleUnloader.minutes(fromPref: raw)
        }
        // Off-main: SMAppService.register/unregister is a slow synchronous
        // syscall that froze the Settings UI when run on the main runloop tick.
        // The toggle already flips optimistically, so the UI stays snappy.
        SettingsHooks.shared.onLaunchAtLoginChanged = { on in
            Task.detached(priority: .userInitiated) { LaunchAtLogin.setEnabled(on) }
        }
        SettingsHooks.shared.onClipboardHistoryChanged = { [weak self] on in self?.setClipboardHistory(enabled: on) }
        SettingsHooks.shared.onClipboardMaxItemsChanged = { ClipboardStore.shared.applyMaxItemsChange() }

        // Reconcile login-item registration with the persisted preference.
        LaunchAtLogin.syncWithPreference()

        // Live model switch: the picker writes the pref; we unload the old model and
        // download-if-needed + reload the new one, no restart. See ModelSetup.runSwitch.
        SettingsHooks.shared.onModelChanged = { [weak self] _ in self?.switchModel() }

        // Side-effect hook: re-register hotkeys when the user rebinds them.
        SettingsHooks.shared.onShortcutsChanged = { [weak self] in self?.registerHotKeys() }
        SettingsHooks.shared.onCheckForUpdates = { AppUpdater.shared.checkForUpdates() }
        SettingsHooks.shared.onMenuBarIconChanged = { [weak self] visible in
            self?.menuBar?.setIconVisible(visible)
        }
        // Toggling the Dock-icon preference reconciles the activation policy at
        // once: enabling it shows the icon if a window is already open, disabling
        // it drops back to a pure accessory agent.
        SettingsHooks.shared.onDockIconChanged = { _ in DockPolicy.preferenceChanged() }
        // Drag-to-snap window management: toggling reconciles its passive mouse
        // monitors (prompting for Accessibility on enable, like autocomplete).
        SettingsHooks.shared.onDragSnapChanged = { [weak self] on in self?.setDragSnap(enabled: on) }

        // Accessory button (opt-in) refreshes the ghost suggestion — same as ⌥.
        // (a fresh completion for the focused field, lifting any Esc suppression).
        autocomplete.onAccessoryClicked = { [weak self] in self?.autocomplete.refreshSuggestion() }

        // Offer to move into /Applications on first launch from elsewhere.
        AppRelocator.offerIfNeeded()

        // Register global hotkeys from the (rebindable) shortcut store.
        registerHotKeys()

        // Start Sparkle (background update checks per Info.plist + preference).
        _ = AppUpdater.shared

        // Start clipboard capture if enabled (off by default).
        if Preferences.clipboardHistoryEnabled {
            ClipboardMonitor.shared.start()
        }

        // Only preload the language model when inline autocomplete is on —
        // that's the one path where a cold load on the first keystroke is
        // user-visible. The model is the app's largest memory consumer (~4 GB
        // resident). Model-requiring extensions (e.g. Translate) load it
        // LAZILY on first use, so a fresh boot with autocomplete off stays
        // lightweight (~120 MB) even when Translate is enabled. Autocomplete +
        // coding agent are off by default; when a user enables one, General
        // settings surfaces a clickable warning if the needed grant is missing
        // (no first-run wizard — see GeneralPane).
        if Preferences.autocompleteEnabled {
            runModelSetup(force: false)
        }
        startAutocompleteIfReady()
        // Drag-to-snap rides its own passive monitors (NOT the keystroke tap); start
        // them if enabled, the window extension is live, and Accessibility is trusted.
        DragSnapController.shared.windowExtLive = windowExtLive
        DragSnapController.shared.reconcile()

        // E2E handshake (gated by PROSPER_E2E=1): tell the launching test process
        // whether the keystroke tap is live so it can proceed — or skip with a
        // clear reason — instead of polling blindly. See the e2e ProsperAppRunner.
        if ProcessInfo.processInfo.environment["PROSPER_E2E"] == "1" {
            let trusted = PermissionsManager.isAccessibilityTrusted()
            FileHandle.standardError.write(Data(
                "PROSPER_E2E_READY accessibility=\(trusted) tap=\(autocomplete.isRunning)\n".utf8))
        }
    }

    /// Reconcile live subsystems with preferences/files that a settings-sync pull
    /// just wrote. Mirrors the launch-time wiring: re-register hotkeys, re-bootstrap
    /// the file-backed stores, hot-reload agent config, re-discover extensions, and
    /// re-apply the UI/engine toggles to the now-synced preference values. Idempotent.
    @MainActor
    private func reapplyAfterSync() {
        // Global hotkeys (shortcut.* keys may have changed).
        registerHotKeys()

        // File-backed stores reconcile from the freshly written files.
        QuicklinkStore.bootstrap()
        QuickdirStore.bootstrap()
        AgentPersonaStore.bootstrap()
        CommandStore.bootstrap()
        if let servers = MCPConfigStore.reloadIfChanged() {
            NotificationCenter.default.post(name: .mcpServersReloadedExternally, object: servers)
        }
        if let hooks = HooksConfigStore.reloadIfChanged() {
            NotificationCenter.default.post(name: .hooksReloadedExternally, object: hooks)
        }
        AgentController.shared.applyAgentConfigChange()

        // Synced user extensions/plugins: re-discover (discover() also drops the
        // cached off-main Lua VMs via asyncRuntimes.invalidateAll()).
        extensions.discover()

        // UI / engine toggles reconcile to the (now-synced) preferences.
        menuBar?.setIconVisible(Preferences.showMenuBarIcon)
        DockPolicy.preferenceChanged()
        LaunchAtLogin.syncWithPreference()
        ClipboardStore.shared.applyMaxItemsChange()
        setAutocomplete(enabled: Preferences.autocompleteEnabled)
        setClipboardHistory(enabled: Preferences.clipboardHistoryEnabled)
    }

    /// Builds the app's main menu with a single standard Edit submenu. The items
    /// target the first-responder action selectors (`copy:`, `paste:`, …) with
    /// `nil` target, so AppKit dispatches them up the responder chain to whatever
    /// field editor is active. This is what makes the common text-editing
    /// shortcuts work in our windowless/borderless panels, where there is no menu
    /// bar to provide them. Idempotent — safe to call once on launch.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)

        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    /// (Re)registers all global hotkeys from the rebindable `ShortcutStore`.
    /// Every trigger — the command-runner triggers (⌘Space, ⌥Space, plus a spare
    /// slot), Translate (⌥L), Open Settings (⌥\), clipboard, window management —
    /// is rebindable and clearable. Safe to call again after a rebind — it tears
    /// down and rebuilds the whole set.
    /// GURL Apple Event (a link opened while Prosper is the default browser). Forward
    /// the URL to extensions as `url.open`; a url-dispatcher extension then rewrites or
    /// re-opens it in the real browser. With no handler extension the link is dropped
    /// — only set Prosper default once such an extension is enabled.
    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let data = try? JSONSerialization.data(withJSONObject: ["url": urlString]),
              let payload = String(data: data, encoding: .utf8) else { return }
        extensions.broadcastEvent("url.open", payloadJSON: payload)
    }

    /// Re-register this bundle with LaunchServices so its declared http/https
    /// URL-scheme handling is enumerated in the Default-web-browser picker.
    /// LSUIElement does NOT exclude us from that list (it gates Dock/Cmd-Tab
    /// presentation only) — picker membership is driven purely by CFBundleURLTypes
    /// + a live registration, so a stale/missing record is the real cause of
    /// "Prosper doesn't appear". No-op unless we're running from a real `.app`
    /// wrapper (a bare-binary dev run would otherwise register a throwaway path).
    private func registerAsURLHandler() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return }
        LSRegisterURL(bundleURL as CFURL, true)
    }

    /// Re-skin the AppKit-only surfaces for the active theme. SwiftUI windows
    /// handle themselves via the Themed{} wrapper; these have no SwiftUI host.
    private func applyThemeToAppKit() {
        let store = ThemeStore.shared
        // Menu-bar icon: themed image or the bundled default (nil → default).
        menuBar?.setMenuBarImage(store.image("menuBarIcon"))
        // Dock / app icon: nil restores the app bundle's icon.
        NSApp.applicationIconImage = store.image("appIcon")
        // Already-open opaque windows (Settings/Chat/ModelSetup): refresh
        // their backdrop. ponytail: keyed on opacity so we never paint over the
        // borderless transparent panels (runner/clipboard) — they read Neon via
        // SwiftUI and redraw themselves.
        let bg = NSColor(Neon.bgTop)
        for win in NSApp.windows where win.backgroundColor.alphaComponent > 0.9 {
            win.backgroundColor = bg
        }
        // Themed windows (Settings) also follow the live opacity + UI-size settings:
        // flip opaque/clear for transparency and rescale the minimum content size so
        // the scaled sidebar + content column always fit. Borderless floating panels
        // (runner/clipboard) are already transparent and redraw themselves via SwiftUI.
        let scale = ThemeRuntime.scale
        for win in NSApp.windows {
            switch win.identifier {
            case SettingsWindow.themedIdentifier:
                SettingsWindow.applyWindowOpacity(win)
                win.contentMinSize = NSSize(width: 820 * scale, height: 480 * scale)
            case ChatWindow.themedIdentifier:
                SettingsWindow.applyWindowOpacity(win)
                win.contentMinSize = NSSize(width: 560 * scale, height: 520 * scale)
            default:
                break
            }
        }
    }

    private func registerHotKeys() {
        hotKeys.forEach { $0.unregister() }
        hotKeys.removeAll()

        // The command-runner triggers (⌘Space main, ⌥Space alt 1, alt 2 unset)
        // open the universal launcher (apps + commands), no prefix assumed.
        // Translate has its own trigger (⌥L), and Settings opens on ⌥\.
        // Translate is now a Lua system extension (com.prosper.translate). Its ⌥L
        // hotkey opens the universal launcher prefilled with the extension's "l "
        // mode prefix, which the runner resolves into the Translate mode.
        let toggleTranslate: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.toggleRunnerPanel(mode: .universal, prefill: "l ") }
        }
        let toggle: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.toggleRunnerPanel(mode: .universal) }
        }
        let toggleClipboard: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.toggleClipboardPanel() }
        }
        let openSettings: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.openSettings() }
        }
        let openAgent: () -> Void = {
            DispatchQueue.main.async { ChatWindow.shared.show() }
        }
        let toggleAutocomplete: () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.setAutocomplete(enabled: !Preferences.autocompleteEnabled) }
        }

        // (hotkey, human label) pairs so a registration conflict can name the
        // offending binding to the user. Every combo is read from the store and
        // skipped when it has no modifier (unset / cleared by the user) so a
        // disabled shortcut never registers a bare key.
        var bound: [(key: GlobalHotKey, label: String)] = []
        func add(_ action: ShortcutAction, _ handler: @escaping () -> Void) {
            // An extension-owned shortcut (e.g. Translate's ⌥L) is skipped while its
            // extension is disabled, so a dead binding never claims the combo.
            guard action.isAvailable(registry: extensions) else { return }
            let combo = ShortcutStore.combo(for: action)
            guard combo.carbonModifiers != 0 else { return }
            bound.append(
                (GlobalHotKey(keyCode: combo.keyCode, modifiers: combo.carbonModifiers,
                              id: action.hotKeyId, handler: handler),
                 "\(action.title) (\(combo.display))")
            )
        }

        // Command runner (universal launcher) on its three rebindable triggers,
        // translate on its own, settings on its own. All rebindable / clearable.
        add(.runner, toggle)
        add(.runnerSpace, toggle)
        add(.runnerBackslash, toggle)
        add(.translate, toggleTranslate)
        add(.settings, openSettings)
        add(.clipboard, toggleClipboard)
        add(.agent, openAgent)
        add(.toggleAutocomplete, toggleAutocomplete)

        // Built-in window management: snap the frontmost window to a screen edge,
        // maximize, or centre it. Applied via Accessibility to whatever app is
        // frontmost when the shortcut fires.
        let windowActions: [(action: ShortcutAction, op: WindowAction)] = [
            (.windowLeftHalf, .leftHalf),
            (.windowRightHalf, .rightHalf),
            (.windowTopHalf, .topHalf),
            (.windowBottomHalf, .bottomHalf),
            (.windowMaximize, .maximize),
            (.windowCenter, .center),
        ]
        for entry in windowActions {
            let op = entry.op
            add(entry.action) { DispatchQueue.main.async { WindowManager.perform(op) } }
        }

        // User-defined custom shortcuts: each opens the runner pre-seeded with
        // its activation prefix (no need to type "o ", ">", etc.). Ids start at
        // 100 to stay clear of the fixed action ids above.
        for (i, cs) in ShortcutStore.customShortcuts().enumerated() {
            // Skip not-yet-recorded combos (no modifier) so we never register a
            // bare key that would swallow ordinary typing.
            guard cs.combo.carbonModifiers != 0 else { continue }
            let prefix = cs.prefix
            bound.append(
                (GlobalHotKey(keyCode: cs.combo.keyCode, modifiers: cs.combo.carbonModifiers,
                              id: UInt32(100 + i)) { [weak self] in
                    DispatchQueue.main.async { self?.openRunner(prefill: prefix) }
                },
                 "\(cs.label) (\(cs.combo.display))")
            )
        }

        // Extension-contributed global hotkeys (`[[contributes.keybindings]]`):
        // each maps a key string to a command id that the host runs through normal
        // dispatch on press — no Lua callback, no resident VM (host API plan §C).
        // Ids start at 300 to stay clear of the fixed + custom-shortcut ids above.
        var hotkeyIndex = 0
        for record in extensions.records where record.isLive {
            for kb in record.manifest.contributes?.allKeybindings ?? [] {
                guard let combo = KeyCombo.parse(kb.key), combo.carbonModifiers != 0 else { continue }
                let command = kb.command
                bound.append(
                    (GlobalHotKey(keyCode: combo.keyCode, modifiers: combo.carbonModifiers,
                                  id: UInt32(300 + hotkeyIndex)) { [weak self] in
                        Task { @MainActor in _ = await self?.extensions.invokeAsync(commandID: command, query: "") }
                    },
                     "\(record.manifest.extension.title) · \(combo.display)")
                )
                hotkeyIndex += 1
            }
        }

        hotKeys = bound.map(\.key)
        reportHotKeyConflicts(bound.filter { !$0.key.isRegistered }.map(\.label))

        // Reserve every successfully-registered native chord so an extension key
        // rule (hammerspoon-compat) on the same chord yields to the dedicated Carbon
        // hotkey instead of swallowing it in the shared tap (e.g. openlid's
        // cmd+alt+ctrl+l). Only registered ones — an unclaimed combo should still
        // let a shim rule handle it.
        let reserved = Set(hotKeys.filter(\.isRegistered).map {
            KeyChord(carbonKeyCode: $0.keyCode, carbonModifiers: $0.modifiers)
        })
        ExtensionKeyRules.shared.setReservedChords(reserved)

        // Load the user's native shortcut rules into the shared engine (idempotent;
        // empty by default). Done after reserving chords so a native shortcut never
        // shadows a registered Carbon hotkey.
        ShortcutRulesStore.shared.apply()
    }

    /// Warns the user once when one or more global hotkeys could not be claimed.
    /// The usual cause is another launcher (Raycast owns ⌥Space by default,
    /// Spotlight/Alfred, etc.) already holding the combo — macOS gives the combo
    /// to whoever registered first, so ours silently never fires. We surface the
    /// conflict so the user can rebind in Settings → Shortcuts or free it up in
    /// the other app, instead of staring at a dead shortcut.
    private func reportHotKeyConflicts(_ labels: [String]) {
        guard !labels.isEmpty else { return }
        NSLog("prosper: hotkey conflicts (already claimed by another app): \(labels.joined(separator: ", "))")
        guard Bundle.main.bundleIdentifier != nil else { return } // no UNUserNotification in CLI runs
        let content = UNMutableNotificationContent()
        content.title = "Prosper: shortcut unavailable"
        content.body = labels.count == 1
            ? "\(labels[0]) is already used by another app. Rebind it in Settings → Shortcuts."
            : "These shortcuts are already used by other apps: \(labels.joined(separator: ", ")). Rebind them in Settings → Shortcuts."
        let request = UNNotificationRequest(identifier: "prosper.hotkey.conflict", content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            if granted { center.add(request) }
        }
    }

    /// Opens the command runner from a custom shortcut. The shortcut's activation
    /// prefix is mapped to a locked runner mode (e.g. "o " → openApp, "l " →
    /// translate) so the user lands inside that capability with no prefix to type.
    /// Prefixes without a dedicated mode (":", "base64 ", blank) open the universal
    /// runner pre-seeded with the prefix.
    private func openRunner(prefill: String) {
        // Window-launching extension commands (manifest `launches_window`) bound to a
        // custom shortcut fire IMMEDIATELY — no visible runner, no typed prefix. The
        // handler opens its own window via host.window.open (→ windowPresenter).
        if let routed = extensions.route(query: prefill), routed.command.launchesWindow {
            let id = routed.command.id
            Task { @MainActor in _ = await self.extensions.invokeAsync(commandID: id, query: prefill) }
            return
        }
        let panel = runnerPanel ?? RunnerPanel()
        runnerPanel = panel
        if let (mode, stripped) = ModeTrigger.resolve(prefill) {
            panel.present(mode: mode, prefill: stripped)
        } else {
            panel.present(prefill: prefill)
        }
    }

    private func startAutocompleteIfReady() {
        reconcileKeyTap()
    }

    /// The single CGEvent keystroke tap (owned by AutocompleteEngine) is shared:
    /// inline autocomplete AND extension key rules (hammerspoon-compat hotkeys /
    /// remaps / double-taps) both ride it. Run it when EITHER needs it — so a
    /// trusted key-rule extension works even with inline autocomplete switched off
    /// (the previous coupling left the tap down and silently killed all key rules).
    /// Idempotent: start()/stop() no-op when already in the desired state.
    /// Pure rule for whether the shared CGEvent keystroke tap must run. Four
    /// independent consumers ride it — inline autocomplete, native `ExtensionKeyRules`,
    /// resident `hs.eventtap` callbacks, and snippet auto-expansion — and it runs if
    /// ANY needs it. Extracted + unit-tested precisely because the "every shortcut
    /// dead" bug was a dropped term here (`eventTaps`), which silently kept the tap
    /// down for pure-eventtap configs; the `snippets` term has the same failure mode
    /// (snippets dead whenever inline autocomplete is off).
    static func needKeyTap(autocomplete: Bool, extRules: Bool, eventTaps: Bool, snippets: Bool) -> Bool {
        autocomplete || extRules || eventTaps || snippets
    }

    func reconcileKeyTap() {
        let acEnabled = Preferences.autocompleteEnabled
        let extRules = !ExtensionKeyRules.shared.isEmpty
        // A pure-`hs.eventtap` config (no native key rules) needs the tap too — it is
        // the surface those raw callbacks ride. Without this term the tap stays down
        // when autocomplete is off and the only consumer is a resident eventtap.
        let eventTaps = EventTapHost.shared.isActive
        // Snippet auto-expansion rides the same tap. Without this term the tap stays
        // down when autocomplete is off and snippets are the only consumer.
        let snippets = Preferences.snippetsEnabled && Preferences.snippetsAutoExpand
        let needTap = Self.needKeyTap(autocomplete: acEnabled, extRules: extRules, eventTaps: eventTaps, snippets: snippets)
        let trusted = PermissionsManager.isAccessibilityTrusted()
        NSLog("prosper: reconcileKeyTap autocomplete=%d extRules=%d eventTaps=%d snippets=%d needTap=%d axTrusted=%d",
              acEnabled, extRules, eventTaps, snippets, needTap, trusted)
        if needTap {
            if trusted { _ = autocomplete.start() }
            else { NSLog("prosper: key tap needed but Accessibility not trusted — tap not started") }
        } else {
            autocomplete.stop()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        autocomplete.stop()
        hotKeys.forEach { $0.unregister() }
        BunHarness.shared.shutdown()
        // Release every extension's native resources (power assertions, pmset lid
        // override) so a "disable sleep" can never outlive the app.
        for record in extensions.records {
            LiveExtensionHostServices.shared.resetResources(extensionID: record.id)
        }
    }

    // MARK: - Actions

    private func toggleRunnerPanel(mode: RunnerMode = .universal, prefill: String? = nil) {
        if let panel = runnerPanel, panel.isShown {
            panel.dismiss()
            return
        }
        let panel = runnerPanel ?? RunnerPanel()
        runnerPanel = panel
        panel.present(mode: mode, prefill: prefill ?? "")
    }

    private func toggleClipboardPanel() {
        if let panel = clipboardPanel, panel.isShown {
            panel.dismiss()
            return
        }
        let panel = clipboardPanel ?? ClipboardPanel(onOpenSettings: { [weak self] in self?.openSettings() })
        clipboardPanel = panel
        panel.present()
    }

    private func openSettings() {
        let window = settingsWindow ?? SettingsWindow()
        settingsWindow = window
        window.show()
    }

    private func setClipboardHistory(enabled: Bool) {
        Preferences.clipboardHistoryEnabled = enabled
        if enabled {
            ClipboardMonitor.shared.start()
        } else {
            ClipboardMonitor.shared.stop()
        }
    }

    /// Whether the window extension is enabled + trusted. Drag-snap is one of its
    /// features, so it only runs while the extension is live.
    private var windowExtLive: Bool {
        extensions.record(id: "com.prosper.window")?.isLive ?? false
    }

    private func setDragSnap(enabled: Bool) {
        Preferences.dragSnapEnabled = enabled
        // Prompt for Accessibility on enable so the monitors can read/move windows.
        if enabled { _ = PermissionsManager.ensureAccessibilityTrust(prompt: true) }
        DragSnapController.shared.windowExtLive = windowExtLive
        DragSnapController.shared.reconcile()
    }

    private func setAutocomplete(enabled: Bool) {
        Preferences.autocompleteEnabled = enabled
        // Prompt for Accessibility on enable so the tap can actually start.
        if enabled { _ = PermissionsManager.ensureAccessibilityTrust(prompt: true) }
        // Reconcile the shared tap from BOTH inputs (autocomplete pref + extension
        // key rules) — disabling inline autocomplete must NOT tear the tap down
        // while a key-rule extension still needs it.
        reconcileKeyTap()
        // Reconcile after the toggle: load/preload when any LLM consumer is on,
        // unload the multi-GB weights when none remain. Lightweight off-state.
        reconcileModelResidency()
    }

    /// True when a feature needs the local AI model resident *continuously*: only
    /// inline autocomplete, which would otherwise pay a user-visible cold load on
    /// the first keystroke. Model-requiring extensions (e.g. Translate) do NOT keep
    /// it resident — they load it lazily on first use (CommandRouter.runExtension
    /// awaits the load; host.llm callers go through `CoreBridge`, which ensure-loads),
    /// so keeping multi-GB resident just because such an extension is *enabled* is
    /// wasted memory. When false the weights can be freed.
    private func shouldKeepModelResident() -> Bool {
        Preferences.autocompleteEnabled
    }

    /// Reconcile model residency after a toggle. Two independent concerns:
    ///   • Unload: free the multi-GB weights when inline autocomplete is off.
    ///     Model-requiring extensions load lazily on demand, so they don't pin the
    ///     weights — disabling autocomplete frees them even with Translate enabled.
    ///   • Preload: warm the model eagerly ONLY for inline autocomplete, where a
    ///     cold load on the first keystroke is user-visible. Extensions like
    ///     Translate load the model LAZILY on first use (MLXEngine loads on
    ///     demand), so merely enabling Translate must NOT cost 4 GB at idle — the
    ///     lightweight boot is preserved.
    /// Called on autocomplete toggle and on `extensions.onEnabledChanged`.
    private func reconcileModelResidency() {
        if shouldKeepModelResident() {
            // Autocomplete owns residency now — drop any pending idle unload AND any
            // deferred forced unload (a disable→enable toggle during a generation could
            // otherwise free the model the moment that generation finishes).
            ModelIdleUnloader.shared.cancel()
            Task { await MLXEngine.shared.cancelPendingUnload() }
            // Download if missing + warm so the first completion isn't a cold load.
            runModelSetup(force: false)
        } else {
            // requestUnload (not unload) so disabling autocomplete mid-completion defers
            // the free until that generation finishes instead of clearing GPU buffers
            // under an active compute.
            Task { await MLXEngine.shared.requestUnload() }
        }
    }

    private func runModelSetup(force: Bool) {
        let setup = modelSetup ?? ModelSetup()
        modelSetup = setup
        setup.runIfNeeded(force: force) { [weak self] ok in
            // Cancelled/failed download with no model on disk → drop to "None" and
            // turn inline completions off (can't complete without weights).
            if !ok, ModelFiles.firstDownloadedModel() == nil {
                self?.dropToNoModel()
            }
        }
    }

    /// Live-switch to the model just chosen in Settings: shows the setup window and
    /// unloads the old model, then downloads-if-needed + loads + warms the new one
    /// (plus its draft/adapter). No app restart. Wired to `onModelChanged`.
    private func switchModel() {
        // Remember the model that was actually active before this switch so we can
        // restore it if the user cancels (or the download fails).
        let previous = ModelFiles.firstDownloadedModel()
        let setup = modelSetup ?? ModelSetup()
        modelSetup = setup
        setup.runSwitch { [weak self] ok in
            guard !ok else { return }
            self?.revertModelSelection(previous: previous)
        }
    }

    /// Revert after a cancelled/failed switch. Prefer the previously-active model;
    /// otherwise the first downloaded model; otherwise "None" (completions off).
    private func revertModelSelection(previous: String?) {
        let fallback = previous ?? ModelFiles.firstDownloadedModel()
        guard let fallback else { dropToNoModel(); return }
        Preferences.coreModel = fallback
        SettingsHooks.shared.revertModelSelection?(fallback)
        // Reload the fallback (already on disk → fast, no UI needed).
        CoreBridge.switchModel(progress: { _ in }, completion: { _ in })
    }

    /// No model available: select "None" in the picker and force inline completions
    /// off — without weights they can't run.
    private func dropToNoModel() {
        Preferences.coreModel = ""
        SettingsHooks.shared.revertModelSelection?(nil)
        setAutocomplete(enabled: false)
    }
}
