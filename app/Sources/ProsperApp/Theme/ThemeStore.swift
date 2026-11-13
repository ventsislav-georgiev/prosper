import AppKit
import CryptoKit
import SwiftUI
import os

/// Owns the active theme. Single source of truth for which theme is live, the
/// list of selectable themes (built-in default + extension-contributed), and the
/// resolved image assets. SwiftUI redraws by observing `generation`; AppKit
/// surfaces (window backgrounds, menu-bar icon, dock icon, app appearance)
/// re-apply through the `onChange` hook, which `AppDelegate` wires up.
///
/// Switching is instant: applying a theme is a synchronous palette swap + a
/// `generation` bump on the main actor; image assets stream in afterwards and
/// never block the color change.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    /// Bumped on every apply. The `Themed` root wrapper keys its content on this,
    /// so a change tears down + rebuilds the whole view tree → every `Neon.*`
    /// re-reads the new palette. Cheap (one Int) and the switch is a rare,
    /// deliberate user action, so a full rebuild is the right trade for not
    /// threading an @Environment value through ~290 call sites.
    @Published private(set) var generation = 0
    @Published private(set) var activeID = ThemeDescriptor.builtInID
    @Published private(set) var appearance: ThemeAppearance = .dark
    @Published private(set) var available: [ThemeDescriptor] = [.builtIn]
    /// logical asset name → loaded image (e.g. "menuBarIcon", "appIcon").
    @Published private(set) var images: [String: NSImage] = [:]
    /// descriptor id → resolved palette, for swatch previews. Built once per
    /// `setAvailable` so the selector never reads theme.json from a view body.
    @Published private(set) var previews: [String: ThemePalette] = [:]
    /// #862: descriptor id -> its tint dots (base first, then the variants in file
    /// order). Only themes that declare valid variants have an entry.
    @Published private(set) var tints: [String: [ThemeTint]] = [:]
    /// #862: the applied variant key of the active theme; nil = its base palette.
    @Published private(set) var activeTint: String?

    /// Global UI size + window opacity. Persisted via Preferences; mirrored into
    /// `ThemeRuntime` so the non-isolated `Neon.font`/`sz`/`op` helpers read them.
    /// Changing either bumps `generation` (same live-rebuild path as a theme swap).
    @Published private(set) var scale: CGFloat = 1.0
    @Published private(set) var opacity: CGFloat = 1.0
    /// Frosted-glass backgrounds. Persisted via Preferences; mirrored into
    /// `ThemeRuntime.frost`. Forced off while system "Reduce transparency" is on.
    @Published private(set) var frost = false

    /// Selected menu-bar icon (Settings → Appearance → Menu Bar Icon).
    /// Persisted via Preferences. Published (not gated behind `generation` or
    /// `backdropTick`) purely so the picker's own selected-state checkmark
    /// repaints — same proven path as the Transparency picker reading
    /// `theme.opacity` live from inside a `NeonSection`'s `content()` closure
    /// with no id/generation trick involved. See `setMenuBarIconChoice`.
    @Published private(set) var menuBarIconChoice: MenuBarIconChoice = Preferences.menuBarIconChoice

    /// Selected menu-bar icon size (Settings → Appearance → Menu Bar Icon).
    /// Same "published for the picker's own repaint, no id/generation trick"
    /// pattern as `menuBarIconChoice` above.
    @Published private(set) var menuBarIconSize: MenuBarIconSize = Preferences.menuBarIconSize

    /// Bumped on opacity/frost changes. Unlike `generation` (which keys `Themed`'s
    /// `.id()` and tears the whole window subtree down — needed for scale/palette
    /// swaps that touch every view), these only affect the few backdrop views. They
    /// observe this tick so they re-render in place: no teardown, no lost scroll or
    /// focus, no main-thread hitch from rebuilding the entire pane on a slider tap.
    @Published private(set) var backdropTick: Int = 0

    /// Invoked after each apply (and after async assets land) so AppKit can
    /// re-skin non-SwiftUI surfaces. Set by AppDelegate.
    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let cacheDir: URL
    private var reduceTransparencyObserver: NSObjectProtocol?
    private var assetTask: Task<Void, Never>?
    private var lastAssets: [String: String] = [:]
    private let log = Logger(subsystem: "com.prosper", category: "theme")
    /// QA #744 INFO-4: theme id -> the refusal line last logged for it. A rescan re-reads every
    /// theme.json; the same line is not repeated, a different one is logged. An entry goes when
    /// the theme's list decodes or the theme leaves `available`, so it holds at most one line per
    /// theme with a refused list right now.
    private var loggedRefusals: [String: String] = [:]
    /// Test seam: each refusal line as it is logged.
    var onVariantRefusalLogged: ((String) -> Void)?

    private static let activeKey = "prosper.activeThemeID"
    /// #862: theme id -> remembered variant key, beside `activeKey` in the same store.
    /// Per Mac like `activeKey` (neither is in SyncedKeys).
    private static let tintKey = "prosper.themeTints"
    /// Cap on a cached remote asset. ponytail: post-download size check, not a
    /// streaming cap — themes ship from the trusted marketplace and icons are
    /// small. Upgrade to a streaming `URLSession.bytes` cap if untrusted theme
    /// URLs ever become possible.
    nonisolated private static let maxAssetBytes = 32 * 1024 * 1024

    init(defaults: UserDefaults = Preferences.defaults,
         cacheDir: URL = ThemeStore.defaultCacheDir) {
        self.defaults = defaults
        self.cacheDir = cacheDir
        // Seed the display metrics from the persisted prefs and publish them into
        // ThemeRuntime BEFORE any view renders, so the first frame already honours
        // the user's size/opacity (no flash of default-sized UI on launch).
        let s = CGFloat(Preferences.uiScale)
        let o = CGFloat(Preferences.uiOpacity)
        let f = Preferences.uiFrost
        scale = s
        opacity = o
        frost = f
        ThemeRuntime.scale = s
        ThemeRuntime.opacity = Self.effectiveOpacity(o)
        ThemeRuntime.frost = Self.effectiveFrost(f)
        _ = Self.popoverAppearanceObserver
        // Re-evaluate transparency live when the user toggles the system "Reduce
        // transparency" accessibility setting while Prosper is running (otherwise the
        // downgrade only applies on next setOpacity/launch).
        reduceTransparencyObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let op = Self.effectiveOpacity(self.opacity)
                let fr = Self.effectiveFrost(self.frost)
                guard op != ThemeRuntime.opacity || fr != ThemeRuntime.frost else { return }
                ThemeRuntime.opacity = op
                ThemeRuntime.frost = fr
                self.backdropTick &+= 1
                self.onChange?()
            }
        }
    }

    /// #752: every popover wears the active theme's appearance, set as it shows.
    /// `NSApp.appearance` (set in `apply`) reaches app windows, but a popover shown
    /// from a status item takes the MENU BAR's appearance, which follows the system
    /// Light/Dark setting. Under system Light the default (dark) theme's light
    /// `Neon.textPrimary` then sat on aqua controls: white text in white fields,
    /// black segment labels on the dark Neon backdrop (the Sensors fan control).
    /// One observer for every popover — status item, SwiftUI `.popover`, future
    /// ones — instead of an appearance line per controller. queue .main (#753): a
    /// post on the main thread still runs the block before `post` returns, so the
    /// appearance is set before the popover draws, and a post from any other
    /// thread hops to main instead of trapping in `assumeIsolated`.
    private static let popoverAppearanceObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSPopover.willShowNotification, object: nil, queue: .main
    ) { note in
        guard let popover = note.object as? NSPopover else { return }
        MainActor.assumeIsolated {
            shownPopovers.add(popover)
            adoptThemeAppearance(popover)
        }
    }

    /// #753: every popover that has shown, held weakly, so `apply` can re-skin the
    /// ones still on screen (a pinned Calendar popover) on a live theme switch.
    private static let shownPopovers = NSHashTable<NSPopover>.weakObjects()

    /// The appearance a surface showing `Neon.*` colours must render in: the
    /// active theme's, whatever the system or the anchoring view says.
    static func adoptThemeAppearance(_ popover: NSPopover, _ theme: ThemeAppearance = shared.appearance) {
        popover.appearance = NSAppearance(named: theme.nsAppearanceName)
    }

    /// System "Reduce transparency" wins: when it's on, windows render fully opaque
    /// regardless of the user's stored preference (the preference is kept so it
    /// takes effect again if the accessibility setting is turned off). Mirrors
    /// FootprintWindow's downgrade.
    static func effectiveOpacity(_ stored: CGFloat) -> CGFloat {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1.0 : stored
    }

    /// Same precedence for Frost: system "Reduce transparency" forces it off (the
    /// stored preference is kept and re-applies when the accessibility setting is
    /// turned off). The `reduceTransparency` overload is the pure decision (unit-
    /// testable); the convenience reads the live accessibility flag.
    static func effectiveFrost(_ stored: Bool, reduceTransparency: Bool) -> Bool {
        !reduceTransparency && stored
    }
    static func effectiveFrost(_ stored: Bool) -> Bool {
        effectiveFrost(stored, reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }

    // MARK: - Display metrics (size + opacity)

    /// User changed the UI size multiplier. Persists, mirrors into `ThemeRuntime`,
    /// and bumps `generation` so every window rebuilds at the new size. `onChange`
    /// lets AppKit-only surfaces (window content sizes, opacity) re-apply.
    func setScale(_ value: CGFloat) {
        Preferences.uiScale = Double(value)
        let clamped = CGFloat(Preferences.uiScale)
        guard clamped != scale else { return }
        scale = clamped
        ThemeRuntime.scale = clamped
        generation &+= 1
        onChange?()
    }

    /// User changed the window opacity. Only the backdrop views care, so bump the
    /// light `backdropTick` (re-render in place) instead of `generation` (full
    /// teardown). `onChange` re-applies the AppKit window `isOpaque`/background.
    func setOpacity(_ value: CGFloat) {
        Preferences.uiOpacity = Double(value)
        let clamped = CGFloat(Preferences.uiOpacity)
        guard clamped != opacity else { return }
        opacity = clamped
        ThemeRuntime.opacity = Self.effectiveOpacity(clamped)
        backdropTick &+= 1
        onChange?()
    }

    /// User toggled Frost. Backdrop-only, same light path as `setOpacity`; `onChange`
    /// flips the windows' `isOpaque` (the blur needs a non-opaque window).
    func setFrost(_ value: Bool) {
        Preferences.uiFrost = value
        guard value != frost else { return }
        frost = value
        ThemeRuntime.frost = Self.effectiveFrost(value)
        backdropTick &+= 1
        onChange?()
    }

    /// User picked a menu-bar icon. Persists, updates the published value (for
    /// the picker's own repaint), and pokes `onChange` — the SAME hook
    /// `applyThemeToAppKit` already listens on to re-call
    /// `MenuBarController.setMenuBarImage`, which reads
    /// `Preferences.menuBarIconChoice` itself, so this applies to the live
    /// status item immediately with no extra wiring.
    func setMenuBarIconChoice(_ choice: MenuBarIconChoice) {
        Preferences.menuBarIconChoice = choice
        guard choice != menuBarIconChoice else { return }
        menuBarIconChoice = choice
        onChange?()
    }

    /// User picked a menu-bar icon size. Same pattern as
    /// `setMenuBarIconChoice` — `onChange` re-invokes
    /// `MenuBarController.setMenuBarImage`, which reads
    /// `Preferences.menuBarIconSize` itself, so a fresh selection applies to
    /// the live status item immediately.
    func setMenuBarIconSize(_ size: MenuBarIconSize) {
        Preferences.menuBarIconSize = size
        guard size != menuBarIconSize else { return }
        menuBarIconSize = size
        onChange?()
    }

    static var defaultCacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/prosper/theme-cache")
    }

    // MARK: - Discovery

    /// Replace the selectable-theme list with the registry's contributed themes,
    /// Default first, and re-apply the persisted selection (so edits to a theme's
    /// theme.json take effect on rescan). The Default entry is normally supplied by
    /// the bundled `theme-default` system extension; if that extension is missing
    /// or disabled, the Swift `.builtIn` descriptor (backed by `ThemePalette.default`)
    /// is inserted so a Default always exists. If the active theme disappeared (its
    /// extension was removed/disabled), we fall back to Default.
    func setAvailable(_ contributed: [ThemeDescriptor]) {
        var list = contributed
        if !list.contains(where: { $0.id == ThemeDescriptor.builtInID }) {
            list.insert(.builtIn, at: 0)
        } else {
            // Default to the front; keep the rest in discovery order.
            let def = list.filter { $0.id == ThemeDescriptor.builtInID }
            let rest = list.filter { $0.id != ThemeDescriptor.builtInID }
            list = def + rest
        }
        // Dedup by id, first wins. Two installed extensions can declare the same
        // theme id; without this the `previews` dictionary build would trap on a
        // duplicate key and the selector's ForEach(id:) would collide.
        var seen = Set<String>()
        available = list.filter { seen.insert($0.id).inserted }
        // Resolve swatch palettes once here (one disk read per theme), so the
        // selector renders from `previews` instead of decoding theme.json in a
        // view body on every redraw.
        let specs = available.map { ($0.id, ThemeSpec.load(for: $0)) }
        loggedRefusals = loggedRefusals.filter { id, _ in available.contains { $0.id == id } }
        for (id, spec) in specs {
            guard let e = spec.variantError else { loggedRefusals[id] = nil; continue }
            // The description shows theme-file strings through ThemeVariantError.shown.
            let line = "theme \(ThemeVariantError.shown(id, max: 128)): variants refused (\(e.description)); base palette only"
            guard loggedRefusals[id] != line else { continue }
            loggedRefusals[id] = line
            log.error("\(line, privacy: .public)")
            onVariantRefusalLogged?(line)
        }
        tints = Dictionary(uniqueKeysWithValues: specs.compactMap { id, spec in
            ThemeTint.options(spec).map { (id, $0) }
        })
        previews = Dictionary(uniqueKeysWithValues: specs.map { id, spec in
            (id, ThemePalette.resolve(spec, tint: storedTint(for: id)))
        })
        let wanted = defaults.string(forKey: Self.activeKey) ?? ThemeDescriptor.builtInID
        let target = available.first { $0.id == wanted } ?? available.first ?? .builtIn
        applyDescriptor(target, tint: storedTint(for: target.id), persist: false)
    }

    // MARK: - Selection

    /// User picked a theme. Persists the choice and applies it with the tint
    /// remembered for that theme.
    func select(id: String) {
        guard let target = available.first(where: { $0.id == id }) else { return }
        applyDescriptor(target, tint: storedTint(for: id), persist: true)
    }

    /// #862: a tint dot. Selects theme `id` WITH tint `tint` (nil = the base) in one
    /// apply, and remembers the tint for that theme.
    func select(id: String, tint: String?) {
        guard let target = available.first(where: { $0.id == id }) else { return }
        applyDescriptor(target, tint: tint, persist: true)
    }

    /// The tint remembered for theme `id` as stored; `applyDescriptor` validates it.
    private func storedTint(for id: String) -> String? {
        (defaults.dictionary(forKey: Self.tintKey) as? [String: String])?[id]
    }

    /// The tint the theme's row shows as selected: the remembered one when that theme
    /// still declares it, else nil (the base dot).
    func rememberedTint(for id: String) -> String? {
        guard let key = storedTint(for: id), tints[id]?.contains(where: { $0.key == key }) == true else { return nil }
        return key
    }

    private func applyDescriptor(_ d: ThemeDescriptor, tint: String?, persist: Bool) {
        // built-in default = empty spec = pure ThemePalette.default
        let spec = ThemeSpec.load(for: d)
        apply(spec: spec, descriptor: d, tint: spec.variantKey(tint), persist: persist)
    }

    /// The synchronous core: swap colors + appearance now, kick assets async.
    private func apply(spec: ThemeSpec, descriptor d: ThemeDescriptor, tint: String?, persist: Bool) {
        let newPalette = ThemePalette.resolve(spec, tint: tint)
        if persist {
            defaults.set(d.id, forKey: Self.activeKey)
            var map = (defaults.dictionary(forKey: Self.tintKey) as? [String: String]) ?? [:]
            map[d.id] = tint
            defaults.set(map, forKey: Self.tintKey)
        }

        // Always assert the app appearance, even on a suppressed no-op apply.
        // Idempotent + cheap. Critical at startup: the very first apply for the
        // default theme is usually a no-op (palette already == default), and if we
        // returned before this, NSApp.appearance would stay nil → AppKit chrome
        // would follow the macOS *system* light/dark setting instead of the theme.
        // Windows inherit it (none pins its own, #753). Popovers carry an explicit
        // appearance from the willShow observer, so re-skin the shown ones here.
        NSApp?.appearance = NSAppearance(named: spec.appearance.nsAppearanceName)
        for popover in Self.shownPopovers.allObjects { Self.adoptThemeAppearance(popover, spec.appearance) }

        // Suppress no-op re-applies. setAvailable() runs on every registry rescan
        // (extension install/enable/file-watch); without this guard each rescan
        // bumps `generation` and rebuilds every window, dropping scroll/focus
        // state. We still re-apply when the *resolved* palette, appearance, or
        // assets change — so editing the active theme.json (hot-reload) still
        // takes effect.
        let unchanged = activeID == d.id
            && activeTint == tint
            && appearance == spec.appearance
            && lastAssets == spec.assets
            && newPalette.channelsEqual(ThemeRuntime.palette)
        guard !unchanged else { return }

        ThemeRuntime.palette = newPalette
        appearance = spec.appearance
        activeID = d.id
        activeTint = tint
        previews[d.id] = newPalette
        lastAssets = spec.assets

        // Drop the previous theme's images immediately; the new ones stream in.
        // Built-in/asset-less themes leave AppKit to use its bundled icons.
        images = [:]
        generation &+= 1
        onChange?()

        assetTask?.cancel()
        let baseDir = d.jsonPath?.deletingLastPathComponent()
        let cacheDir = self.cacheDir.appending(path: d.id)
        let assets = spec.assets
        let myGen = generation   // guard against a stale task (same id, hot-reload) winning
        assetTask = Task { [weak self] in
            var loaded: [String: NSImage] = [:]
            for (key, ref) in assets {
                if Task.isCancelled { return }
                if let img = await Self.loadAsset(ref: ref, baseDir: baseDir, cacheDir: cacheDir) {
                    loaded[key] = img
                }
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, self.generation == myGen else { return }
                self.images = loaded
                self.onChange?()
            }
        }
    }

    /// Convenience accessor for AppKit (menu bar, dock).
    func image(_ key: String) -> NSImage? { images[key] }

    // MARK: - Asset resolution

    /// Resolve one asset ref to an image. Order: inline `data:`/raw-svg → cached
    /// http(s) (fetch on miss, reuse on hit, refetch if the cache file vanished)
    /// → bundle-relative path inside the extension. nil on any failure so callers
    /// fall back to the app's bundled icon.
    nonisolated static func loadAsset(ref: String, baseDir: URL?, cacheDir: URL) async -> NSImage? {
        if ref.hasPrefix("data:") || ref.hasPrefix("<svg") {
            return inlineImage(ref)
        }
        if ref.hasPrefix("http://") || ref.hasPrefix("https://"), let url = URL(string: ref) {
            return await cachedRemoteImage(url: url, cacheDir: cacheDir)
        }
        // bundle-relative (vectors shipped inside the extension)
        if let baseDir {
            let fileURL = baseDir.appending(path: ref)
            if let data = try? Data(contentsOf: fileURL) { return NSImage(data: data) }
        }
        return nil
    }

    private nonisolated static func inlineImage(_ ref: String) -> NSImage? {
        if ref.hasPrefix("<svg") { return NSImage(data: Data(ref.utf8)) }
        // data:[<mime>][;base64],<payload>
        guard let comma = ref.firstIndex(of: ",") else { return nil }
        let meta = ref[..<comma]
        let payload = String(ref[ref.index(after: comma)...])
        if meta.contains(";base64") {
            guard let data = Data(base64Encoded: payload) else { return nil }
            return NSImage(data: data)
        }
        guard let decoded = payload.removingPercentEncoding else { return nil }
        return NSImage(data: Data(decoded.utf8))
    }

    /// Disk-cached remote fetch. Cache filename = SHA256(url) so a changed URL
    /// re-fetches and a present file is reused; a missing file re-fetches.
    private nonisolated static func cachedRemoteImage(url: URL, cacheDir: URL) async -> NSImage? {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        // Keep the extension cosmetic and filename-safe — never let a crafted URL
        // path inject separators or traversal into the cache filename.
        let rawExt = url.pathExtension.lowercased()
        let ext = (!rawExt.isEmpty && rawExt.count <= 5 && rawExt.allSatisfy(\.isLetter)) ? rawExt : "img"
        let file = cacheDir.appending(path: "\(name).\(ext)")

        if let data = try? Data(contentsOf: file), let img = NSImage(data: data) {
            return img
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= maxAssetBytes,
              let img = NSImage(data: data) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // Atomic: same content-addressed path can be written by a concurrent apply
        // (two themes referencing one icon URL, or a rapid re-select mid-fetch).
        // Atomic rename makes the file appear all-or-nothing — never a truncated
        // read at the `Data(contentsOf:)` above (which would silently drop the icon).
        try? data.write(to: file, options: .atomic)
        return img
    }
}
