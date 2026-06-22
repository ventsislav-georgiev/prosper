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

    /// Global UI size + window opacity. Persisted via Preferences; mirrored into
    /// `ThemeRuntime` so the non-isolated `Neon.font`/`sz`/`op` helpers read them.
    /// Changing either bumps `generation` (same live-rebuild path as a theme swap).
    @Published private(set) var scale: CGFloat = 1.0
    @Published private(set) var opacity: CGFloat = 1.0

    /// Invoked after each apply (and after async assets land) so AppKit can
    /// re-skin non-SwiftUI surfaces. Set by AppDelegate.
    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let cacheDir: URL
    private var reduceTransparencyObserver: NSObjectProtocol?
    private var assetTask: Task<Void, Never>?
    private var lastAssets: [String: String] = [:]
    private let log = Logger(subsystem: "com.prosper", category: "theme")

    private static let activeKey = "prosper.activeThemeID"
    /// Cap on a cached remote asset. ponytail: post-download size check, not a
    /// streaming cap — themes ship from the trusted marketplace and icons are
    /// small. Upgrade to a streaming `URLSession.bytes` cap if untrusted theme
    /// URLs ever become possible.
    nonisolated private static let maxAssetBytes = 32 * 1024 * 1024

    init(defaults: UserDefaults = .standard,
         cacheDir: URL = ThemeStore.defaultCacheDir) {
        self.defaults = defaults
        self.cacheDir = cacheDir
        // Seed the display metrics from the persisted prefs and publish them into
        // ThemeRuntime BEFORE any view renders, so the first frame already honours
        // the user's size/opacity (no flash of default-sized UI on launch).
        let s = CGFloat(Preferences.uiScale)
        let o = CGFloat(Preferences.uiOpacity)
        scale = s
        opacity = o
        ThemeRuntime.scale = s
        ThemeRuntime.opacity = Self.effectiveOpacity(o)
        // Re-evaluate transparency live when the user toggles the system "Reduce
        // transparency" accessibility setting while Prosper is running (otherwise the
        // downgrade only applies on next setOpacity/launch).
        reduceTransparencyObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let effective = Self.effectiveOpacity(self.opacity)
                guard effective != ThemeRuntime.opacity else { return }
                ThemeRuntime.opacity = effective
                self.generation &+= 1
                self.onChange?()
            }
        }
    }

    /// System "Reduce transparency" wins: when it's on, windows render fully opaque
    /// regardless of the user's stored preference (the preference is kept so it
    /// takes effect again if the accessibility setting is turned off). Mirrors
    /// FootprintWindow's downgrade.
    static func effectiveOpacity(_ stored: CGFloat) -> CGFloat {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1.0 : stored
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

    /// User changed the window opacity. Same live-rebuild path as `setScale`.
    func setOpacity(_ value: CGFloat) {
        Preferences.uiOpacity = Double(value)
        let clamped = CGFloat(Preferences.uiOpacity)
        guard clamped != opacity else { return }
        opacity = clamped
        ThemeRuntime.opacity = Self.effectiveOpacity(clamped)
        generation &+= 1
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
        previews = Dictionary(uniqueKeysWithValues: available.map { ($0.id, ThemePalette.load(for: $0)) })
        let wanted = defaults.string(forKey: Self.activeKey) ?? ThemeDescriptor.builtInID
        let target = available.first { $0.id == wanted } ?? available.first ?? .builtIn
        applyDescriptor(target, persist: false)
    }

    // MARK: - Selection

    /// User picked a theme. Persists the choice and applies it.
    func select(id: String) {
        guard let target = available.first(where: { $0.id == id }) else { return }
        applyDescriptor(target, persist: true)
    }

    private func applyDescriptor(_ d: ThemeDescriptor, persist: Bool) {
        let spec: ThemeSpec
        if let path = d.jsonPath {
            spec = (try? ThemeSpec.decode(Data(contentsOf: path))) ?? .empty
        } else {
            spec = .empty   // built-in default = empty spec = pure ThemePalette.default
        }
        apply(spec: spec, descriptor: d, persist: persist)
    }

    /// The synchronous core: swap colors + appearance now, kick assets async.
    private func apply(spec: ThemeSpec, descriptor d: ThemeDescriptor, persist: Bool) {
        let newPalette = ThemePalette.resolve(spec)
        if persist { defaults.set(d.id, forKey: Self.activeKey) }

        // Always assert the app appearance, even on a suppressed no-op apply.
        // Idempotent + cheap. Critical at startup: the very first apply for the
        // default theme is usually a no-op (palette already == default), and if we
        // returned before this, NSApp.appearance would stay nil → AppKit chrome
        // would follow the macOS *system* light/dark setting instead of the theme.
        NSApp?.appearance = NSAppearance(named: spec.appearance.nsAppearanceName)

        // Suppress no-op re-applies. setAvailable() runs on every registry rescan
        // (extension install/enable/file-watch); without this guard each rescan
        // bumps `generation` and rebuilds every window, dropping scroll/focus
        // state. We still re-apply when the *resolved* palette, appearance, or
        // assets change — so editing the active theme.json (hot-reload) still
        // takes effect.
        let unchanged = activeID == d.id
            && appearance == spec.appearance
            && lastAssets == spec.assets
            && newPalette.channelsEqual(ThemeRuntime.palette)
        guard !unchanged else { return }

        ThemeRuntime.palette = newPalette
        appearance = spec.appearance
        activeID = d.id
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
