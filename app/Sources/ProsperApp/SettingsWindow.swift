import AppKit
import Charts
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Hosts the SwiftUI Settings window, toggled from the menu bar (⌘,). The
/// window is built on open and torn down on close (a closed-but-alive hosting
/// view keeps rendering and burns CPU); its frame persists via autosave.
@MainActor
final class SettingsWindow {

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// Identifies the Settings window so the theme onChange hook can re-skin it.
    static let themedIdentifier = NSUserInterfaceItemIdentifier("prosper.themedWindow")

    /// Apply the current `ThemeRuntime.opacity` to a window: below 1.0 it goes
    /// non-opaque so the SwiftUI backdrop's faded fill lets the desktop through;
    /// at 1.0 it stays the original opaque neon console.
    /// Idempotent — safe to call repeatedly from the theme onChange hook.
    static func applyWindowOpacity(_ win: NSWindow) {
        // Frost forces non-opaque even at full opacity: the SwiftUI backdrop's
        // `.behindWindow` blur can only sample the desktop through a non-opaque window.
        let frost = ThemeRuntime.frost
        let opaque = !frost && ThemeRuntime.opacity >= 0.999
        win.isOpaque = opaque
        // The titlebar strip is painted ONLY by the window background (content view
        // doesn't extend under it — no .fullSizeContentView). A `.clear` bg made the
        // titlebar vanish entirely below 1.0; fill it with bgTop at the live opacity
        // (or the frost tint) so it stays slightly translucent, matching the backdrop.
        win.backgroundColor = opaque
            ? NSColor(Neon.bgTop)
            : NSColor(Neon.bgTop).withAlphaComponent(ThemeRuntime.backdropFillOpacity)
        win.invalidateShadow()
    }

    func show() {
        if let window {
            DockPolicy.windowDidShow(window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = SettingsRootView()
        let hosting = NSHostingController(rootView: Themed { root })
        // Don't let SwiftUI drive the window size. On macOS 13+ NSHostingController
        // defaults to growing the window to the view's intrinsic height, so a tall
        // pane (the openlid Remote Wake section with its help expanded) stretched the
        // window past the screen — its bottom rows drew offscreen and the NeonScroll
        // never scrolled because it was handed all the height it asked for. The frame
        // is managed manually below (explicit size + min/max + autosave); an empty
        // sizingOptions keeps it that way and lets the inner ScrollView do the work.
        hosting.sizingOptions = []
        let win = CommandWClosableWindow(contentViewController: hosting)
        win.title = "Prosper Settings"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // The window is a dark, full-bleed neon console: a vertical sidebar owns
        // navigation and the content area paints its own cyberpunk backdrop. Hide
        // the title, make the titlebar transparent, and paint the frame in the
        // backdrop's top color so the titlebar dissolves into the UI. Force dark
        // aqua so system controls (segmented pickers, fields) match the theme.
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.appearance = NSAppearance(named: .darkAqua)
        // Tagged so the theme onChange hook (AppDelegate) can find this window to
        // re-apply opacity + scaled min-size live when the user changes them.
        win.identifier = SettingsWindow.themedIdentifier
        let scale = ThemeRuntime.scale
        win.setContentSize(NSSize(width: 900 * scale, height: 640 * scale))
        // The sidebar (218·scale) plus the content column need ~820·scale minimum;
        // height is free so the window can grow to show more rows. Width is now
        // resizable (the sidebar + scrolling cards reflow).
        win.contentMinSize = NSSize(width: 820 * scale, height: 480 * scale)
        SettingsWindow.applyWindowOpacity(win)
        win.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
        win.isReleasedWhenClosed = false
        win.setFrameAutosaveName("ProsperSettingsWindow")
        if !win.setFrameUsingName("ProsperSettingsWindow") {
            win.centerOnScreen()
        }
        window = win
        // Standard windows close via the title-bar button / ⌘W (performClose),
        // which posts willClose rather than going through an orderOut funnel — so
        // hide the Dock icon from here when the settings window is dismissed.
        // Also tear the window down: the hosting view of an ordered-out window
        // keeps rendering (timers/TimelineView schedules don't pause for it),
        // which burned ~1% CPU forever after the first open. Dropping every
        // strong reference deallocates the SwiftUI tree; the next open rebuilds
        // it and the frame autosave name restores the position.
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
                // references, and its hosting view would keep rendering.
                DispatchQueue.main.async { win.contentViewController = nil }
            }
        }
        DockPolicy.windowDidShow(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}

/// NSWindow that closes on ⌘W. As a menu-bar agent (LSUIElement) Prosper has no
/// standard File ▸ Close menu item, so the system ⌘W never reaches this window —
/// we handle the key equivalent ourselves. `performClose` honors the close button;
/// the willClose observer then drops the window so it deallocates.
private final class CommandWClosableWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Match ⌘W by virtual keycode (kVK_ANSI_W), not character: under a non-Latin
        // layout charactersIgnoringModifiers is the layout glyph ("в" on Bulgarian), so
        // a char check misses our synthetic ⌘W. The W key's keycode is layout-independent.
        if event.modifierFlags.contains(.command),
           event.keyCode == 13 || event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Tab / ⇧Tab cycle the sidebar sections (forward / backward) so the whole
    /// window is keyboard-navigable. While a text field is being edited the Tab
    /// goes to the field editor as usual (form navigation stays intact).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 48 /* Tab */ {
            let editingText = firstResponder is NSText || firstResponder is NSTextView
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !editingText, mods.isSubset(of: [.shift]) {
                NotificationCenter.default.post(
                    name: .prosperSettingsCycleSection, object: nil,
                    userInfo: ["delta": mods.contains(.shift) ? -1 : 1])
                return
            }
        }
        super.sendEvent(event)
    }
}

extension Notification.Name {
    /// Posted by the settings window on Tab/⇧Tab; userInfo["delta"] is +1/-1.
    static let prosperSettingsCycleSection = Notification.Name("prosper.settings.cycleSection")
}

// MARK: - Model

/// Bridges `Preferences` (UserDefaults) to SwiftUI. Each property's setter
/// persists immediately and notifies observers.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var autocompleteEnabled: Bool { didSet { Preferences.autocompleteEnabled = autocompleteEnabled } }
    /// Master switch for the coding agent. Toggling it shows/hides the whole
    /// "Coding Agent" settings category and the menu-bar entry.
    @Published var agentEnabled: Bool { didSet { Preferences.agentEnabled = agentEnabled } }
    @Published var completionsEnabledByDefault: Bool { didSet { Preferences.completionsEnabledByDefault = completionsEnabledByDefault } }
    @Published var completionLength: CompletionLength { didSet { Preferences.completionLength = completionLength } }
    @Published var customInstructions: String { didSet { Preferences.customInstructions = customInstructions } }
    @Published var userName: String { didSet { Preferences.userName = userName } }
    @Published var userLanguages: String { didSet { Preferences.userLanguages = userLanguages } }
    @Published var voiceStyle: String { didSet { Preferences.voiceStyle = voiceStyle } }
    @Published var launchAtLogin: Bool
    @Published var clipboardHistoryEnabled: Bool
    @Published var clipboardHistoryMaxItems: Int {
        didSet {
            Preferences.clipboardHistoryMaxItems = clipboardHistoryMaxItems
            onClipboardMaxItemsChanged?()
        }
    }
    @Published var useClipboardContext: Bool { didSet { Preferences.useClipboardContext = useClipboardContext } }
    @Published var quickSelectModifier: QuickSelectModifier { didSet { Preferences.quickSelectModifier = quickSelectModifier } }
    @Published var midlineCompletionsEnabled: Bool { didSet { Preferences.midlineCompletionsEnabled = midlineCompletionsEnabled } }
    @Published var emojiSuggestionsEnabled: Bool { didSet { Preferences.emojiSuggestionsEnabled = emojiSuggestionsEnabled } }
    @Published var suppressOnTypo: Bool { didSet { Preferences.suppressOnTypo = suppressOnTypo } }
    @Published var trailingSpaceAfterWordAccept: Bool { didSet { Preferences.trailingSpaceAfterWordAccept = trailingSpaceAfterWordAccept } }
    /// Set while reverting the picker after a cancelled/failed switch so the
    /// `coreModel` write doesn't re-fire `onModelChanged` (which would loop).
    private var suppressModelHook = false
    @Published var coreModel: String {
        didSet {
            guard coreModel != oldValue else { return }
            Preferences.coreModel = coreModel
            if suppressModelHook { return }
            // Live switch: download-if-needed + reload the new model (no restart).
            SettingsHooks.shared.onModelChanged?(coreModel)
        }
    }

    /// Reflects an externally-driven model change in the picker WITHOUT triggering
    /// a new switch. `nil` ⇒ "None" (no model downloaded) and inline completions
    /// are forced off.
    func revertCoreModel(to id: String?) {
        suppressModelHook = true
        coreModel = id ?? ""
        if id == nil { autocompleteEnabled = false }
        suppressModelHook = false
    }

    /// Coding-agent model. Swapped in (residency swap) only when agent work runs, so
    /// changing it never disturbs the resident inline model — no live-switch hook.
    @Published var agentModel: String { didSet { Preferences.agentModel = agentModel } }

    /// Remote Terminal (DchTerm). Set via the methods below so the server start/stop
    /// side-effect runs only on user action, not during init.
    @Published var remoteTerminalEnabled: Bool
    @Published var isolateRemoteSessions: Bool

    func setRemoteTerminal(_ on: Bool) {
        remoteTerminalEnabled = on
        Preferences.remoteTerminalEnabled = on
        DchSessionServer.shared.syncToPreference()
    }
    func setIsolateRemoteSessions(_ on: Bool) {
        isolateRemoteSessions = on
        Preferences.isolateRemoteSessions = on
    }

    /// MCP servers for the coding agent. Persisted on every mutation; rendered into
    /// codex config.toml on the next harness spawn (changes apply to new runs).
    @Published var mcpServers: [MCPServer] {
        didSet { Preferences.mcpServers = mcpServers; MCPConfigStore.writeFile(mcpServers) }
    }
    /// Lifecycle hooks for the coding agent. Same lifecycle as `mcpServers`: persisted
    /// + mirrored to hooks.json on mutation, rendered into config.toml on next spawn.
    @Published var hooks: [HookRule] {
        didSet { Preferences.hooks = hooks; HooksConfigStore.writeFile(hooks) }
    }
    /// Token for the external-edit observer so the open Settings UI refreshes when
    /// `mcp.json` is edited/imported out-of-band. Removed on deinit.

    @Published var collectTypingHistory: Bool { didSet { Preferences.collectTypingHistory = collectTypingHistory } }
    @Published var personalizeWordChoice: Double { didSet { Preferences.personalizeWordChoice = personalizeWordChoice } }

    @Published var useScreenshotContext: Bool { didSet { Preferences.useScreenshotContext = useScreenshotContext } }
    @Published var useOCRContext: Bool { didSet { Preferences.useOCRContext = useOCRContext } }
    @Published var improveAppearanceFromScreenshot: Bool { didSet { Preferences.improveAppearanceFromScreenshot = improveAppearanceFromScreenshot } }
    @Published var showAccessoryButton: Bool { didSet { Preferences.showAccessoryButton = showAccessoryButton } }
    @Published var dismissOverlaysOnClick: Bool { didSet { Preferences.dismissOverlaysOnClick = dismissOverlaysOnClick } }
    @Published var showSuggestedFixes: Bool { didSet { Preferences.showSuggestedFixes = showSuggestedFixes } }
    /// Opt-out usage analytics. Flipping on (re)starts the daily sender; off stops it.
    @Published var analyticsEnabled: Bool {
        didSet {
            Preferences.analyticsEnabled = analyticsEnabled
            if analyticsEnabled { AnalyticsService.shared.start() }
        }
    }
    @Published var emojiSkinTone: EmojiSkinTone { didSet { Preferences.emojiSkinTone = emojiSkinTone } }
    @Published var emojiGender: EmojiGender { didSet { Preferences.emojiGender = emojiGender } }
    @Published var showMenuBarIcon: Bool
    @Published var showDockIcon: Bool
    @Published var improveCompatBundleIds: [String]

    // Drag-to-snap window management. `dragSnapEnabled` is set via `setDragSnap`
    // (side effect: reconcile the monitors); the rest persist directly on change.
    @Published var dragSnapEnabled: Bool
    @Published var dragSnapStyleVibrancy: Bool { didSet { Preferences.dragSnapStyle = dragSnapStyleVibrancy ? .vibrancy : .flat } }
    @Published var dragSnapModifier: DragSnapModifier { didSet { Preferences.dragSnapModifier = dragSnapModifier } }
    @Published var dragSnapEdgeMargin: Double { didSet { Preferences.dragSnapEdgeMargin = CGFloat(dragSnapEdgeMargin) } }
    @Published var dragSnapCornerSize: Double { didSet { Preferences.dragSnapCornerSize = CGFloat(dragSnapCornerSize) } }
    @Published var dragSnapIgnoredBundleIds: [String]
    // Which screen the command runner / Clipboard History open on.
    @Published var runnerPlacement: RunnerPlacement { didSet { Preferences.runnerPlacement = runnerPlacement } }
    // Window layouts (drag-into-zone). Mode + gap persist directly; the store holds
    // groups/layouts and the active selection.
    @Published var snapMode: SnapMode { didSet { Preferences.snapMode = snapMode } }
    @Published var layoutGap: Double { didSet { Preferences.layoutGap = CGFloat(layoutGap) } }
    // Coalesce the store write to the next runloop tick: a single CRUD action
    // (duplicate, delete) mutates the store several times in one pass, and this
    // collapses that burst into one encode+UserDefaults write.
    // ponytail: per-keystroke name edits land on separate ticks so still write
    // once each — acceptable at µs/KB scale; add a debounce timer only if a
    // profiler ever shows it matters.
    @Published var layoutStore: LayoutStore { didSet { scheduleLayoutStorePersist() } }
    private var layoutStorePersistScheduled = false
    private func scheduleLayoutStorePersist() {
        guard !layoutStorePersistScheduled else { return }
        layoutStorePersistScheduled = true
        // Strong self capture, NOT weak: this write must outlive the view. With
        // [weak self] a settings-window close in the same runloop turn as the final
        // edit would dealloc the model before the block runs and silently drop the
        // last layout change. The closure isn't stored, so GCD releases it (and self)
        // right after it runs — no retain cycle, no leak.
        DispatchQueue.main.async { [self] in
            layoutStorePersistScheduled = false
            Preferences.layoutStore = layoutStore
        }
    }

    @Published var disabledBundleIds: [String]
    @Published var disableTabBundleIds: [String]
    @Published var enabledBundleIds: [String]
    @Published var disabledDomains: [String]

    /// Per-action global shortcuts (rebindable).
    @Published var shortcutCombos: [ShortcutAction: KeyCombo]

    /// User-defined custom shortcuts (open the runner pre-seeded with a prefix).
    @Published var customShortcuts: [CustomShortcut]

    /// Side-effect hooks owned by AppDelegate (start/stop engines, login item).
    var onAutocompleteChanged: ((Bool) -> Void)?
    var onLaunchAtLoginChanged: ((Bool) -> Void)?
    var onClipboardHistoryChanged: ((Bool) -> Void)?
    var onClipboardMaxItemsChanged: (() -> Void)?
    var onShortcutsChanged: (() -> Void)?
    var onMenuBarIconChanged: ((Bool) -> Void)?
    var onDockIconChanged: ((Bool) -> Void)?
    var onDragSnapChanged: ((Bool) -> Void)?

    init() {
        autocompleteEnabled = Preferences.autocompleteEnabled
        agentEnabled = Preferences.agentEnabled
        completionsEnabledByDefault = Preferences.completionsEnabledByDefault
        completionLength = Preferences.completionLength
        customInstructions = Preferences.customInstructions
        userName = Preferences.userName
        userLanguages = Preferences.userLanguages
        voiceStyle = Preferences.voiceStyle
        launchAtLogin = LaunchAtLogin.isEnabled
        clipboardHistoryEnabled = Preferences.clipboardHistoryEnabled
        clipboardHistoryMaxItems = Preferences.clipboardHistoryMaxItems
        useClipboardContext = Preferences.useClipboardContext
        quickSelectModifier = Preferences.quickSelectModifier
        midlineCompletionsEnabled = Preferences.midlineCompletionsEnabled
        emojiSuggestionsEnabled = Preferences.emojiSuggestionsEnabled
        suppressOnTypo = Preferences.suppressOnTypo
        trailingSpaceAfterWordAccept = Preferences.trailingSpaceAfterWordAccept
        coreModel = Preferences.coreModel
        agentModel = Preferences.agentModel
        remoteTerminalEnabled = Preferences.remoteTerminalEnabled
        isolateRemoteSessions = Preferences.isolateRemoteSessions
        mcpServers = Preferences.mcpServers
        hooks = Preferences.hooks
        collectTypingHistory = Preferences.collectTypingHistory
        personalizeWordChoice = Preferences.personalizeWordChoice
        useScreenshotContext = Preferences.useScreenshotContext
        useOCRContext = Preferences.useOCRContext
        improveAppearanceFromScreenshot = Preferences.improveAppearanceFromScreenshot
        showAccessoryButton = Preferences.showAccessoryButton
        dismissOverlaysOnClick = Preferences.dismissOverlaysOnClick
        showSuggestedFixes = Preferences.showSuggestedFixes
        analyticsEnabled = Preferences.analyticsEnabled
        emojiSkinTone = Preferences.emojiSkinTone
        emojiGender = Preferences.emojiGender
        showMenuBarIcon = Preferences.showMenuBarIcon
        showDockIcon = Preferences.showDockIcon
        dragSnapEnabled = Preferences.dragSnapEnabled
        dragSnapStyleVibrancy = Preferences.dragSnapStyle == .vibrancy
        dragSnapModifier = Preferences.dragSnapModifier
        dragSnapEdgeMargin = Double(Preferences.dragSnapEdgeMargin)
        dragSnapCornerSize = Double(Preferences.dragSnapCornerSize)
        dragSnapIgnoredBundleIds = Preferences.dragSnapIgnoredBundleIds.sorted()
        runnerPlacement = Preferences.runnerPlacement
        snapMode = Preferences.snapMode
        layoutGap = Double(Preferences.layoutGap)
        layoutStore = Preferences.layoutStore
        improveCompatBundleIds = Preferences.improveCompatBundleIds.sorted()
        disabledBundleIds = Preferences.disabledBundleIds.sorted()
        disableTabBundleIds = Preferences.disableTabBundleIds.sorted()
        enabledBundleIds = Preferences.enabledBundleIds.sorted()
        disabledDomains = Preferences.disabledDomains.sorted()
        var combos: [ShortcutAction: KeyCombo] = [:]
        for action in ShortcutAction.allCases { combos[action] = ShortcutStore.combo(for: action) }
        shortcutCombos = combos
        customShortcuts = ShortcutStore.customShortcuts()

        // Let AppDelegate silently revert the picker after a cancelled/failed switch.
        SettingsHooks.shared.revertModelSelection = { [weak self] id in
            self?.revertCoreModel(to: id)
        }

        // Reflect an external edit/import of mcp.json into the live list. [weak self]
        // means the registration harmlessly no-ops after self deallocs — no manual
        // removal (which a nonisolated deinit can't do for a MainActor property).
        // ponytail: SettingsModel is app-lifetime; one dangling block observer is fine.
        NotificationCenter.default.addObserver(
            forName: .mcpServersReloadedExternally, object: nil, queue: .main) { [weak self] note in
            guard let self, let servers = note.object as? [MCPServer], self.mcpServers != servers
            else { return }
            self.mcpServers = servers
        }
        NotificationCenter.default.addObserver(
            forName: .hooksReloadedExternally, object: nil, queue: .main) { [weak self] note in
            guard let self, let hooks = note.object as? [HookRule], self.hooks != hooks
            else { return }
            self.hooks = hooks
        }
    }

    private func persistCustomShortcuts() {
        ShortcutStore.setCustomShortcuts(customShortcuts)
        onShortcutsChanged?()
    }

    /// Adds a new custom shortcut bound to the first built-in target, with no
    /// combo yet (the user records one via the recorder row).
    func addCustomShortcut() {
        let target = ActivationTarget.builtins.first!
        let empty = KeyCombo(keyCode: 0, carbonModifiers: 0, display: "Unset")
        customShortcuts.append(CustomShortcut(combo: empty, prefix: target.prefix, label: target.label))
        persistCustomShortcuts()
    }

    func updateCustomShortcutCombo(id: UUID, combo: KeyCombo) {
        guard let i = customShortcuts.firstIndex(where: { $0.id == id }) else { return }
        customShortcuts[i].combo = combo
        persistCustomShortcuts()
    }

    func updateCustomShortcutTarget(id: UUID, target: ActivationTarget) {
        guard let i = customShortcuts.firstIndex(where: { $0.id == id }) else { return }
        customShortcuts[i].prefix = target.prefix
        customShortcuts[i].label = target.label
        persistCustomShortcuts()
    }

    func removeCustomShortcut(id: UUID) {
        customShortcuts.removeAll { $0.id == id }
        persistCustomShortcuts()
    }

    // MARK: - Native key mappings (launch app / remap / media — replaces the old
    // appkeys / app-remaps / media-layer extensions). Each edit re-applies to the
    // shared key-rule engine immediately.

    @Published var keyMappings: [ShortcutRulesStore.Rule] = ShortcutRulesStore.shared.rules

    private func persistKeyMappings() {
        ShortcutRulesStore.shared.setRules(keyMappings)
    }

    func addKeyMapping() {
        keyMappings.append(ShortcutRulesStore.Rule())
        persistKeyMappings()
    }

    func updateKeyMapping(_ rule: ShortcutRulesStore.Rule) {
        guard let i = keyMappings.firstIndex(where: { $0.id == rule.id }) else { return }
        keyMappings[i] = rule
        persistKeyMappings()
    }

    func removeKeyMapping(id: UUID) {
        keyMappings.removeAll { $0.id == id }
        persistKeyMappings()
    }

    func setShortcut(_ combo: KeyCombo, for action: ShortcutAction) {
        ShortcutStore.setCombo(combo, for: action)
        shortcutCombos[action] = combo
        onShortcutsChanged?()
    }

    func resetShortcut(_ action: ShortcutAction) {
        ShortcutStore.reset(action)
        shortcutCombos[action] = action.defaultCombo
        onShortcutsChanged?()
    }

    /// Disables a shortcut by persisting an empty combo. Registration skips it, so
    /// the trigger stops firing until the user records a new key (or resets it).
    func clearShortcut(_ action: ShortcutAction) {
        ShortcutStore.setCombo(unsetKeyCombo, for: action)
        shortcutCombos[action] = unsetKeyCombo
        onShortcutsChanged?()
    }

    func addDisabledDomain(_ d: String) { mutate(\.disabledDomains, add: d) { Preferences.disabledDomains = Set($0) } }
    func removeDisabledDomain(_ d: String) { mutate(\.disabledDomains, remove: d) { Preferences.disabledDomains = Set($0) } }

    func setAutocomplete(_ on: Bool) {
        autocompleteEnabled = on
        onAutocompleteChanged?(on)
    }

    func setDragSnap(_ on: Bool) {
        dragSnapEnabled = on
        Preferences.dragSnapEnabled = on
        onDragSnapChanged?(on)
    }

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLogin = on
        onLaunchAtLoginChanged?(on)
    }

    func setClipboardHistory(_ on: Bool) {
        clipboardHistoryEnabled = on
        onClipboardHistoryChanged?(on)
    }

    func setShowMenuBarIcon(_ on: Bool) {
        showMenuBarIcon = on
        Preferences.showMenuBarIcon = on
        onMenuBarIconChanged?(on)
    }

    func setShowDockIcon(_ on: Bool) {
        showDockIcon = on
        Preferences.showDockIcon = on
        onDockIconChanged?(on)
    }

    func addCompat(_ id: String) { mutate(\.improveCompatBundleIds, add: id) { Preferences.improveCompatBundleIds = Set($0) } }
    func removeCompat(_ id: String) { mutate(\.improveCompatBundleIds, remove: id) { Preferences.improveCompatBundleIds = Set($0) } }

    /// Per-app custom instructions (bundle id → text).
    func perAppInstruction(_ bundleId: String) -> String {
        Preferences.perAppCustomInstructions[bundleId] ?? ""
    }
    func setPerAppInstruction(_ text: String, for bundleId: String) {
        guard !bundleId.isEmpty else { return }
        var map = Preferences.perAppCustomInstructions
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { map.removeValue(forKey: bundleId) } else { map[bundleId] = trimmed }
        Preferences.perAppCustomInstructions = map
    }

    func addDisabled(_ id: String) { mutate(\.disabledBundleIds, add: id) { Preferences.disabledBundleIds = Set($0) } }
    func removeDisabled(_ id: String) { mutate(\.disabledBundleIds, remove: id) { Preferences.disabledBundleIds = Set($0) } }
    func addDisableTab(_ id: String) { mutate(\.disableTabBundleIds, add: id) { Preferences.disableTabBundleIds = Set($0) } }
    func removeDisableTab(_ id: String) { mutate(\.disableTabBundleIds, remove: id) { Preferences.disableTabBundleIds = Set($0) } }
    func addEnabled(_ id: String) { mutate(\.enabledBundleIds, add: id) { Preferences.enabledBundleIds = Set($0) } }
    func removeEnabled(_ id: String) { mutate(\.enabledBundleIds, remove: id) { Preferences.enabledBundleIds = Set($0) } }
    func addDragSnapIgnored(_ id: String) { mutate(\.dragSnapIgnoredBundleIds, add: id) { Preferences.dragSnapIgnoredBundleIds = $0 } }
    func removeDragSnapIgnored(_ id: String) { mutate(\.dragSnapIgnoredBundleIds, remove: id) { Preferences.dragSnapIgnoredBundleIds = $0 } }

    func resetCustomInstructions() { customInstructions = "" }

    private func mutate(_ key: ReferenceWritableKeyPath<SettingsModel, [String]>,
                        add: String? = nil, remove: String? = nil,
                        persist: ([String]) -> Void) {
        var list = self[keyPath: key]
        if let add, !add.isEmpty, !list.contains(add) { list.append(add) }
        if let remove { list.removeAll { $0 == remove } }
        list.sort()
        self[keyPath: key] = list
        persist(list)
    }
}

// MARK: - Root (vertical sidebar)

private struct SettingsRootView: View {
    @StateObject private var model = SettingsModel()
    // AppStorage (not @State): the window is torn down on close, so plain view
    // state would land every reopen back on General.
    @AppStorage("settingsSelectedPane") private var selection = "general"
    @State private var registry = SettingsHooks.shared.extensionRegistry
    // Bumped on every registry change so the sidebar `groups` recompute when an
    // extension is enabled/disabled/installed (its section appears/disappears).
    @State private var registryRev = 0

    private var groups: [(String, [SettingsTab])] {
        // Read registryRev so SwiftUI tracks it as a body dependency: the
        // `.onReceive(registryChanges)` bump below must invalidate this view (and
        // recompute the sidebar) the instant an extension is enabled/disabled —
        // otherwise the rail only refreshes on the next unrelated re-render.
        _ = registryRev
        return settingsSidebarGroups(registry: registry)
    }

    /// Registry mutations (enable/disable/install) as a void stream; empty when
    /// there's no registry. `registry` is set once for the view's lifetime.
    private var registryChanges: AnyPublisher<Void, Never> {
        registry?.objectWillChange.map { _ in () }.eraseToAnyPublisher()
            ?? Empty(completeImmediately: false).eraseToAnyPublisher()
    }

    /// Resolve an `ext:<extID>|<sectionID>` sidebar selection to its pane.
    private func extensionSettingsPane(registry: ExtensionRegistry, selection: String) -> ExtensionSettingsPane? {
        let body = String(selection.dropFirst("ext:".count))
        guard let sep = body.firstIndex(of: "|") else { return nil }
        let extID = String(body[..<sep])
        let sectionID = String(body[body.index(after: sep)...])
        guard let (record, section) = registry.settingsSection(extensionID: extID, sectionID: sectionID)
        else { return nil }
        // Translate uses the same local model as inline completions; surface the shared
        // AI Model picker at the top of its settings so the model is changeable even
        // when inline autocomplete is off (its Completions tab is then hidden).
        // Window Management is merged here: the native drag-snap pane rides in as
        // the header above this extension's own (Tier-A) shortcut binds, so there's
        // ONE Window Management section instead of a native tab + an ext section.
        var header: AnyView?
        var footer: AnyView?
        switch extID {
        case "com.prosper.translate": header = AnyView(AIModelSection(model: model))
        // Window: drag-snap config rides in as the FOOTER so the manifest's
        // Permissions + window-move shortcut binds read first on the page.
        case "com.prosper.window": footer = AnyView(WindowManagementPane(model: model))
        // Menu Bar Management: the rich native controls (spacing, section list,
        // reorder + relaunch) ride in as the FOOTER below the manifest's reveal
        // shortcut, so there's ONE Menu Bar Management section.
        case "com.prosper.menubar": footer = AnyView(MenuBarPane(model: model))
        default: break
        }
        return ExtensionSettingsPane(registry: registry, record: record, section: section,
                                     header: header, footer: footer)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(groups: groups, selection: $selection)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsBackground())
        }
        .frame(minWidth: sz(820), minHeight: sz(480))
        .preferredColorScheme(.dark)
        .onAppear {
            let shared = SettingsHooks.shared
            model.onAutocompleteChanged = shared.onAutocompleteChanged
            model.onLaunchAtLoginChanged = shared.onLaunchAtLoginChanged
            model.onClipboardHistoryChanged = shared.onClipboardHistoryChanged
            model.onClipboardMaxItemsChanged = shared.onClipboardMaxItemsChanged
            model.onShortcutsChanged = shared.onShortcutsChanged
            model.onMenuBarIconChanged = shared.onMenuBarIconChanged
            model.onDockIconChanged = shared.onDockIconChanged
            model.onDragSnapChanged = shared.onDragSnapChanged
        }
        .onReceive(NotificationCenter.default.publisher(for: .prosperSettingsCycleSection)) { note in
            let ids = groups.flatMap { $0.1.map(\.id) }
            guard let delta = note.userInfo?["delta"] as? Int,
                  let idx = ids.firstIndex(of: selection) else { return }
            selection = ids[(idx + delta + ids.count) % ids.count]
        }
        .onReceive(registryChanges) { _ in
            registryRev &+= 1   // force `groups` to recompute (sidebar add/remove)
            healSelection()
        }
        // Toggling a category master switch hides/shows its whole group; if the
        // active pane lived in a now-hidden group, fall back to General.
        .onChange(of: model.autocompleteEnabled) { _, _ in healSelection() }
        .onChange(of: model.agentEnabled) { _, _ in healSelection() }
    }

    /// Reset the selection to General when it points at a tab that's no longer
    /// in the sidebar (a vanished ext section, or a hidden feature category).
    private func healSelection() {
        if !groups.contains(where: { $0.1.contains { $0.id == selection } }) {
            selection = "general"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case "general": GeneralPane(model: model)
        case "appearance": AppearanceSettingsPane()
        case "completions": CompletionsPane(model: model)
        case "context": ContextPane(model: model)
        case "apps": AppsPane(model: model)
        case "personalization": PersonalizationPane(model: model)
        case "shortcuts": ShortcutsPane(model: model)
        case "ai-models": AIModelsPane(model: model)
        case "system-stats": SystemStatsPane()
        case "agent": AgentPane(model: model)
        case "agent-mcp": MCPServersPane(model: model)
        case "agent-plugins": PluginsHooksPane(model: model)
        case "agent-commands": CommandsPane()
        case "agent-personas": AgentsPane()
        case "agent-permissions": PermissionsPane()
        case "statistics": StatisticsPane()
        case "account": AccountPane()
        case "sync": SyncPane()
        case "analytics": AnalyticsPane(model: model)
        case "about": AboutPane()
        case "extensions":
            if let registry { ExtensionsPane(registry: registry) } else { GeneralPane(model: model) }
        default:
            if selection.hasPrefix("ext:"), let registry,
               let pane = extensionSettingsPane(registry: registry, selection: selection) {
                // .id(selection) gives each ext section its own view identity, so
                // switching sections rebuilds the pane's @State (loaded UI) instead
                // of reusing a stale render and only swapping the title.
                pane.id(selection)
            } else {
                GeneralPane(model: model)
            }
        }
    }
}

/// Carries AppDelegate side-effect closures into the SwiftUI Settings tree
/// without threading them through the window plumbing.
@MainActor
final class SettingsHooks {
    static let shared = SettingsHooks()
    var onAutocompleteChanged: ((Bool) -> Void)?
    var onLaunchAtLoginChanged: ((Bool) -> Void)?
    var onClipboardHistoryChanged: ((Bool) -> Void)?
    var onClipboardMaxItemsChanged: (() -> Void)?
    var onShortcutsChanged: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onMenuBarIconChanged: ((Bool) -> Void)?
    var onDockIconChanged: ((Bool) -> Void)?
    var onDragSnapChanged: ((Bool) -> Void)?
    /// Fired when the user picks a different AI model. AppDelegate drives a live switch
    /// (download-if-needed + reload) via `CoreBridge.switchModel` — no restart needed.
    var onModelChanged: ((String) -> Void)?
    /// Driven by AppDelegate after a cancelled/failed switch: revert the picker to a
    /// downloaded model id, or `nil` for "None" (no model on disk → completions off).
    /// Must NOT re-trigger `onModelChanged`.
    var revertModelSelection: ((String?) -> Void)?
    /// The live extension registry, owned by AppDelegate, so the Extensions pane
    /// can list/install/manage extensions.
    var extensionRegistry: ExtensionRegistry?
}

// MARK: - Pane header

/// Big neon title shown at the top of each pane's scrolling column.
struct PaneTitle: View {
    let title: String
    var accent: String? = nil
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: sz(3)) {
            neonAccentedText(title, accent: accent)
                .font(Neon.font(22, weight: .bold, design: .rounded))
                .foregroundStyle(Neon.textPrimary)
            Text(subtitle)
                .font(Neon.font(12))
                .foregroundStyle(Neon.textSecondary)
        }
        .padding(.bottom, sz(2))
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    // Deep-link target: writing the shared selection key switches the sidebar
    // pane (SettingsRootView binds it via @AppStorage), so the warning below can
    // jump the user straight to the Context pane's permission grants.
    @AppStorage("settingsSelectedPane") private var selection = "general"
    // Autocomplete's keystroke tap is gated by Accessibility. Checked on appear
    // (granting happens out-of-process); the user fixes it on the Context pane
    // and returns. There's no first-run wizard, so this is the only nudge.
    @State private var hasAccessibility = PermissionsManager.isAccessibilityTrusted()

    var body: some View {
        NeonScroll {
            PaneTitle(title: "General", subtitle: "Startup, menu bar and clipboard")

            // Always-visible Accessibility grant. The Context pane has the full
            // permissions list, but it lives under the Inline Autocomplete category
            // and is hidden when that's off — so a clipboard-only user never sees it.
            // Accessibility underpins clipboard paste, autocomplete, drag-snap and
            // shortcuts, so surface it here on the always-present General pane.
            NeonSection("Permissions",
                        footer: "Accessibility lets Prosper paste from Clipboard History, run system-wide autocomplete, snap windows and fire shortcuts. Use “Open” to grant it in System Settings, then “Re-check”.") {
                PermissionStatusRow(
                    title: "Accessibility",
                    subtitle: "Paste clipboard entries, watch keystrokes, move windows, run shortcuts",
                    granted: hasAccessibility) {
                        // Prompt only nudges when NOT yet trusted (no dialog when
                        // granted); always open the pane so "Open" works either way.
                        _ = PermissionsManager.ensureAccessibilityTrust(prompt: !hasAccessibility)
                        PermissionsManager.openAccessibilitySettings()
                        hasAccessibility = PermissionsManager.isAccessibilityTrusted()
                    }
                NeonDivider()
                HStack {
                    Button("Re-check") { hasAccessibility = PermissionsManager.isAccessibilityTrusted() }
                        .buttonStyle(.neon)
                    Spacer()
                }
            }

            NeonSection("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
            }

            NeonSection("Menu Bar",
                        footer: "With the icon hidden, Prosper stays reachable via global shortcuts.") {
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { model.showMenuBarIcon },
                    set: { model.setShowMenuBarIcon($0) }))
            }

            NeonSection("Dock",
                        footer: "Shows a Dock icon only while a Prosper window is open, so you can switch back to it with Cmd-Tab. Turn off to keep Prosper fully hidden from the Dock and app switcher.") {
                Toggle("Show Dock icon while a window is open", isOn: Binding(
                    get: { model.showDockIcon },
                    set: { model.setShowDockIcon($0) }))
            }

            NeonSection("Inline Autocomplete",
                        footer: "Off hides the whole Inline Autocomplete settings category and stops completions.") {
                Toggle("Enable inline autocomplete", isOn: Binding(
                    get: { model.autocompleteEnabled },
                    set: { model.setAutocomplete($0) }))
                if model.autocompleteEnabled && !hasAccessibility {
                    NeonDivider()
                    PermissionWarningRow(
                        title: "Accessibility permission needed",
                        message: "Completions can't appear until you grant it. Open Context to fix.") {
                            selection = "context"
                        }
                }
            }

            NeonSection("Coding Agent",
                        footer: "Off hides the whole Coding Agent settings category and the menu-bar entry.") {
                Toggle("Enable coding agent", isOn: $model.agentEnabled)
            }

            NeonSection("Remote Terminal",
                        footer: "Serves your terminal sessions to the DchTerm app over Tailscale. The port binds only to your Tailscale address — never the public internet. Requires Tailscale to be running.") {
                Toggle("Serve sessions over Tailscale", isOn: Binding(
                    get: { model.remoteTerminalEnabled },
                    set: { model.setRemoteTerminal($0) }))
                NeonDivider()
                Toggle("Isolate sessions", isOn: Binding(
                    get: { model.isolateRemoteSessions },
                    set: { model.setIsolateRemoteSessions($0) }))
                    .disabled(!model.remoteTerminalEnabled)
            }

            NeonSection("Clipboard",
                        footer: "History is encrypted at rest. Pinned items are always kept and don't count toward the limit.") {
                Toggle("Enable clipboard history", isOn: Binding(
                    get: { model.clipboardHistoryEnabled },
                    set: { model.setClipboardHistory($0) }))
                NeonDivider()
                NeonRow("History size",
                        subtitle: "Most recent entries kept (\(Preferences.clipboardHistoryMaxRange.lowerBound)–\(Preferences.clipboardHistoryMaxRange.upperBound)).") {
                    HStack(spacing: sz(10)) {
                        Text("\(model.clipboardHistoryMaxItems)")
                            .font(Neon.font(13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Neon.textPrimary)
                            .frame(minWidth: sz(44), alignment: .trailing)
                        Stepper("", value: $model.clipboardHistoryMaxItems,
                                in: Preferences.clipboardHistoryMaxRange, step: 50)
                            .labelsHidden()
                    }
                }
                .disabled(!model.clipboardHistoryEnabled)
                NeonDivider()
                Toggle("Use clipboard text as completion context",
                       isOn: $model.useClipboardContext)
            }

            // Own group: the modifier drives BOTH runner results and clipboard rows.
            NeonSection("Quick-select") {
                NeonRow("Quick-select modifier",
                        subtitle: "Paste a clipboard row (1…0) or pick a top runner result (1…5).") {
                    Picker("", selection: $model.quickSelectModifier) {
                        ForEach(QuickSelectModifier.allCases, id: \.self) { mod in
                            Text(mod.title).tag(mod)
                        }
                    }
                    .labelsHidden()
                    .frame(width: sz(150))
                }
            }
        }
        .onAppear { hasAccessibility = PermissionsManager.isAccessibilityTrusted() }
    }
}

/// A tappable warning row: amber triangle + message, chevron affordance. Used in
/// General to flag a missing permission and deep-link to the pane that fixes it.
private struct PermissionWarningRow: View {
    let title: String
    let message: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: sz(10)) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Neon.magenta)
                VStack(alignment: .leading, spacing: sz(2)) {
                    Text(title)
                        .font(Neon.font(13, weight: .semibold))
                        .foregroundStyle(Neon.textPrimary)
                    Text(message)
                        .font(Neon.font(12))
                        .foregroundStyle(Neon.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Neon.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AI Model (shared)

/// The AI Model picker, selecting the local `coreModel` used by BOTH inline
/// completions and the Translate extension. Writing `model.coreModel` drives the live
/// model switch (download-if-needed + reload) via `onModelChanged`. Reused in the
/// Completions pane and prepended to the Translate settings pane, so the model stays
/// changeable even when inline autocomplete is off (and its tab hidden).
struct AIModelSection: View {
    @ObservedObject var model: SettingsModel

    /// Picker-offered models, smallest→largest. The full-size 12B/26B QAT checkpoints
    /// are NOT offered: the vendored mlx-swift-lm fork has no loader for them (12B =
    /// unregistered model_type `gemma4_unified`; 26B-A4B = 128-expert MoE that doesn't
    /// map onto the dense Gemma4Model). See Preferences.unsupportedModelIds — re-add
    /// here only once the architectures are ported AND verified to load.
    static let models: [(String, String)] = [
        (Preferences.qatE2B4Id, "Gemma 4 E2B (QAT 4-bit, ~4.3 GB) — fastest, lightest"),
        (Preferences.qatE2B6Id, "Gemma 4 E2B (QAT 6-bit, ~5.1 GB) — sharper E2B, more RAM"),
        (Preferences.qatE2B8Id, "Gemma 4 E2B (QAT 8-bit, ~5.9 GB) — sharpest E2B, most RAM"),
        (Preferences.qatE4B4Id, "Gemma 4 E4B (QAT 4-bit, ~6.8 GB) — larger base, smarter"),
        (Preferences.qatE4B6Id, "Gemma 4 E4B (QAT 6-bit, ~7.8 GB) — larger base, sharper"),
        (Preferences.qatE4B8Id, "Gemma 4 E4B (QAT 8-bit, ~8.9 GB) — recommended (smartest, most RAM)"),
    ]

    /// Prepends a "None" row whenever no model is selected (e.g. after cancelling the
    /// first download) so the empty `coreModel` tag has a match — without it SwiftUI
    /// shows a blank selection.
    private var modelOptions: [(String, String)] {
        guard model.coreModel.isEmpty else { return Self.models }
        return [("", "None — no model downloaded (inline completions off)")] + Self.models
    }

    var body: some View {
        NeonSection("AI Model", footer: "Switching downloads the model if needed, then reloads it — no restart required.") {
            Picker("Model", selection: $model.coreModel) {
                ForEach(modelOptions, id: \.0) {
                    Text(ModelFiles.pickerLabel(for: $0.0, base: CustomModelStore.label(for: $0.0, fallback: $0.1))).tag($0.0)
                }
            }
            NeonDivider()
            HStack {
                Spacer()
                Button("Reveal Model Files in Finder") { ModelFiles.reveal() }
                    .buttonStyle(.neon)
            }
        }
    }
}

// MARK: - Completions

private struct CompletionsPane: View {
    @ObservedObject var model: SettingsModel

    /// Fixed (non-rebindable) keys active while a suggestion is on screen. Lives
    /// here, beside the rest of the completion settings, rather than in Shortcuts.
    static let fixedKeys: [(String, String)] = [
        ("Accept full completion", "\u{2192}"),
        ("Accept single word", "Tab \u{00B7} \u{2325}\u{2192}"),
        ("Dismiss suggestion", "Esc"),
    ]

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Completions", subtitle: "Activation, model, length, behavior and AI instructions")

            NeonSection("Activation") {
                Toggle("Enable completions by default (off ⇒ per-app opt-in)",
                       isOn: $model.completionsEnabledByDefault)
                    .disabled(!model.autocompleteEnabled)
                NeonDivider()
                Toggle("Show accessory button near the active text field",
                       isOn: $model.showAccessoryButton)
                    .disabled(!model.autocompleteEnabled)
                NeonDivider()
                Toggle("Hide ghost text and accessory button on mouse click",
                       isOn: $model.dismissOverlaysOnClick)
                    .disabled(!model.autocompleteEnabled)
            }

            AIModelSection(model: model)

            NeonSection("Length") {
                VStack(alignment: .leading, spacing: sz(8)) {
                    Text("Maximum completion length").foregroundStyle(Neon.textPrimary)
                    Picker("", selection: $model.completionLength) {
                        ForEach(CompletionLength.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            NeonSection("Keys (while a suggestion is shown)") {
                ForEach(Array(CompletionsPane.fixedKeys.enumerated()), id: \.element.0) { idx, row in
                    if idx > 0 { NeonDivider() }
                    HStack {
                        Text(row.0).foregroundStyle(Neon.textPrimary)
                        Spacer()
                        Text(row.1).font(Neon.font(.body, design: .monospaced))
                            .foregroundStyle(Neon.blue)
                    }
                }
            }

            NeonSection("Behavior") {
                Toggle("Mid-line completions (suggest with text after the caret)",
                       isOn: $model.midlineCompletionsEnabled)
                NeonDivider()
                Toggle("Emoji suggestions (:name inline + in the command runner)",
                       isOn: $model.emojiSuggestionsEnabled)
                NeonDivider()
                Toggle("Don't complete when a typo is suspected",
                       isOn: $model.suppressOnTypo)
                NeonDivider()
                Toggle("Show suggested fixes (strike typo, propose correction)",
                       isOn: $model.showSuggestedFixes)
                NeonDivider()
                Toggle("Add a space after accepting the last word (Tab)",
                       isOn: $model.trailingSpaceAfterWordAccept)
            }

            NeonSection("Emoji") {
                Picker("Preferred skin tone", selection: $model.emojiSkinTone) {
                    ForEach(EmojiSkinTone.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                NeonDivider()
                Picker("Preferred gender", selection: $model.emojiGender) {
                    ForEach(EmojiGender.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            NeonSection("About You",
                        footer: "Optional. Woven into the completion system prompt so suggestions sound like you. Leave blank to skip.") {
                TextField("Your name (e.g. Vince)", text: $model.userName)
                    .textFieldStyle(.roundedBorder)
                NeonDivider()
                TextField("Languages you write in (e.g. English, Bulgarian)", text: $model.userLanguages)
                    .textFieldStyle(.roundedBorder)
                NeonDivider()
                TextField("Preferred voice (e.g. friendly, professional, concise)", text: $model.voiceStyle)
                    .textFieldStyle(.roundedBorder)
            }

            NeonSection("Custom AI Instructions",
                        footer: "Appended to the completion system prompt (tone, languages, style).") {
                NeonTextEditor(text: $model.customInstructions, minHeight: sz(140))
                HStack {
                    Spacer()
                    Button("Reset to Default") { model.resetCustomInstructions() }
                        .buttonStyle(.neon)
                }
            }

            // Translation source/target languages moved to the Translate system
            // extension's own Options (Settings → Extensions → Translate).
        }
    }
}

// MARK: - Context

private struct ContextPane: View {
    @ObservedObject var model: SettingsModel
    @State private var hasScreenPermission = VisionContext.hasScreenRecordingPermission()
    @State private var hasAccessibility = PermissionsManager.isAccessibilityTrusted()
    @State private var hasNotifications = false

    /// Re-reads every privacy grant. The TCC checks are synchronous; the
    /// notification authorization is fetched async and applied on the main actor.
    private func refreshPermissions() {
        hasScreenPermission = VisionContext.hasScreenRecordingPermission()
        hasAccessibility = PermissionsManager.isAccessibilityTrusted()
        Task { @MainActor in hasNotifications = await PermissionsManager.notificationStatus() }
    }

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Context", subtitle: "What Prosper sees to sharpen suggestions")

            NeonSection("Screenshots",
                        footer: "Captures a small region around the cursor and feeds it to the local model. OCR recognizes nearby text on-device (Neural Engine) — useful in Slack, Notion and other apps that hide their text from accessibility. Requires Screen Recording permission. Nothing leaves your machine.") {
                Toggle("Use screenshots for context (multimodal)",
                       isOn: $model.useScreenshotContext)
                NeonDivider()
                Toggle("Read on-screen text for context (OCR)",
                       isOn: $model.useOCRContext)
                NeonDivider()
                Toggle("Use screenshots to improve suggestion appearance",
                       isOn: $model.improveAppearanceFromScreenshot)
            }

            NeonSection("Permissions",
                        footer: "macOS privacy grants Prosper needs. Accessibility powers system-wide autocomplete (watching keystrokes and inserting completions); Screen Recording enables screenshot/OCR context; Notifications surface update and status messages. Use “Open” to grant in System Settings, then “Re-check”.") {
                PermissionStatusRow(
                    title: "Accessibility",
                    subtitle: "Watch keystrokes, read focused text fields, and insert completions",
                    granted: hasAccessibility) {
                        // Prompt only nudges when NOT yet trusted (no dialog when
                        // granted); always open the pane so "Open" works either way.
                        _ = PermissionsManager.ensureAccessibilityTrust(prompt: !hasAccessibility)
                        PermissionsManager.openAccessibilitySettings()
                        hasAccessibility = PermissionsManager.isAccessibilityTrusted()
                    }
                // Recovery for the ad-hoc-signing "toggle on, still not trusted"
                // trap: a rebuild's new code signature no longer matches the old
                // grant. One-step reset + re-request binds a fresh grant to the
                // current binary. (Formerly lived in the now-removed onboarding.)
                if !hasAccessibility {
                    NeonDivider()
                    NeonRow("Enabled in System Settings but still not trusted?",
                            subtitle: "An ad-hoc-signed rebuild changes the app's signature, so macOS's old grant stops matching. Reset and re-add in one step.") {
                        Button("Reset & re-add") {
                            // Off-main: tccutil reset spawns a subprocess and blocks
                            // on waitUntilExit — would freeze the Settings window.
                            Task {
                                await Task.detached(priority: .userInitiated) {
                                    PermissionsManager.resetPrivacyGrant(service: "Accessibility")
                                }.value
                                PermissionsManager.ensureAccessibilityTrust(prompt: true)
                                PermissionsManager.openAccessibilitySettings()
                                hasAccessibility = PermissionsManager.isAccessibilityTrusted()
                            }
                        }.buttonStyle(.neon)
                    }
                }
                NeonDivider()
                PermissionStatusRow(
                    title: "Screen Recording",
                    subtitle: "Capture on-screen text for screenshot / OCR context",
                    granted: hasScreenPermission) {
                        // Request only nudges when NOT yet granted; always open the
                        // pane so "Open" works even once the grant is in place.
                        if !hasScreenPermission { _ = VisionContext.requestScreenRecordingPermission() }
                        PermissionsManager.openScreenRecordingSettings()
                        hasScreenPermission = VisionContext.hasScreenRecordingPermission()
                    }
                NeonDivider()
                PermissionStatusRow(
                    title: "Notifications",
                    subtitle: "Show update and status alerts",
                    granted: hasNotifications) {
                        PermissionsManager.openNotificationSettings()
                    }
                NeonDivider()
                HStack {
                    Button("Re-check") { refreshPermissions() }.buttonStyle(.neon)
                    Spacer()
                }
            }

            NeonSection("Clipboard") {
                Toggle("Use clipboard text as completion context",
                       isOn: $model.useClipboardContext)
            }
        }
        .onAppear { refreshPermissions() }
    }
}

/// A permission row in the Context pane: a name + optional subtitle on the left,
/// a granted/not-granted status pill and an "Open" action on the right. Mirrors
/// the Screen Recording status styling used across Settings.
private struct PermissionStatusRow: View {
    let title: String
    var subtitle: String?
    let granted: Bool
    let action: () -> Void

    var body: some View {
        NeonRow(title, subtitle: subtitle) {
            HStack(spacing: sz(10)) {
                Label(granted ? "Granted" : "Not granted",
                      systemImage: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(Neon.font(12, weight: .semibold))
                    .foregroundStyle(granted ? Neon.blue : Neon.magenta)
                Button("Open") { action() }.buttonStyle(.neon)
            }
        }
    }
}

// MARK: - Apps

private struct AppsPane: View {
    @ObservedObject var model: SettingsModel
    @State private var newDisabled = ""
    @State private var newDisableTab = ""
    @State private var newEnabled = ""
    @State private var newDomain = ""
    @State private var newCompat = ""
    @State private var perAppBundle = ""
    @State private var perAppText = ""
    @State private var bundleCounts: [(bundleId: String, count: Int)] = []

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Apps", subtitle: "Per-app and per-domain completion control")

            NeonSection("Disabled apps (no completions)") {
                bundleList(model.disabledBundleIds, remove: model.removeDisabled)
                addRow(text: $newDisabled, placeholder: "com.example.app") {
                    model.addDisabled(newDisabled.trimmingCharacters(in: .whitespaces)); newDisabled = ""
                }
            }

            NeonSection("Disabled browser domains (no completions)",
                        footer: "Matches the host and its subdomains in supported browsers.") {
                bundleList(model.disabledDomains, remove: model.removeDisabledDomain)
                addRow(text: $newDomain, placeholder: "bank.com") {
                    model.addDisabledDomain(newDomain.trimmingCharacters(in: .whitespaces)); newDomain = ""
                }
            }

            if !model.completionsEnabledByDefault {
                NeonSection("Enabled apps (opt-in mode)") {
                    bundleList(model.enabledBundleIds, remove: model.removeEnabled)
                    addRow(text: $newEnabled, placeholder: "com.example.app") {
                        model.addEnabled(newEnabled.trimmingCharacters(in: .whitespaces)); newEnabled = ""
                    }
                }
            }

            NeonSection("Disable Tab key (→ still accepts)") {
                bundleList(model.disableTabBundleIds, remove: model.removeDisableTab)
                addRow(text: $newDisableTab, placeholder: "com.example.ide") {
                    model.addDisableTab(newDisableTab.trimmingCharacters(in: .whitespaces)); newDisableTab = ""
                }
            }

            NeonSection("Improve compatibility (paste insertion)",
                        footer: "Inserts accepted completions via clipboard paste for apps that mishandle synthesized typing.") {
                bundleList(model.improveCompatBundleIds, remove: model.removeCompat)
                addRow(text: $newCompat, placeholder: "com.example.app") {
                    model.addCompat(newCompat.trimmingCharacters(in: .whitespaces)); newCompat = ""
                }
            }

            NeonSection("Per-app custom instructions",
                        footer: "Supplements the global instructions for the given app only.") {
                TextField("Bundle id", text: $perAppBundle)
                    .textFieldStyle(.roundedBorder)
                NeonTextEditor(text: $perAppText, minHeight: sz(80))
                HStack {
                    Button("Load") {
                        perAppText = model.perAppInstruction(perAppBundle.trimmingCharacters(in: .whitespaces))
                    }.buttonStyle(.neon)
                    Button("Save") {
                        model.setPerAppInstruction(perAppText, for: perAppBundle.trimmingCharacters(in: .whitespaces))
                    }
                    .buttonStyle(.neon)
                    .disabled(perAppBundle.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }
            }

            NeonSection("Collected inputs per app") {
                if bundleCounts.isEmpty {
                    Text("No per-app history yet (enable Typing History to collect).")
                        .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                } else {
                    ForEach(Array(bundleCounts.enumerated()), id: \.element.bundleId) { idx, row in
                        if idx > 0 { NeonDivider() }
                        HStack {
                            Text(row.bundleId).font(Neon.font(.body, design: .monospaced))
                                .foregroundStyle(Neon.textPrimary)
                            Spacer()
                            Text("\(row.count)")
                                .font(Neon.font(.body, design: .monospaced))
                                .foregroundStyle(Neon.blue)
                        }
                    }
                }
                NeonDivider()
                HStack {
                    Spacer()
                    Button("Refresh counts") { loadCounts() }.buttonStyle(.neon)
                }
            }
        }
        .onAppear(perform: loadCounts)
    }

    private func loadCounts() {
        Task {
            let counts = await TypingHistoryStore.shared.countsByBundle()
            await MainActor.run { bundleCounts = counts }
        }
    }

    @ViewBuilder
    private func bundleList(_ ids: [String], remove: @escaping (String) -> Void) -> some View {
        if ids.isEmpty {
            Text("None").foregroundStyle(Neon.textSecondary).font(Neon.font(.caption))
        } else {
            ForEach(Array(ids.enumerated()), id: \.element) { idx, id in
                if idx > 0 { NeonDivider() }
                HStack {
                    Text(id).font(Neon.font(.body, design: .monospaced))
                        .foregroundStyle(Neon.textPrimary)
                    Spacer()
                    Button(role: .destructive) { remove(id) } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(Neon.magenta)
                    }.buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder
    private func addRow(text: Binding<String>, placeholder: String, add: @escaping () -> Void) -> some View {
        HStack {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button("Add", action: add)
                .buttonStyle(.neon)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

// MARK: - Statistics

private struct StatisticsPane: View {
    @State private var total = CompletionStats.totalCompletions
    @State private var words = CompletionStats.totalWords
    @State private var chars = CompletionStats.totalChars
    @State private var today = CompletionStats.todayCount
    @State private var average = CompletionStats.dailyAverage

    @State private var metric: CompletionStats.Metric = .completions
    @State private var rangeDays = 30
    @State private var series: [CompletionStats.DayPoint] = []

    private let ranges = [(7, "7d"), (30, "30d"), (90, "90d")]

    /// `series` re-keyed to real `Date`s so the chart's x-axis can format clean,
    /// evenly spaced day labels instead of cramming every raw `yyyy-MM-dd` string
    /// (the old axis overlapped them into an unreadable smear).
    private var points: [(date: Date, value: Int)] {
        let fmt = DateFormatter()
        fmt.calendar = Calendar.current
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        return series.compactMap { p in
            fmt.date(from: p.day).map { (date: $0, value: p.value) }
        }
    }

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Statistics", subtitle: "Local usage — stored on-device, never transmitted")

            // Headline metric tiles (Raycast-style dashboard).
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: sz(14)), count: 3), spacing: sz(14)) {
                NeonStatTile(value: "\(today)", label: "Today", icon: "bolt.fill")
                NeonStatTile(value: "\(total)", label: "Completions", icon: "checkmark.circle.fill")
                NeonStatTile(value: String(format: "%.1f", average), label: "Daily avg", icon: "chart.line.uptrend.xyaxis")
                NeonStatTile(value: "\(words)", label: "Words", icon: "text.word.spacing")
                NeonStatTile(value: "\(chars)", label: "Characters", icon: "character")
                NeonStatTile(value: rangeLabel, label: "Range", icon: "calendar")
            }

            NeonSection("Activity") {
                HStack(spacing: sz(16)) {
                    Picker("", selection: $metric) {
                        ForEach(CompletionStats.Metric.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Picker("", selection: $rangeDays) {
                        ForEach(ranges, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(width: sz(150))
                }
                chart
            }

            NeonSection(footer: "Counts are stored locally and never transmitted.") {
                HStack {
                    Button("Refresh") { refresh() }.buttonStyle(.neon)
                    Spacer()
                    Button(role: .destructive) { CompletionStats.reset(); refresh() } label: {
                        Text("Reset Statistics")
                    }.buttonStyle(.neonDestructive)
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: metric) { _, _ in reloadSeries() }
        .onChange(of: rangeDays) { _, _ in reloadSeries() }
    }

    private var rangeLabel: String { "\(rangeDays)d" }

    @ViewBuilder
    private var chart: some View {
        if points.allSatisfy({ $0.value == 0 }) {
            VStack(spacing: sz(6)) {
                Image(systemName: "chart.bar.xaxis")
                    .font(Neon.font(26)).foregroundStyle(Neon.textSecondary.opacity(0.5))
                Text("No activity in this range yet.")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: sz(180))
        } else {
            Chart(points, id: \.date) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value(metric.title, point.value),
                    width: .ratio(0.62)
                )
                .foregroundStyle(Neon.barFill)
            }
            .chartXAxis {
                AxisMarks(preset: .aligned, values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(Neon.stroke)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(Neon.textSecondary)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Neon.stroke)
                    AxisValueLabel().foregroundStyle(Neon.textSecondary)
                }
            }
            .frame(height: sz(200))
        }
    }

    private func refresh() {
        total = CompletionStats.totalCompletions
        words = CompletionStats.totalWords
        chars = CompletionStats.totalChars
        today = CompletionStats.todayCount
        average = CompletionStats.dailyAverage
        reloadSeries()
    }

    private func reloadSeries() {
        series = CompletionStats.series(metric: metric, days: rangeDays)
    }
}

// MARK: - Personalization

private struct PersonalizationPane: View {
    @ObservedObject var model: SettingsModel
    @State private var entryCount = 0

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Personalization", subtitle: "Learn from your writing — fully on-device")

            NeonSection("Typing History",
                        footer: "Stored locally (encrypted at rest), never transmitted. Only accepted completions are recorded — never raw keystrokes.") {
                Toggle("Collect accepted completions for personalization",
                       isOn: $model.collectTypingHistory)
            }

            NeonSection("Word-choice personalization",
                        footer: "Biases completions toward words you write often.") {
                HStack {
                    Text("Off").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                    Slider(value: $model.personalizeWordChoice, in: 0...1)
                    Text("Max").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                }
                .disabled(!model.collectTypingHistory)
            }

            NeonSection("Existing data") {
                NeonRow("Stored entries") {
                    Text("\(entryCount)")
                        .font(Neon.font(.body, design: .monospaced))
                        .foregroundStyle(Neon.blue)
                }
                NeonDivider()
                HStack {
                    Button("Refresh") { loadCount() }.buttonStyle(.neon)
                    Spacer()
                    Button(role: .destructive) {
                        Task {
                            await TypingHistoryStore.shared.deleteAll()
                            loadCount()
                        }
                    } label: { Text("Delete All History") }
                        .buttonStyle(.neonDestructive)
                }
            }
        }
        .onAppear(perform: loadCount)
    }

    private func loadCount() {
        Task {
            let count = await TypingHistoryStore.shared.entryCount()
            await MainActor.run { entryCount = count }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Shortcuts", subtitle: "Trigger Prosper features, jump to commands, and remap keys")

            NeonSection("Prosper Shortcuts (click to rebind)",
                        footer: "Global hotkeys for Prosper's own features. Click to rebind, ↩ to reset to default, ✕ to disable.") {
                let actions = ShortcutAction.allCases.filter {
                    !$0.isWindowManagement && $0.isAvailable(registry: SettingsHooks.shared.extensionRegistry)
                }
                ForEach(Array(actions.enumerated()), id: \.element) { idx, action in
                    if idx > 0 { NeonDivider() }
                    GlobalShortcutRow(model: model, action: action)
                }
            }

            NeonSection("Command Shortcuts",
                        footer: "Each shortcut opens the command runner already scoped to the chosen command \u{2014} including any quickdir, so you can jump straight to its directory listing without typing a prefix.") {
                ForEach(Array(model.customShortcuts.enumerated()), id: \.element.id) { idx, cs in
                    if idx > 0 { NeonDivider() }
                    CustomShortcutRow(model: model, shortcut: cs)
                }
                if !model.customShortcuts.isEmpty { NeonDivider() }
                HStack {
                    Button {
                        model.addCustomShortcut()
                    } label: { Label("Add Shortcut", systemImage: "plus") }
                        .buttonStyle(.neon)
                    Spacer()
                }
            }

            NeonSection("Key Remapping",
                        footer: "Bind any key or media key to launch an app, remap to another key, send a media key, or disable it \u{2014} for every app or just one. No defaults; add what you want.") {
                ForEach(Array(model.keyMappings.enumerated()), id: \.element.id) { idx, rule in
                    if idx > 0 { NeonDivider() }
                    KeyMappingRow(model: model, rule: rule)
                }
                if !model.keyMappings.isEmpty { NeonDivider() }
                HStack {
                    Button {
                        model.addKeyMapping()
                    } label: { Label("Add Mapping", systemImage: "plus") }
                        .buttonStyle(.neon)
                    Spacer()
                }
            }

            // Read-only guide: launcher prefixes contributed by enabled extensions,
            // GROUPED per extension. Sourced live from modeTriggers() (already
            // filtered to enabled+trusted). arg == nil drops dynamic per-item
            // triggers (e.g. each quickdir dir), keeping just the manifest
            // activators like "sn ", "bm ", "ql ". Beyond these prefixes, every
            // command is also reachable by typing its extension's name or any of
            // its keywords (see UnifiedSearch command discovery) — the footer says so.
            let activatorGroups = Self.activatorGroups(
                SettingsHooks.shared.extensionRegistry?.modeTriggers() ?? [])
            if !activatorGroups.isEmpty {
                NeonSection("Extension Activators",
                            footer: "Type a prefix to jump straight to a command \u{2014} or just type the extension's name or a keyword to see its commands in the launcher. Read-only; updates as you enable or disable extensions.") {
                    ForEach(Array(activatorGroups.enumerated()), id: \.element.title) { gi, group in
                        if gi > 0 { NeonDivider() }
                        Text(group.title)
                            .font(Neon.font(.callout, weight: .semibold))
                            .foregroundStyle(Neon.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array(group.triggers.enumerated()), id: \.offset) { _, t in
                            ExtensionActivatorRow(trigger: t)
                        }
                    }
                }
            }
        }
    }

    /// Groups manifest activators per contributing extension for the read-only
    /// guide: drops dynamic per-item triggers (arg != nil), buckets by extension
    /// title, sorts groups alphabetically and triggers within each by prefix.
    static func activatorGroups(_ specs: [ExtensionRegistry.ModeTriggerSpec])
        -> [(title: String, triggers: [ExtensionRegistry.ModeTriggerSpec])] {
        var buckets: [String: [ExtensionRegistry.ModeTriggerSpec]] = [:]
        for s in specs where s.arg == nil {
            let key = s.extensionTitle.isEmpty ? "Other" : s.extensionTitle
            buckets[key, default: []].append(s)
        }
        return buckets
            .map { (title: $0.key,
                    triggers: $0.value.sorted {
                        $0.prefix.localizedCaseInsensitiveCompare($1.prefix) == .orderedAscending
                    }) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

/// One read-only row: launcher prefix badge + command title + contributing
/// extension. Pure guide; no interaction.
private struct ExtensionActivatorRow: View {
    let trigger: ExtensionRegistry.ModeTriggerSpec

    var body: some View {
        HStack(spacing: sz(10)) {
            Image(systemName: trigger.icon)
                .foregroundStyle(Neon.textSecondary)
                .frame(width: sz(18))
            Text(trigger.prefix)
                .font(Neon.font(.body, design: .monospaced))
                .foregroundStyle(Neon.textPrimary)
                .padding(.horizontal, sz(8)).padding(.vertical, sz(2))
                .neonCard()
            Text(trigger.title).foregroundStyle(Neon.textPrimary)
            Spacer()
            if !trigger.extensionTitle.isEmpty {
                Text(trigger.extensionTitle).foregroundStyle(Neon.textSecondary)
            }
        }
    }
}

/// One rebindable global-shortcut row: title + recorder + reset/clear. Shared by
/// the Shortcuts pane and the Window Management pane.
private struct GlobalShortcutRow: View {
    @ObservedObject var model: SettingsModel
    let action: ShortcutAction

    var body: some View {
        HStack {
            Text(action.title).foregroundStyle(Neon.textPrimary)
            Spacer()
            ShortcutRecorder(combo: model.shortcutCombos[action] ?? action.defaultCombo) { combo in
                model.setShortcut(combo, for: action)
            }
            .frame(width: sz(110), height: sz(24))
            .fixedSize()
            Button {
                model.resetShortcut(action)
            } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .help("Reset to default")
            Button {
                model.clearShortcut(action)
            } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .help("Disable this shortcut")
        }
    }
}

/// One editable custom-shortcut row: command picker + recorder + delete.
/// Factored out of `ShortcutsPane` to keep the SwiftUI type-checker fast.
private struct CustomShortcutRow: View {
    @ObservedObject var model: SettingsModel
    let shortcut: CustomShortcut

    /// Built-in targets plus the live quickdir targets. If the saved prefix no
    /// longer matches any target (e.g. a quickdir was renamed/removed), keep its
    /// stored label/prefix in the list so the picker still shows the selection.
    private var targets: [ActivationTarget] {
        let base = ActivationTarget.allTargets(registry: SettingsHooks.shared.extensionRegistry)
        if base.contains(where: { $0.prefix == shortcut.prefix }) { return base }
        return base + [ActivationTarget(label: shortcut.label, prefix: shortcut.prefix)]
    }

    private var selectedTarget: Binding<ActivationTarget> {
        Binding(
            get: {
                targets.first { $0.prefix == shortcut.prefix } ?? targets[0]
            },
            set: { model.updateCustomShortcutTarget(id: shortcut.id, target: $0) }
        )
    }

    var body: some View {
        HStack {
            Picker("", selection: selectedTarget) {
                ForEach(targets) { t in
                    Text(t.label).tag(t)
                }
            }
            .labelsHidden()
            // Hug the menu button to its label so it sits flush-left in the row
            // (text left-aligned). A fixed width centered the label in the spare
            // space, leaving the dropdowns looking indented + mis-aligned.
            .fixedSize()

            Spacer()

            ShortcutRecorder(combo: shortcut.combo) { combo in
                model.updateCustomShortcutCombo(id: shortcut.id, combo: combo)
            }
            .frame(width: sz(110), height: sz(24))
            .fixedSize()

            Button {
                model.removeCustomShortcut(id: shortcut.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this shortcut")
        }
    }
}

/// One native key-mapping row: trigger → action → target, applied to the live engine
/// on every edit. Replaces the old appkeys/app-remaps/media-layer extensions.
private struct KeyMappingRow: View {
    @ObservedObject var model: SettingsModel
    let rule: ShortcutRulesStore.Rule

    private static let mediaNames = MediaKey.nameToCode.keys.sorted()

    private func update(_ mutate: (inout ShortcutRulesStore.Rule) -> Void) {
        var r = rule; mutate(&r); model.updateKeyMapping(r)
    }

    private var triggerIsMedia: Bool { rule.trigger.lowercased().hasPrefix("media:") }
    private var triggerCombo: KeyCombo { KeyCombo.parse(rule.trigger) ?? unsetKeyCombo }

    var body: some View {
        HStack(spacing: sz(8)) {
            triggerEditor
            Image(systemName: "arrow.right").foregroundStyle(Neon.textSecondary)
            Picker("", selection: Binding(
                get: { rule.action },
                set: { a in update { $0.action = a; $0.target = "" } }
            )) {
                Text("Launch App").tag(ShortcutRulesStore.ActionKind.launchApp)
                Text("Remap Key").tag(ShortcutRulesStore.ActionKind.remap)
                Text("Send Media").tag(ShortcutRulesStore.ActionKind.sendMedia)
                Text("Disable").tag(ShortcutRulesStore.ActionKind.swallow)
            }
            .labelsHidden().fixedSize()
            targetEditor
            Spacer()
            scopeEditor
            Button { model.removeKeyMapping(id: rule.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Remove this mapping")
        }
    }

    @ViewBuilder private var triggerEditor: some View {
        HStack(spacing: sz(2)) {
            if triggerIsMedia {
                Text(String(rule.trigger.dropFirst("media:".count)))
                    .foregroundStyle(Neon.textPrimary).frame(width: sz(96), alignment: .leading)
            } else {
                ShortcutRecorder(combo: triggerCombo) { combo in
                    if let s = combo.specString { update { $0.trigger = s } }
                }
                .frame(width: sz(96), height: sz(24)).fixedSize()
            }
            Menu {
                Button("Record Key…") { update { $0.trigger = "" } }
                Divider()
                ForEach(Self.mediaNames, id: \.self) { n in
                    Button(n) { update { $0.trigger = "media:\(n)" } }
                }
            } label: { Image(systemName: "chevron.down").imageScale(.small) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Use a media key as the trigger")
        }
    }

    /// Per-app scope: empty `apps` = every app; otherwise the rule only fires when one
    /// of the listed bundle ids is frontmost. Multi-select with checkmarks.
    @ViewBuilder private var scopeEditor: some View {
        Menu(scopeLabel) {
            Button("Any app") { update { $0.apps = [] } }
            Divider()
            ForEach(AppIndex.shared.ensureBuilt()) { app in
                let id = app.bundleId ?? app.url.path
                Button {
                    update {
                        if let i = $0.apps.firstIndex(of: id) { $0.apps.remove(at: i) }
                        else { $0.apps.append(id) }
                    }
                } label: {
                    if rule.apps.contains(id) { Label(app.name, systemImage: "checkmark") }
                    else { Text(app.name) }
                }
            }
        }
        .menuIndicator(.hidden).fixedSize().help("Limit this mapping to specific apps")
    }

    private var scopeLabel: String {
        switch rule.apps.count {
        case 0: return "Any app"
        case 1: return appDisplay(rule.apps[0])
        default: return "\(rule.apps.count) apps"
        }
    }

    @ViewBuilder private var targetEditor: some View {
        switch rule.action {
        case .launchApp:
            Menu(appDisplay(rule.target)) {
                ForEach(AppIndex.shared.ensureBuilt()) { app in
                    Button(app.name) { update { $0.target = app.bundleId ?? app.url.path } }
                }
            }
            .fixedSize()
        case .remap:
            ShortcutRecorder(combo: KeyCombo.parse(rule.target) ?? unsetKeyCombo) { combo in
                if let s = combo.specString { update { $0.target = s } }
            }
            .frame(width: sz(96), height: sz(24)).fixedSize()
        case .sendMedia:
            Picker("", selection: Binding(
                get: { rule.target.isEmpty ? Self.mediaNames.first! : rule.target.uppercased() },
                set: { v in update { $0.target = v } }
            )) {
                ForEach(Self.mediaNames, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
        case .swallow:
            Text("\u{2014}").foregroundStyle(Neon.textSecondary)
        }
    }

    /// Show the app's display name for a stored bundle-id/path target, else a prompt.
    private func appDisplay(_ target: String) -> String {
        guard !target.isEmpty else { return "Choose App\u{2026}" }
        if let app = AppIndex.shared.ensureBuilt().first(where: { $0.bundleId == target || $0.url.path == target }) {
            return app.name
        }
        return target
    }
}


// MARK: - About

// MARK: - Analytics

/// Opt-out usage analytics pane: a toggle plus a live, read-only dump of the EXACT
/// payload sent. Transparency by construction — what you see here is what is sent.
private struct AnalyticsPane: View {
    @ObservedObject var model: SettingsModel
    @State private var payload = ""
    @State private var sending = false
    @State private var sendResult: String?
    // Stable tick anchor — see AboutPane. A stored Date keeps the periodic schedule
    // fixed across body rebuilds instead of re-anchoring on every render.
    @State private var clock = Date()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium; f.timeStyle = .short
        return f
    }()

    /// Compact countdown, matching the About pane's "next check" style.
    private static func fmtCountdown(_ seconds: TimeInterval) -> String {
        let t = Int(seconds.rounded())
        let m = t / 60, s = t % 60
        if m >= 60 { let h = m / 60; return "\(h)h \(m % 60)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Analytics",
                      subtitle: "Anonymous usage stats — counters and on/off flags only")

            NeonSection("Usage Analytics",
                        footer: "Enabled by default. We collect only anonymous counters and settings flags to understand which features get used — never your text, names, prompts, file paths, links, or any personal data. Sent once a day to Aptabase (EU).") {
                Toggle("Share anonymous usage analytics", isOn: $model.analyticsEnabled)
            }

            if model.analyticsEnabled {
                // TimelineView's periodic schedule pauses while offscreen (the settings
                // window survives close), so the 1 Hz countdown stops burning CPU when
                // hidden — same approach as the About pane's update countdown.
                TimelineView(.periodic(from: clock, by: 1)) { timeline in
                    NeonSection("Send Schedule") {
                        let last = AnalyticsStore.lastSent
                        NeonRow("Last sent",
                                subtitle: last.map(Self.stamp.string(from:)) ?? "Not sent yet") {
                            EmptyView()
                        }
                        NeonDivider()
                        let next = last?.addingTimeInterval(86_400)
                        let remaining = next.map { max(0, $0.timeIntervalSince(timeline.date)) }
                        NeonRow("Next send",
                                subtitle: {
                                    guard let next, let remaining else { return "On next app launch" }
                                    return remaining <= 0
                                        ? "Due now (sends within the hour)"
                                        : "in \(Self.fmtCountdown(remaining)) · \(Self.stamp.string(from: next))"
                                }()) {
                            EmptyView()
                        }
                        NeonDivider()
                        NeonRow("Send now",
                                subtitle: sendResult ?? "Send the current payload immediately") {
                            Button(sending ? "Sending…" : "Send now") {
                                sending = true; sendResult = nil
                                Task { @MainActor in
                                    let ok = await AnalyticsService.shared.sendNow()
                                    sending = false
                                    sendResult = ok ? "Sent just now" : "Send failed — will retry automatically"
                                }
                            }
                            .buttonStyle(.neon)
                            .disabled(sending)
                        }
                    }
                }
            }

            NeonSection("Exactly what is sent",
                        footer: model.analyticsEnabled
                            ? "This is the live payload for the next daily send."
                            : "Analytics are off — nothing is sent.") {
                Text(payload.isEmpty ? "{}" : payload)
                    .font(Neon.font(11, design: .monospaced))
                    .foregroundStyle(Neon.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(model.analyticsEnabled ? 1 : 0.5)
            }
        }
        .onAppear { payload = AnalyticsSnapshot.prettyJSON() }
    }
}

/// Loads the recent-supporters list (`GET /supporters`) for the About pane.
/// Fail-soft: any network error just leaves the list empty so the section hides.
@MainActor
private final class SupportersLoader: ObservableObject {
    @Published private(set) var names: [String] = []
    private var loaded = false

    func loadOnce() async {
        guard !loaded, ProsperServer.isConfigured else { return }
        loaded = true
        var req = URLRequest(url: ProsperServer.baseURL.appending(path: "/supporters"))
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode ?? 0 < 300,
              let decoded = try? JSONDecoder().decode(SupportersResponse.self, from: data)
        else { return }
        names = decoded.supporters
    }

    private struct SupportersResponse: Codable { let supporters: [String] }
}

private struct AboutPane: View {
    // Stable tick anchor. Using `.now` inline would re-anchor the periodic schedule on
    // every body rebuild (e.g. each AppUpdater.downloadProgress change), jittering the
    // countdown; a stored Date keeps the schedule fixed across rebuilds.
    @State private var clock = Date()
    @StateObject private var supporters = SupportersLoader()
    // @AppStorage so the toggle re-renders on change — a hand-rolled Binding reading
    // UserDefaults.bool directly never invalidates the body, so the switch never flips.
    @AppStorage(TraceLog.key) private var traceVerbose = false

    /// One predicate catches both processes (app logs "ProsperTrace(app)", daemon
    /// "ProsperTrace"). `--last 1h` since the wake events happen while away.
    static let traceLogCommand =
        "log show --last 1h --predicate 'eventMessage CONTAINS \"ProsperTrace\"'"

    /// Formats a remaining-seconds interval as a compact countdown.
    private static func fmtCountdown(_ seconds: TimeInterval) -> String {
        let t = Int(seconds.rounded())
        let m = t / 60, s = t % 60
        if m >= 60 { let h = m / 60; return "\(h)h \(m % 60)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// The real app icon (neon Vulcan), matching the Dock/bundle icon, rather
    /// than a placeholder SF Symbol. Falls back to the bundled AppIcon then a
    /// symbol if the running app has no icon image (e.g. unbundled debug run).
    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApp.applicationIconImage
            ?? Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                .flatMap({ NSImage(contentsOf: $0) }) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: sz(96), height: sz(96))
                .shadow(color: Neon.blue.opacity(0.5), radius: sz(18))
        } else {
            Image(systemName: "character.bubble")
                .font(Neon.font(56))
                .foregroundStyle(Neon.blue)
                .shadow(color: Neon.blue.opacity(0.6), radius: sz(14))
        }
    }

    var body: some View {
        NeonScroll {
            VStack(spacing: sz(14)) {
                appIcon
                Text("PROSPER")
                    .font(Neon.font(26, weight: .heavy, design: .rounded))
                    .tracking(4)
                    .foregroundStyle(Neon.textPrimary)
                Text("Version \(AppInfo.displayVersion)")
                    .font(Neon.font(.callout)).foregroundStyle(Neon.blue)
                Text("System-wide inline autocomplete, command runner, and clipboard history.")
                    .multilineTextAlignment(.center).foregroundStyle(Neon.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, sz(8))

            // TimelineView's periodic schedule pauses while the view is offscreen.
            // The settings window outlives close (isReleasedWhenClosed = false), so
            // a plain Timer.publish ticker here kept re-rendering this pane at 1 Hz
            // forever — ~1% idle CPU with no window on screen.
            TimelineView(.periodic(from: clock, by: 1)) { timeline in
                let now = timeline.date
                NeonSection("Updates") {
                    // Label flips while a manual check / download is in flight; the
                    // section's 1s countdown re-render picks the state up, so no
                    // extra plumbing is needed.
                    let downloading = AppUpdater.shared.isDownloadingUpdate
                    let checking = AppUpdater.shared.isCheckingForUpdates
                    HStack {
                        Button(downloading ? "Downloading update…"
                               : checking ? "Checking for Updates…"
                               : "Check for Updates…") {
                            SettingsHooks.shared.onCheckForUpdates?()
                        }
                        .buttonStyle(.neon)
                        .disabled(checking || downloading)
                        Spacer()
                    }
                    if downloading {
                        NeonProgressBar(progress: AppUpdater.shared.downloadProgress)
                        Text("Downloading the new version — it will install and relaunch automatically.")
                            .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                    }
                    NeonDivider()
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { AppUpdater.shared.automaticChecks },
                        set: { AppUpdater.shared.automaticChecks = $0 }))
                    // Countdown hides while downloading — the next version is already
                    // on its way, so "next check" is noise.
                    if AppUpdater.shared.automaticChecks, !downloading,
                       let next = AppUpdater.shared.nextCheckDate {
                        let remaining = max(0, next.timeIntervalSince(now))
                        Text("Next check in \(Self.fmtCountdown(remaining))")
                            .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                    }
                    NeonDivider()
                    Toggle("Receive beta (pre-release) updates", isOn: Binding(
                        get: { AppUpdater.shared.allowBetaUpdates },
                        set: { AppUpdater.shared.allowBetaUpdates = $0 }))
                    Text("Get early builds before they're promoted to everyone. Beta builds are tested but may be less stable.")
                        .font(Neon.font(.caption2)).foregroundStyle(Neon.textSecondary)
                }
            }

            NeonSection("Engine") {
                Text("Inline completions — local inference via Apple MLX (mlx-swift-lm), running a model of your choice (such as Gemma) selectable in Completions.")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                NeonDivider()
                Text("Coding agent — OpenAI's Codex harness over a local OpenAI-compatible server, running a selectable coding model (such as Qwen). Extensible with MCP servers, lifecycle hooks, and JS/TS plugins.")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                NeonDivider()
                Text("Extensions — vendored Lua 5.4 runtime · JS/TS plugins run on Bun.")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                NeonDivider()
                Text("Acknowledgments: mlx-swift, swift-transformers, GRDB.swift (encrypted store), Sparkle (auto-update), TOMLDecoder, Aptabase (anonymous analytics), and Apple's Vision / ScreenCaptureKit for screen context.")
                    .font(Neon.font(.caption2)).foregroundStyle(Neon.textSecondary)
            }

            NeonSection("Troubleshooting",
                        footer: "Logs the remote-wake and keep-awake decision path (app + privileged daemon) to the unified system log, to diagnose why a Mac won't wake or stay awake. Leave off for normal use.") {
                Toggle("Verbose troubleshooting log", isOn: $traceVerbose)
                    .onChange(of: traceVerbose) {
                        // Push the new flag to a running daemon (no-op if remote-wake off).
                        LiveExtensionHostServices.reapplyRemoteWakeForTrace()
                    }
                Text("Read the captured log (events persist across sleep — run after reproducing):")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                HStack(spacing: sz(8)) {
                    Text(Self.traceLogCommand)
                        .font(Neon.font(11, design: .monospaced))
                        .foregroundStyle(Neon.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.traceLogCommand, forType: .string)
                    }.buttonStyle(.neon)
                }
            }

            if !supporters.names.isEmpty {
                NeonSection("Supporters ♥",
                            footer: "People who chipped in to keep Prosper free for everyone. Thank you.") {
                    Text(supporters.names.joined(separator: " · "))
                        .font(Neon.font(12))
                        .foregroundStyle(Neon.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task { await supporters.loadOnce() }
    }
}

// MARK: - Neon progress bar

/// A slim neon-gradient progress bar. A known fraction fills left-to-right; a
/// nil fraction renders the full bar with a slow opacity pulse (indeterminate).
/// Used by the About pane while an update downloads/extracts, and by the Agent pane
/// while a model downloads.
struct NeonProgressBar: View {
    /// 0…1, or nil while the total size is unknown.
    let progress: Double?
    @State private var pulsing = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Neon.card)
                    .overlay(Capsule().strokeBorder(Neon.stroke, lineWidth: 1))
                Capsule()
                    .fill(LinearGradient(colors: [Neon.blue, Neon.blueBright],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, geo.size.width * (progress ?? 1)))
                    .opacity(progress == nil ? (pulsing ? 0.35 : 0.9) : 1)
                    .shadow(color: Neon.blue.opacity(0.5), radius: sz(4))
                    .animation(.easeInOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: sz(6))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}

// MARK: - Shared dark text editor

/// A dark, neon-edged multiline editor used for instruction fields. The default
/// `TextEditor` paints an opaque light backdrop that clashes with the console
/// theme, so we hide it and repaint a deep card surface.
struct NeonTextEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 120

    var body: some View {
        TextEditor(text: $text)
            .font(Neon.font(.body, design: .monospaced))
            .foregroundStyle(Neon.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(sz(8))
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                    .fill(Neon.bgBottom))
            .overlay(
                RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                    .strokeBorder(Neon.stroke, lineWidth: 1))
    }
}

/// A neon-edged WYSIWYG rich-text editor whose binding is an RTF document string.
/// Used for rich snippets so authors edit formatting visually instead of raw RTF.
struct NeonRichTextEditor: View {
    @Binding var rtf: String
    var minHeight: CGFloat = 120

    var body: some View {
        RichTextEditorRepresentable(rtf: $rtf)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: sz(8), style: .continuous).fill(Neon.bgBottom))
            .overlay(
                RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                    .strokeBorder(Neon.stroke, lineWidth: 1))
    }
}

/// `NSTextView`-backed rich editor. Reads its binding as an RTF document (falls
/// back to seeding plain text when the string isn't valid RTF yet) and writes
/// edits back as an RTF string, without clobbering the caret on echo updates.
private struct RichTextEditorRepresentable: NSViewRepresentable {
    @Binding var rtf: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13 * ThemeRuntime.scale)
        textView.textColor = NSColor(Neon.textPrimary)
        textView.insertionPointColor = NSColor(Neon.blue)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        context.coordinator.textView = textView
        context.coordinator.apply(rtf)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Track the latest binding (SwiftUI recreates the struct on updates).
        context.coordinator.parent = self
        // Skip echo of our own edit (keeps the caret); only re-apply external changes.
        guard rtf != context.coordinator.lastWritten else { return }
        context.coordinator.apply(rtf)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditorRepresentable
        weak var textView: NSTextView?
        var lastWritten: String?

        init(_ parent: RichTextEditorRepresentable) { self.parent = parent }

        func apply(_ rtf: String) {
            guard let tv = textView else { return }
            lastWritten = rtf
            if let data = rtf.data(using: .utf8),
               let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil) {
                tv.textStorage?.setAttributedString(attr)
            } else {
                tv.string = rtf   // not valid RTF yet → seed as plain text
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let storage = textView?.textStorage else { return }
            let range = NSRange(location: 0, length: storage.length)
            guard let data = try? storage.rtf(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]),
                let s = String(data: data, encoding: .utf8) else { return }
            lastWritten = s
            parent.rtf = s
        }
    }
}

// MARK: - Sidebar group ordering

// MARK: - Window Management

private struct WindowManagementPane: View {
    @ObservedObject var model: SettingsModel
    @AppStorage("settingsSelectedPane") private var selection = "general"
    @State private var hasAccessibility = PermissionsManager.isAccessibilityTrusted()
    @State private var newIgnored = ""
    @State private var showLayoutEditor = false

    // Rendered as the footer of the window extension's settings pane (inside its
    // NeonScroll), so no own scroll/title — the page header already names it.
    var body: some View {
        VStack(alignment: .leading, spacing: sz(16)) {
            NeonSection("Panel placement",
                        footer: "Where the command runner (⌥Space) and Clipboard History open on a multi-display setup. “Screen under the cursor” follows your pointer like Raycast and Ditto; “Last position” reopens wherever you last dragged the runner; “Main screen” always uses the display with the menu bar.") {
                Picker("Open on", selection: $model.runnerPlacement) {
                    ForEach(RunnerPlacement.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            NeonSection("Drag to Snap",
                        footer: "Drag a window so the pointer reaches a screen edge or corner; a live preview shows where it will land, and it snaps there when you let go. Left/right/bottom edges give halves, the top edge maximizes, and corners give quarters.") {
                Toggle("Enable drag-to-snap", isOn: Binding(
                    get: { model.dragSnapEnabled },
                    set: { model.setDragSnap($0) }))
                if model.dragSnapEnabled && !hasAccessibility {
                    NeonDivider()
                    PermissionWarningRow(
                        title: "Accessibility permission needed",
                        message: "Snapping can't move windows until you grant it. Open Context to fix.") {
                            selection = "context"
                        }
                }
            }

            NeonSection("Trigger",
                        footer: "Require a modifier key to be held while dragging, to avoid accidental snaps. With no modifier, any drag to an edge snaps.") {
                Picker("Snap when dragging", selection: $model.dragSnapModifier) {
                    ForEach(DragSnapModifier.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            .disabled(!model.dragSnapEnabled)

            NeonSection("Preview",
                        footer: "Vibrancy (the default) blurs the snap area and tints it with your accent color. Turn it off for a simple flat translucent fill (flat is forced while Reduce Transparency is on).") {
                Toggle("Use vibrancy preview", isOn: $model.dragSnapStyleVibrancy)
            }
            .disabled(!model.dragSnapEnabled)

            NeonSection("Zones",
                        footer: "Edge sensitivity is how close to a screen edge the pointer must reach to trigger a snap; corner size is how large the quarter-snap corner squares are.") {
                NeonRow("Edge sensitivity", subtitle: "\(Int(model.dragSnapEdgeMargin)) px") {
                    Slider(value: $model.dragSnapEdgeMargin,
                           in: Preferences.dragSnapEdgeMarginRange, step: 1)
                        .frame(width: sz(200))
                }
                NeonDivider()
                NeonRow("Corner size", subtitle: "\(Int(model.dragSnapCornerSize)) px") {
                    Slider(value: $model.dragSnapCornerSize,
                           in: Preferences.dragSnapCornerSizeRange, step: 5)
                        .frame(width: sz(200))
                }
            }
            .disabled(!model.dragSnapEnabled)

            NeonSection("Layouts",
                        footer: "“Edges & corners” gives the classic half/quarter snaps. “Layout zones” shows your active custom layout’s tiles on screen while dragging, and drops the window into whichever tile the pointer is over. “Layout palette” shows all your layouts as small templates near the top of the screen — drag onto a cell to send the window to that spot.") {
                Picker("Snap into", selection: $model.snapMode) {
                    ForEach(SnapMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.snapMode != .edges {
                    if model.snapMode == .layouts {
                        NeonDivider()
                        Picker("Active layout", selection: Binding(
                            get: { model.layoutStore.activeLayout?.id },
                            set: { model.layoutStore.activeLayoutId = $0 })) {
                            ForEach(model.layoutStore.allLayouts) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    NeonDivider()
                    NeonRow("Gap", subtitle: "\(Int(model.layoutGap)) px") {
                        Slider(value: $model.layoutGap, in: Preferences.layoutGapRange, step: 1)
                            .frame(width: sz(200))
                    }
                    NeonDivider()
                    Button("Edit Layouts…") { showLayoutEditor = true }.buttonStyle(.neon)
                }
            }
            .disabled(!model.dragSnapEnabled)

            NeonSection("Excluded apps",
                        footer: "Windows of these apps never snap (use for apps that manage their own layout). Fixed-size dialogs are skipped automatically.") {
                if model.dragSnapIgnoredBundleIds.isEmpty {
                    Text("None").foregroundStyle(Neon.textSecondary).font(Neon.font(.caption))
                } else {
                    ForEach(Array(model.dragSnapIgnoredBundleIds.enumerated()), id: \.element) { idx, id in
                        if idx > 0 { NeonDivider() }
                        HStack {
                            Text(id).font(Neon.font(.body, design: .monospaced))
                                .foregroundStyle(Neon.textPrimary)
                            Spacer()
                            Button(role: .destructive) { model.removeDragSnapIgnored(id) } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(Neon.magenta)
                            }.buttonStyle(.borderless)
                        }
                    }
                }
                NeonDivider()
                HStack {
                    TextField("com.example.app", text: $newIgnored)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addManual)
                    Button("Add", action: addManual).buttonStyle(.neon)
                        .disabled(newIgnored.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Choose App…", action: pickApp).buttonStyle(.neon)
                }
            }
            .disabled(!model.dragSnapEnabled)
        }
        .onAppear { hasAccessibility = PermissionsManager.isAccessibilityTrusted() }
        .sheet(isPresented: $showLayoutEditor) {
            LayoutEditorView(store: $model.layoutStore)
        }
    }

    private func addManual() {
        let id = newIgnored.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        model.addDragSnapIgnored(id)
        newIgnored = ""
    }

    /// Pick a .app and resolve its bundle id — friendlier than typing a reverse-DNS id.
    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        model.addDragSnapIgnored(id)
    }
}

// MARK: - Menu Bar Management

/// Footer pane for the menubar extension's settings section (renders inside its
/// NeonScroll, below the declarative shortcut header). Spacing slider, two-tier
/// hide + hover/auto-rehide toggles, chevron-style picker, a read-only preview
/// strip of the live bar, and the data-loss-safe "relaunch to apply spacing".
/// Reordering is intentionally NOT here — macOS owns icon order (⌘-drag), so the
/// preview just hints the user to do that natively.
private struct MenuBarPane: View {
    @ObservedObject var model: SettingsModel
    @State private var store = Preferences.menuBarStore
    @State private var orderStore = Preferences.menuBarOrderStore
    @State private var sections: [(item: MenuBarItem, section: MenuBarSection)] = []
    @State private var previewHealthy = true
    @State private var skipped: [String] = []
    @State private var relaunching = false
    @State private var probeOK: Bool? = nil      // nil = not run; true iff probeReason == .ok
    @State private var probeReason: MenuBarItemMover.ProbeResult? = nil   // why the probe passed/failed
    @State private var probing = false
    @State private var applying = false
    @State private var saving = false
    @State private var screenRecOK = MenuBarItemIndexer.hasPermission()
    @State private var previewImages: [CGWindowID: NSImage] = [:]   // live per-item captures (Tahoe: only way to show real icons)
    @State private var lastApply: MenuBarArranger.ApplyResult?

    // OS gate is fixed for the running system — decide once.
    private let orderingSupport = MenuBarOrderingCapability.osSupport(
        major: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)

    var body: some View {
        VStack(alignment: .leading, spacing: sz(16)) {
            NeonSection("Icon spacing",
                        footer: "Spacing (in points) between every menu-bar icon. macOS default is 16. New value applies as apps next launch — use “Apply now” to relaunch running menu-bar apps.") {
                NeonRow("Spacing", subtitle: "\(store.clampedSpacing) px") {
                    Slider(value: Binding(get: { Double(store.clampedSpacing) },
                                          set: { setSpacing(Int($0.rounded())) }),
                           in: Double(MenuBarSpacing.minSpacing)...Double(MenuBarSpacing.maxSpacing), step: 1)
                        .frame(width: sz(200))
                }
                NeonDivider()
                Button(relaunching ? "Relaunching…" : "Apply now (relaunch menu-bar apps)") { applyNow() }
                    .buttonStyle(.neon)
                    .disabled(relaunching)
                if !skipped.isEmpty {
                    Text("Skipped (unsaved work / declined to quit): \(skipped.joined(separator: ", ")). Quit and reopen them yourself to apply.")
                        .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                }
            }

            NeonSection("Hide & reveal",
                        footer: "A chevron sits in your menu bar. Drag any icon to its LEFT to hide it; click the chevron (or the reveal shortcut) to show the hidden icons. They auto-rehide after a few seconds.") {
                Toggle("Two-tier hide — add an always-hidden section", isOn: Binding(
                    get: { store.alwaysHiddenEnabled },
                    set: { v in mutate { $0.alwaysHiddenEnabled = v }; MenuBarManager.shared.reconcileDividers() }))
                Text("Adds a second chevron. ⌘-drag an icon to its LEFT to hide it for good; ⌥-click the chevron to peek at that section. Items between the two chevrons hide/reveal normally.")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                NeonDivider()
                Toggle("Reveal on hover", isOn: Binding(
                    get: { store.hoverReveal },
                    set: { v in mutate { $0.hoverReveal = v } }))
                NeonDivider()
                NeonRow("Auto-rehide", subtitle: "\(store.clampedAutoRehide) s") {
                    Slider(value: Binding(get: { Double(store.clampedAutoRehide) },
                                          set: { v in mutate { $0.autoRehideSeconds = Int(v.rounded()) } }),
                           in: 1...30, step: 1)
                        .frame(width: sz(200))
                }
                NeonDivider()
                NeonRow("Chevron", subtitle: "Divider glyph") {
                    Picker("", selection: Binding(
                        get: { store.chevronStyle },
                        set: { v in mutate { $0.chevronStyle = v }; MenuBarManager.shared.refreshChevronStyle() })) {
                        ForEach(ChevronStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: sz(160))
                }
            }

            NeonSection("Your menu bar",
                        footer: "Live preview of your primary display. To move an icon between sections (or reorder it), hold ⌘ and drag it directly in the real menu bar — macOS remembers the new position. Drag an icon to the LEFT of a chevron to hide it.") {
                MenuBarPreviewStrip(elements: previewElements(), chevron: store.chevronStyle,
                                    spacing: store.clampedSpacing, healthy: previewHealthy)
                if !screenRecOK {
                    NeonDivider()
                    NeonRow("Show real icons",
                            subtitle: "This macOS hides each item’s app identity, so the preview needs Screen Recording to show the actual icons. Hide/reveal works without it.") {
                        Button("Grant…") {
                            MenuBarItemIndexer.requestPermission()
                            Task { try? await Task.sleep(for: .milliseconds(500)); refresh() }
                        }.buttonStyle(.neon)
                    }
                }
                NeonDivider()
                Text("Hold ⌘ and drag icons in your menu bar to reorder or re-section them.")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                NeonDivider()
                Button("Refresh") { refresh() }.buttonStyle(.neon)
            }

            orderingSection
        }
        .onAppear {
            store = Preferences.menuBarStore
            orderStore = Preferences.menuBarOrderStore
            refresh()
        }
    }

    // MARK: - Item ordering (opt-in, version-gated; engine wired in later phases)

    @ViewBuilder private var orderingSection: some View {
        NeonSection("Item ordering (experimental)",
                    footer: "Keeps multi-icon apps (Stats, iStat Menus) in a fixed order across relaunch — the one thing macOS itself loses. Opt-in and version-gated: it only runs where Prosper can drive it reliably. Off does nothing.") {
            switch orderingSupport {
            case .unsupportedOS(let message):
                Text(message)
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            case .supported:
                Toggle("Enforce a saved menu-bar order", isOn: Binding(
                    get: { orderStore.enabled },
                    set: { v in mutateOrder { $0.enabled = v }; if v { runProbe() } }))
                NeonDivider()
                NeonRow("When", subtitle: "How aggressively to keep the order") {
                    Picker("", selection: Binding(
                        get: { orderStore.mode },
                        set: { v in mutateOrder { $0.mode = v } })) {
                        Text("On reveal").tag(MenuBarOrderStore.EnforceMode.onDemand)
                        Text("Always (live)").tag(MenuBarOrderStore.EnforceMode.live)
                    }
                    .labelsHidden()
                    .frame(width: sz(160))
                    .disabled(!orderStore.enabled)
                }
                if orderStore.enabled {
                    NeonDivider()
                    probeStatusRow
                    if !screenRecOK {
                        NeonDivider()
                        screenRecordingRow
                    }
                    NeonDivider()
                    HStack(spacing: sz(8)) {
                        Button(saving ? "Saving…" : "Save current order") { saveOrder() }
                            .buttonStyle(.neon)
                            .disabled(saving || applying)
                        Button(applying ? "Applying…" : "Apply saved order") { applyOrder() }
                            .buttonStyle(.neon)
                            .disabled(applying || saving || orderStore.desiredOrder.isEmpty || probeOK != true)
                    }
                    Text(orderStatusText)
                        .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                    if !orderStore.desiredOrder.isEmpty {
                        NeonDivider()
                        orderEditor
                    }
                }
            }
        }
        .task(id: orderStore.enabled) { if orderStore.enabled && probeOK == nil { runProbe() } }
    }

    /// Drag-to-reorder editor over the saved layout — define the desired left→right
    /// order here instead of ⌘-dragging the real bar then "Save current order".
    /// "Apply saved order" then drives the bar to match.
    @ViewBuilder private var orderEditor: some View {
        VStack(alignment: .leading, spacing: sz(4)) {
            Text("Saved order (drag to reorder, ⌫ to remove)")
                .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            List {
                ForEach(orderStore.desiredOrder, id: \.key) { id in
                    HStack(spacing: sz(8)) {
                        if let icon = Self.appIcon(id.bundleID) {
                            Image(nsImage: icon).resizable().frame(width: sz(16), height: sz(16))
                        }
                        Text(Self.displayName(id)).font(Neon.font(.body))
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                }
                .onMove { from, to in mutateOrder { $0.desiredOrder.move(fromOffsets: from, toOffset: to) } }
                .onDelete { idx in mutateOrder { $0.desiredOrder.remove(atOffsets: idx) } }
            }
            .frame(height: sz(min(CGFloat(orderStore.desiredOrder.count) * 26 + 8, 200)))
            .scrollContentBackground(.hidden)
        }
    }

    /// App icon for a bundle id (running app first, then on-disk lookup). nil for the
    /// "unknown" placeholder bundle.
    private static func appIcon(_ bundleID: String) -> NSImage? {
        guard bundleID != "unknown" else { return nil }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app.icon
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    /// Human label for an identity: the OS title, else the app's localized name,
    /// else the bundle id. Multi-icon siblings (same bundle, distinct hash) get a
    /// short hash tag so they're tellable apart.
    private static func displayName(_ id: MenuBarIdentity) -> String {
        if let t = id.title, !t.isEmpty, t != "Menu Item" { return t }
        let base = NSRunningApplication.runningApplications(withBundleIdentifier: id.bundleID)
            .first?.localizedName ?? id.bundleID
        if let h = id.imageHash { return "\(base) · \(h.prefix(4))" }
        return base
    }

    @ViewBuilder private var probeStatusRow: some View {
        switch probeReason {
        case .some(.ok):
            Label("Move test passed — ordering works on this Mac.", systemImage: "checkmark.seal.fill")
                .font(Neon.font(.caption)).foregroundStyle(Neon.terminal)
        case .some(.needsAccessibility):
            VStack(alignment: .leading, spacing: sz(4)) {
                Label("Ordering needs Accessibility permission to move icons.", systemImage: "lock.shield")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                Button("Grant Accessibility…") {
                    _ = PermissionsManager.ensureAccessibilityTrust(prompt: true)
                    // Let the user flip the switch, then re-run the probe.
                    probeReason = nil; probeOK = nil
                    Task { try? await Task.sleep(for: .milliseconds(800)); runProbe() }
                }.buttonStyle(.neon)
            }
        case .some(.moveFailed):
            Label("Move test failed — this Mac’s menu bar didn’t accept the reorder. Ordering is disabled.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
        case .some(.unavailable), .some(.enumerationFailed):
            Label("Move test couldn’t run on this version of macOS — ordering is disabled.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
        case nil:
            Label(probing ? "Running move test…" : "Move test not run yet.",
                  systemImage: "hourglass")
                .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
        }
    }

    @ViewBuilder private var screenRecordingRow: some View {
        NeonRow("Screen Recording",
                subtitle: "Needed only on this macOS to tell multi-icon apps apart (Stats CPU vs RAM). Without it, those items stay in place.") {
            Button("Grant…") {
                MenuBarItemIndexer.requestPermission()
                // Grant takes effect after the system dialog; re-poll shortly.
                Task { try? await Task.sleep(for: .milliseconds(500)); screenRecOK = MenuBarItemIndexer.hasPermission() }
            }.buttonStyle(.neon)
        }
    }

    private var orderStatusText: String {
        if orderStore.desiredOrder.isEmpty {
            return "No saved order yet. Arrange your icons (⌘-drag), then “Save current order”."
        }
        let n = orderStore.desiredOrder.count
        if let r = lastApply {
            return "Saved \(n) items. Last apply: moved \(r.moved), \(r.failed) failed, \(r.skippedUnresolved) not yet identifiable."
        }
        return "Saved \(n) items. “Apply saved order” to restore it."
    }

    private func runProbe() {
        guard probeReason == nil, !probing else { return }
        probing = true
        Task {
            let result = await MenuBarItemMover.selfProbe()
            probing = false
            probeReason = result
            let ok = (result == .ok)
            probeOK = ok
            // Don't hard-disable when it's only a missing Accessibility grant — the
            // user gets a "Grant…" button and can re-probe. Disable on real failures.
            if !ok && result != .needsAccessibility { mutateOrder { $0.enabled = false } }
            if ok { MenuBarOrderEnforcer.shared.update(store: orderStore, probeOK: true) }
        }
    }

    private func saveOrder() {
        guard !saving, !applying else { return }
        saving = true
        Task {
            let order = await MenuBarArranger.snapshotCurrentOrder()
            mutateOrder { $0.desiredOrder = order }
            screenRecOK = MenuBarItemIndexer.hasPermission()
            saving = false
        }
    }

    private func applyOrder() {
        guard !applying, !saving else { return }
        applying = true
        Task {
            lastApply = await MenuBarArranger.apply(desired: orderStore.desiredOrder)
            applying = false
        }
    }

    // MARK: - Actions

    private func mutate(_ change: (inout MenuBarStore) -> Void) {
        var s = store
        change(&s)
        store = s
        Preferences.menuBarStore = s
    }

    private func mutateOrder(_ change: (inout MenuBarOrderStore) -> Void) {
        var s = orderStore
        change(&s)
        orderStore = s
        Preferences.menuBarOrderStore = s
        MenuBarOrderEnforcer.shared.update(store: s, probeOK: probeOK == true)
    }

    private func setSpacing(_ value: Int) {
        mutate { $0.spacing = value }
        MenuBarManager.shared.setSpacing(value)
    }

    private func applyNow() {
        let apps = MenuBarSpacing.owningApps()
        guard !apps.isEmpty else { return }
        relaunching = true
        skipped = []
        MenuBarSpacing.relaunchOwners(apps) { skippedNames in
            skipped = skippedNames
            relaunching = false
        }
    }

    private func refresh() {
        previewHealthy = MenuBarManager.shared.previewHealthy()
        sections = MenuBarManager.shared.sectionedItems()
        capturePreviewIcons()
    }

    /// Capture a live image for each currently-visible item so the preview shows
    /// real icons. On Tahoe pid-based icons are dead (every item = Control Center),
    /// so this is the only source. Needs Screen Recording; without it we keep the
    /// placeholder glyphs. Off-screen (hidden) items can't be captured — they fall
    /// back to placeholders too.
    private func capturePreviewIcons() {
        screenRecOK = MenuBarItemIndexer.hasPermission()
        guard screenRecOK else { previewImages = [:]; return }
        let items = sections.map(\.item)
        Task {
            let cgs = await MenuBarItemIndexer.images(for: items)
            var out: [CGWindowID: NSImage] = [:]
            for (wid, cg) in cgs {
                out[wid] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            previewImages = out
        }
    }

    /// Flatten the sectioned items (left→right) into preview elements, dropping a
    /// chevron marker at each section boundary — exactly where a real divider sits.
    /// All-visible bars show no chevron (nothing is hidden), matching the real bar.
    private func previewElements() -> [PreviewElement] {
        var out: [PreviewElement] = []
        var prev: MenuBarSection?
        for entry in sections {
            if let p = prev, p != entry.section { out.append(.chevron) }
            // Live capture first (only reliable icon source on Tahoe), then the
            // pid-based app icon (works pre-Tahoe), else a placeholder glyph.
            let img = previewImages[entry.item.windowID]
                ?? NSRunningApplication(processIdentifier: entry.item.pid)?.icon
            out.append(.icon(img, dimmed: entry.section != .visible))
            prev = entry.section
        }
        return out
    }
}

/// One slot in the preview strip: an app icon (dimmed when in a hidden band) or a
/// chevron marking a section boundary.
private enum PreviewElement {
    case icon(NSImage?, dimmed: Bool)
    case chevron
}

/// Read-only mock of the live menu bar: app icons in their real left→right order,
/// chevrons at the section boundaries, inter-icon gap scaled to the chosen
/// spacing. Purely illustrative — no interaction (reorder is a native ⌘-drag).
private struct MenuBarPreviewStrip: View {
    let elements: [PreviewElement]
    let chevron: ChevronStyle
    let spacing: Int
    var healthy: Bool = true

    var body: some View {
        Group {
            if !healthy {
                // CGS enumeration can't see windows that provably exist — a newer
                // macOS shifted menu-bar semantics. Hide/reveal + spacing still work;
                // only this preview can't be drawn. (See MenuBarLogic.previewHealthy.)
                Text("Live preview isn’t available on this version of macOS. Your icons are still hidden, revealed, and spaced correctly — only this preview needs a macOS update.")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            } else if elements.isEmpty {
                Text("No menu-bar items detected (or the feature is off).")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
            } else {
                HStack(spacing: max(sz(2), CGFloat(spacing) * 0.5)) {
                    ForEach(Array(elements.enumerated()), id: \.offset) { _, el in
                        switch el {
                        case .icon(let img, let dimmed):
                            if let img {
                                Image(nsImage: img).resizable().interpolation(.high)
                                    .frame(width: sz(18), height: sz(18))
                                    .opacity(dimmed ? 0.4 : 1)
                            } else {
                                Image(systemName: "app.dashed")
                                    .frame(width: sz(18), height: sz(18))
                                    .foregroundStyle(Neon.textSecondary)
                            }
                        case .chevron:
                            Image(systemName: chevron.collapsedSymbol)
                                .foregroundStyle(Neon.textPrimary)
                                .frame(width: sz(16))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)   // bar grows from the right edge
                .padding(.horizontal, sz(10)).padding(.vertical, sz(6))
                .background(RoundedRectangle(cornerRadius: sz(6)).fill(Color.black.opacity(0.28)))
            }
        }
    }
}

/// The Settings sidebar's grouped navigation, derived from the live registry.
/// Extracted from the view so launch-time verification can assert ordering
/// without opening a window. "Extension Settings" sits above "More" so user
/// extensions read before the catch-all tail (Analytics / About).
@MainActor
func settingsSidebarGroups(registry: ExtensionRegistry?) -> [(String, [SettingsTab])] {
    // Everything under "Inline Autocomplete" only affects the typing-completion
    // feature and is inert when it's off; the runner/general tabs are separate.
    // Snippets is no longer hardcoded here — the snippets extension contributes
    // its own dynamic "Snippets" tab via [[contributes.settings_sections]].
    var general: [SettingsTab] = [
        SettingsTab(id: "general", title: "General", icon: "gearshape.fill"),
        SettingsTab(id: "shortcuts", title: "Shortcuts", icon: "command"),
        // Window Management is no longer a static tab — it merged into the single
        // window extension's settings section (drag-snap config rides in as that
        // pane's header). Disabling the extension hides the whole section AND, via
        // DragSnapController.windowExtLive, disables the drag-snap feature too.
        SettingsTab(id: "appearance", title: "Appearance", icon: "paintpalette.fill"),
    ]
    if registry != nil {
        general.append(SettingsTab(id: "extensions", title: "Extensions", icon: "puzzlepiece.extension.fill"))
    }
    let autocomplete: [SettingsTab] = [
        SettingsTab(id: "completions", title: "Completions", icon: "text.cursor"),
        SettingsTab(id: "context", title: "Context", icon: "camera.viewfinder"),
        SettingsTab(id: "apps", title: "Apps", icon: "square.grid.2x2.fill"),
        SettingsTab(id: "personalization", title: "Personalization", icon: "person.crop.circle.fill"),
        SettingsTab(id: "statistics", title: "Statistics", icon: "chart.bar.fill"),
    ]
    let agent: [SettingsTab] = [
        SettingsTab(id: "agent", title: "Model", icon: "wand.and.stars"),
        SettingsTab(id: "agent-mcp", title: "MCP Servers", icon: "server.rack"),
        SettingsTab(id: "agent-plugins", title: "Plugins & Hooks", icon: "puzzlepiece.fill"),
        SettingsTab(id: "agent-commands", title: "Commands", icon: "terminal.fill"),
        SettingsTab(id: "agent-personas", title: "Personas", icon: "person.2.fill"),
        SettingsTab(id: "agent-permissions", title: "Permissions", icon: "lock.shield.fill"),
    ]
    let more: [SettingsTab] = [
        SettingsTab(id: "account", title: "Account", icon: "person.badge.key.fill"),
        SettingsTab(id: "sync", title: "Sync", icon: "arrow.triangle.2.circlepath"),
        SettingsTab(id: "analytics", title: "Analytics", icon: "antenna.radiowaves.left.and.right"),
        SettingsTab(id: "about", title: "About", icon: "info.circle.fill"),
    ]
    // Extensions that declare a sidebar-placed settings section each get their
    // own rail entry (id "ext:<extID>|<sectionID>"). See EXTENSION_SETTINGS_SPEC.md.
    var extensionSections: [SettingsTab] = []
    if let registry {
        for (record, section) in registry.settingsSections(placement: "sidebar") {
            extensionSections.append(SettingsTab(
                id: "ext:\(record.id)|\(section.id)",
                title: section.title,
                icon: section.icon ?? record.manifest.extension.icon ?? "puzzlepiece.extension.fill",
                accent: section.accent))
        }
    }
    var result: [(String, [SettingsTab])] = [("General", general)]
    // AI Models is its own top-level group right under General: it manages BOTH the
    // inline and agent models (download/load/RAM/custom), so it must show regardless of
    // which feature master-switch is on.
    result.append(("AI Models", [SettingsTab(id: "ai-models", title: "AI Models", icon: "cpu")]))
    // System Stats is its own top-level group (native menu-bar monitors); the
    // pane's master switch gates the whole feature, so it shows regardless.
    result.append(("System Stats", [SettingsTab(id: "system-stats", title: "System Stats", icon: "speedometer", accent: "Stats")]))
    // Extension Settings sits right after General so user extensions read first,
    // ahead of the built-in feature groups.
    if !extensionSections.isEmpty { result.append(("Extension Settings", extensionSections)) }
    // The two feature categories are shown only while their master switch (in
    // General) is on — their tabs are inert otherwise. The switches themselves
    // live in General, so a hidden category is always re-enableable.
    if Preferences.autocompleteEnabled { result.append(("Inline Autocomplete", autocomplete)) }
    if Preferences.agentEnabled { result.append(("Coding Agent", agent)) }
    result.append(("More", more))
    return result
}

// MARK: - Launch-time verification (PROSPER_VERIFY=1)

/// Exercises the real settings code paths headlessly (no window needed), so the
/// sidebar ordering and the bookmarks Full-Disk-Access gate can be verified on a
/// locked / headless display where AppKit windows won't render. Prints to stdout;
/// only reached when PROSPER_VERIFY is set, and AppDelegate exits right after.
@MainActor
enum ProsperVerify {
    static func run(registry passedRegistry: ExtensionRegistry) async {
        print("=== PROSPER_VERIFY ===")

        // When PROSPER_VERIFY_EXT_DIR points at the source `extensions/` tree, load
        // a FRESH registry from it into a throwaway temp userDir (hostVersion 0.0.0
        // forces a clean dev-overwrite). This verifies the edited source, not the
        // stale ~/.config/prosper/extensions a prior real launch seeded — and never
        // mutates the user's real extension store.
        let registry: ExtensionRegistry
        if let src = ProcessInfo.processInfo.environment["PROSPER_VERIFY_EXT_DIR"] {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("prosper-verify-ext-\(getpid())", isDirectory: true)
            registry = ExtensionRegistry(systemDir: URL(fileURLWithPath: src),
                                         userDir: tmp, hostVersion: "0.0.0", callTimeout: 60)
            registry.discover()
            print("verify-source: \(src)")
        } else {
            registry = passedRegistry
        }

        // Bug 2: sidebar group order — "Extension Settings" before "More".
        let order = settingsSidebarGroups(registry: registry).map(\.0)
        print("group-order: \(order.joined(separator: " | "))")
        if let e = order.firstIndex(of: "Extension Settings"), let m = order.firstIndex(of: "More") {
            print("bug2 ext-before-more: \(e < m)")
        } else {
            print("bug2 ext-before-more: MISSING (ext or more absent)")
        }

        // Bug 1a: bookmarks Full Disk Access row gated on the source.safari toggle.
        guard let (_, section) = registry.settingsSection(
            extensionID: "com.prosper.bookmarks", sectionID: "bookmarks") else {
            print("bug1 bookmarks-section: NOT FOUND")
            print("=== END PROSPER_VERIFY ==="); return
        }
        func permNames(safariOn: Bool?) -> [String] {
            let ui = SettingsUI.fromManifest(section) { key in
                guard key == "source.safari", let on = safariOn else { return nil }
                return on ? "true" : "false"
            }
            return ui.sections.flatMap(\.rows).filter { $0.kind == "permission" }
                .map { $0.name ?? $0.title ?? "?" }
        }
        print("bug1a safari-default perms: \(permNames(safariOn: nil))")   // unset → default true
        print("bug1a safari-on      perms: \(permNames(safariOn: true))")
        print("bug1a safari-off     perms: \(permNames(safariOn: false))")

        // Bug 1b: permission control renders via the "permission" row kind (the
        // PermissionRow with the neon label + Open/Re-check buttons).
        let kinds = SettingsUI.fromManifest(section) { _ in nil }
            .sections.flatMap { $0.rows.map(\.kind) }
        print("bug1b row-kinds: \(kinds.joined(separator: ","))")

        // Bug 3: each ext section produces distinct content. The old bug only
        // swapped the title (stale @State `ui` reused across section switches);
        // `pane.id(selection)` now rebuilds the pane per selection so the body
        // below is what the user actually sees after switching.
        for (rec, sec) in registry.settingsSections(placement: "sidebar") {
            let ui = SettingsUI.fromManifest(sec) { key in registry.prefValue(extensionID: rec.id, key: key) }
            let fp = ui.sections.flatMap { $0.rows.map { "\($0.kind)/\($0.key ?? $0.name ?? "-")" } }
            print("bug3 ext:\(rec.id)|\(sec.id) title=\(sec.title) rows=[\(fp.joined(separator: ","))]")
        }

        // ── Part 1: "Extension Settings" sits immediately after "General". ──
        if let g = order.firstIndex(of: "General") {
            let after = order.indices.contains(g + 1) ? order[g + 1] : "<none>"
            print("part1 after-general: \(after)  (expect: Extension Settings)")
        } else {
            print("part1 after-general: GENERAL MISSING")
        }

        // ── Part 2: translate migrated to a Tier-A section (target/source keys),
        // the old [[contributes.settings]] mechanism removed entirely. ──
        if let (_, t) = registry.settingsSection(
            extensionID: "com.prosper.translate", sectionID: "translate") {
            let keys = t.allControls.compactMap { $0.key }
            print("part2 translate: dynamic=\(t.isDynamic) keys=\(keys)  (expect: false, [target, source])")
        } else {
            print("part2 translate: SECTION NOT FOUND")
        }

        // ── Part 3: QuickLinks / QuickDirs are now dynamic (Tier-B) sidebar
        // sections with neon accents, rendering a `records` control via Lua —
        // 1:1 with the retired native panes. Render is read-only (no store writes). ──
        for (ext, secID) in [("com.prosper.quicklinks", "quicklinks"),
                             ("com.prosper.quickdirs", "quickdirs")] {
            guard let (_, sec) = registry.settingsSection(extensionID: ext, sectionID: secID) else {
                print("part3 \(secID): SECTION NOT FOUND"); continue
            }
            print("part3 \(secID): dynamic=\(sec.isDynamic) accent=\(sec.accent ?? "-") placement=\(sec.placement ?? "sidebar")")
            guard let ui = await registry.renderSettingsAsync(extensionID: ext, sectionID: secID) else {
                print("part3 \(secID): Lua render FAILED"); continue
            }
            let inner = ui.sections.first
            let rec = ui.sections.flatMap(\.rows).first { $0.kind == "records" }
            print("part3 \(secID): inner title=\(inner?.title ?? "-") accent=\(inner?.accent ?? "-")")
            if let r = rec {
                print("part3 \(secID): records id=\(r.id) addLabel=\(r.addLabel ?? "-") revealLabel=\(r.revealLabel ?? "-") fieldsTemplate=\(r.fields?.compactMap(\.id) ?? []) recordCount=\(r.records?.count ?? 0)")
            } else {
                print("part3 \(secID): NO records control in rendered tree")
            }
        }

        // ── Part 3b: snippets + bookmarks are now dynamic (Tier-B) too — snippets
        // migrated off the native pane (toggles + records library/collections/ignored
        // + import), bookmarks gained per-browser count badges. Render read-only and
        // dump the row kinds / badges so the host bridge is exercised end-to-end. ──
        for (ext, secID) in [("com.prosper.snippets", "snippets"),
                             ("com.prosper.bookmarks", "bookmarks")] {
            guard registry.settingsSection(extensionID: ext, sectionID: secID) != nil else {
                print("part3b \(secID): SECTION NOT FOUND"); continue
            }
            guard let ui = await registry.renderSettingsAsync(extensionID: ext, sectionID: secID) else {
                print("part3b \(secID): Lua render FAILED"); continue
            }
            for row in ui.sections.flatMap(\.rows) {
                let badge = row.badge.map { " badge=\($0)" } ?? ""
                let recs = row.kind == "records" ? " recordCount=\(row.records?.count ?? 0)" : ""
                print("part3b \(secID): row id=\(row.id) kind=\(row.kind)\(badge)\(recs)")
            }
        }

        // ── Part 5: custom-shortcut targets are de-duplicated (item 2) and the
        // translate fixed shortcut is gated on its extension (item 3). allTargets
        // dedups by commandID; isAvailable(.translate) tracks the ext enabled flag. ──
        let targets = ActivationTarget.allTargets(registry: registry)
        let labels = targets.map(\.label)
        let dupLabels = Dictionary(grouping: labels, by: { $0 }).filter { $0.value.count > 1 }.keys
        print("part5 target-count: \(labels.count)  dup-labels: \(Array(dupLabels))  (expect: [])")
        print("part5 translate-available (ext on): \(ShortcutAction.translate.isAvailable(registry: registry))  (expect: true)")
        try? registry.setEnabled(false, id: "com.prosper.translate")
        print("part5 translate-available (ext off): \(ShortcutAction.translate.isAvailable(registry: registry))  (expect: false)")
        try? registry.setEnabled(true, id: "com.prosper.translate")

        // ── Part 4: disabling an extension dynamically unloads its sidebar
        // section; re-enabling reloads it. settingsSidebarGroups filters on
        // record.enabled, so the rail entry must come and go with the toggle. ──
        func hasTab(_ id: String) -> Bool {
            settingsSidebarGroups(registry: registry).contains { $0.1.contains { $0.id == id } }
        }
        let qlTab = "ext:com.prosper.quicklinks|quicklinks"
        print("part4 quicklinks-tab before: \(hasTab(qlTab))  (expect: true)")
        try? registry.setEnabled(false, id: "com.prosper.quicklinks")
        print("part4 quicklinks-tab disabled: \(hasTab(qlTab))  (expect: false)")
        try? registry.setEnabled(true, id: "com.prosper.quicklinks")
        print("part4 quicklinks-tab re-enabled: \(hasTab(qlTab))  (expect: true)")

        // ── Part 6: drag-snap geometry is pure + screen-relative. SnapZone.at
        // classifies cursor → zone; WindowManager.targetFrame turns zone → frame.
        // Both must be exact since the footprint preview and the final placement
        // share this code (a mismatch = preview lies). AX top-left coords. ──
        let scr = CGRect(x: 0, y: 0, width: 1440, height: 900)      // full frame
        let vis = CGRect(x: 0, y: 25, width: 1440, height: 875)     // minus menu bar
        let m: CGFloat = 8, c: CGFloat = 70
        func zone(_ x: CGFloat, _ y: CGFloat) -> SnapZone? {
            SnapZone.at(cursorAX: CGPoint(x: x, y: y), screenAX: scr, edgeMargin: m, cornerSize: c)
        }
        let z1 = zone(4, 450), z2 = zone(720, 4), z3 = zone(4, 4), z4 = zone(720, 450)
        print("part6 zones: left=\(z1.map { "\($0)" } ?? "nil") top=\(z2.map { "\($0)" } ?? "nil") tl=\(z3.map { "\($0)" } ?? "nil") center=\(z4.map { "\($0)" } ?? "nil")")
        let okZones = z1 == .left && z2 == .top && z3 == .topLeft && z4 == nil
        print("part6 zones-ok: \(okZones)  (expect: true)")
        assert(okZones, "SnapZone.at classification regressed")

        let cur = CGRect(x: 300, y: 300, width: 400, height: 300)   // arbitrary window
        let leftHalf = WindowManager.targetFrame(for: .leftHalf, visible: vis, current: cur)
        let tlQuarter = WindowManager.targetFrame(for: .topLeftQuarter, visible: vis, current: cur)
        let maxF = WindowManager.targetFrame(for: .maximize, visible: vis, current: cur)
        let okFrames = leftHalf == CGRect(x: 0, y: 25, width: 720, height: 875)
            && tlQuarter == CGRect(x: 0, y: 25, width: 720, height: 438)
            && maxF == vis
        print("part6 frames: leftHalf=\(leftHalf) tlQuarter=\(tlQuarter) max=\(maxF)")
        print("part6 frames-ok: \(okFrames)  (expect: true)")
        assert(okFrames, "WindowManager.targetFrame geometry regressed")

        // ── Part 7: Menu Bar Management section contributes with the "Menu Bar"
        // accent and a rebindable reveal shortcut; the section math is unit-tested
        // (MenuBarTests) — here we only assert the declarative section wires up.
        if let (_, sec) = registry.settingsSection(extensionID: "com.prosper.menubar", sectionID: "menubar") {
            print("part7 menubar: accent=\(sec.accent ?? "-")  (expect: Menu Bar)")
            if let ui = await registry.renderSettingsAsync(extensionID: "com.prosper.menubar", sectionID: "menubar") {
                let hasShortcut = ui.sections.flatMap(\.rows).contains {
                    $0.kind == "shortcut" && $0.name == "menuBarToggleHidden"
                }
                print("part7 menubar: reveal-shortcut=\(hasShortcut)  (expect: true)")
            } else {
                print("part7 menubar: Lua render FAILED")
            }
        } else {
            print("part7 menubar: SECTION NOT FOUND")
        }
        // Pure section math sanity (no AX): visible band sits right of the divider.
        let mbOK = MenuBarLogic.section(forItemX: 1400, hiddenDividerX: 1000, alwaysHiddenDividerX: 500) == .visible
            && MenuBarLogic.section(forItemX: 300, hiddenDividerX: 1000, alwaysHiddenDividerX: 500) == .alwaysHidden
            && MenuBarLogic.spacingDefaultsValue(forSpacing: MenuBarSpacing.defaultSpacing) == nil
        print("part7 menubar-math-ok: \(mbOK)  (expect: true)")
        assert(mbOK, "MenuBarLogic section/spacing math regressed")

        print("=== END PROSPER_VERIFY ===")
    }
}
