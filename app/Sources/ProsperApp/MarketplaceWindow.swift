import AppKit
import SwiftUI

/// Hosts the extension marketplace in its own window — same build-on-open /
/// teardown-on-close discipline as `ChatWindow` (a closed-but-alive hosting view
/// keeps rendering and burns CPU). Browsing a marketplace full of packages wants
/// more room (search, sort, infinite scroll) than the cramped Extensions settings
/// section could give, so it lives here instead of inline.
@MainActor
final class MarketplaceWindow {
    static let shared = MarketplaceWindow()

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show() {
        if let window {
            DockPolicy.present(window)
            return
        }
        // Pull the live registry AppDelegate owns — same instance the Extensions
        // pane uses, so an install here shows up there (and vice-versa) immediately.
        guard let registry = SettingsHooks.shared.extensionRegistry else { return }

        let installer = MarketInstaller(seams: .live(registry))
        let hosting = NSHostingController(rootView: Themed { MarketplaceRootView(registry: registry, installer: installer) })
        hosting.sizingOptions = []   // #1933: the window's size and minimum are set below, not by SwiftUI
        let win = MarketplaceClosableWindow(contentViewController: hosting)
        win.title = "Extension Marketplace"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = false
        win.identifier = NSUserInterfaceItemIdentifier("prosper.marketplaceWindow")
        let s = ThemeRuntime.scale
        win.setContentSize(NSSize(width: 760 * s, height: 720 * s))
        win.contentMinSize = NSSize(width: 520 * s, height: 460 * s)
        SettingsWindow.applyWindowOpacity(win)
        win.isReleasedWhenClosed = false
        win.setFrameAutosaveName("ProsperMarketplaceWindow")
        if !win.setFrameUsingName("ProsperMarketplaceWindow") { win.centerOnScreen() }
        win.clampToContentMinSize()
        window = win

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                installer.closeSheet()   // #919 S4: a kit sheet open at close removes its work folder
                guard let self else { return }
                if let obs = self.closeObserver { NotificationCenter.default.removeObserver(obs) }
                self.closeObserver = nil
                self.window = nil
                DockPolicy.windowDidHide(win)
                DispatchQueue.main.async { win.contentViewController = nil }
            }
        }
        DockPolicy.present(win)
    }
}

private final class MarketplaceClosableWindow: MinimumKeepingWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.keyCode == 13 || event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Browse state machine

/// The marketplace's cursor-paginated browse logic, lifted out of the view so it's
/// testable without SwiftUI/AppKit and without a live network. The view binds its
/// search/category/sort to the `@Published` filters and renders `packages`; this owns
/// the generation guard (stale results discarded), end-of-list detection, load-once
/// dedupe, and transient-error handling. The `browse` seam is injected in tests.
@MainActor
final class MarketplaceBrowseModel: ObservableObject {

    /// All | Themes | Extensions | Agent Kits. nil kind = no server filter.
    enum Category: String, CaseIterable, Identifiable {
        case all = "All", themes = "Themes", extensions = "Extensions", kits = "Agent Kits"
        var id: String { rawValue }
        var kind: String? {
            switch self {
            case .all: return nil
            case .themes: return "theme"
            case .extensions: return "extension"
            case .kits: return "kit"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case updated = "Recently updated", downloads = "Most downloaded"
        var id: String { rawValue }
        var param: String { self == .downloads ? "downloads" : "updated_at" }
    }

    @Published private(set) var packages: [MarketClient.Package] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var query = ""
    @Published var category: Category = .all { didSet { if oldValue != category { reload() } } }
    @Published var sort: Sort = .updated { didSet { if oldValue != sort { reload() } } }

    /// Next-page offset; nil once the server signals the end of the list.
    private var cursor: Int? = 0
    /// Bumped on every reload so a slow in-flight page from a stale filter set
    /// discards its results instead of appending to the new list.
    private var generation = 0
    /// Filter set whose first page is already loaded — dedupes the Enter-press +
    /// debounce double-trigger and re-entrant `reload()` calls for the same filters.
    private var loadedKey: String?
    /// #1717: the complete All list (no next page) for one query+sort. A category switch
    /// over it filters in place with no fetch and no loading flash.
    private var completeAll: (key: String, packages: [MarketClient.Package])?

    private let browse: @Sendable (_ query: String, _ sort: String, _ kind: String?, _ cursor: Int) async -> MarketClient.BrowseResult

    init(browse: @escaping @Sendable (String, String, String?, Int) async -> MarketClient.BrowseResult =
            { q, s, k, c in await MarketClient.browse(query: q, sort: s, kind: k, cursor: c) }) {
        self.browse = browse
    }

    /// Identifies the current filter set; reused for the load-once dedupe.
    var filterKey: String { "\(query)|\(category.rawValue)|\(sort.rawValue)" }
    var hasMore: Bool { cursor != nil }

    /// Load the first page for the current filters. No-op when that exact filter set
    /// is already loaded and didn't error (so Enter+debounce don't double-fetch).
    func reload(force: Bool = false) {
        if !force, loadedKey == filterKey, error == nil { return }
        loadedKey = filterKey
        generation &+= 1
        if !force, let all = completeAll, all.key == "\(query)|\(sort.rawValue)" {
            let kind = category.kind
            packages = kind == nil ? all.packages : all.packages.filter { $0.kind == kind }
            cursor = nil
            error = nil
            loading = false   // a stale in-flight page is dropped by the generation bump
            return
        }
        packages = []
        cursor = 0
        error = nil
        fetch()
    }

    /// Pull the next page when the list bottom is reached. No-op while a page is in
    /// flight or once the end was reached (cursor == nil).
    func loadMore() {
        guard !loading, cursor != nil else { return }
        fetch()
    }

    private func fetch() {
        guard let offset = cursor else { return }
        loading = true
        let gen = generation
        let firstPage = offset == 0
        let q = query.trimmingCharacters(in: .whitespaces)
        let kind = category.kind
        let sortParam = sort.param
        let allKey = kind == nil ? "\(query)|\(sort.rawValue)" : nil
        let browse = self.browse
        Task {
            let result = await browse(q, sortParam, kind, offset)
            await MainActor.run {
                guard gen == self.generation else { return }   // filters changed mid-flight
                self.loading = false
                if result.failed {
                    // Surface on the first page; on a later page keep the cursor so the
                    // next scroll retries instead of permanently ending the list.
                    if firstPage {
                        self.error = "Couldn\u{2019}t reach the marketplace. Check your connection and try again."
                    }
                    return
                }
                self.error = nil
                self.packages.append(contentsOf: result.packages)
                self.cursor = result.cursor
                if result.cursor == nil, let allKey { self.completeAll = (allKey, self.packages) }
            }
        }
    }
}

/// #1717: the search-field spinner sits in a fixed slot, shown or not, so a filter
/// reload never grows the header and pushes the list down.
struct MarketplaceSearchSpinner: View {
    let loading: Bool
    var body: some View {
        ZStack { if loading { ProgressView().controlSize(.small) } }
            .frame(width: sz(16), height: sz(16))
    }
}

// MARK: - Root view

/// Browse + one-click install. Installed packages land UNTRUSTED — the user reviews
/// and trusts them in the Extensions settings list. Results paginate via the server's
/// cursor; the next page loads as the last row scrolls into view (infinite scroll).
/// #919 S4: themes and extensions install in one click; an agent kit's Install opens its pre-install sheet (MarketKitSheet).
struct MarketplaceRootView: View {
    @ObservedObject var registry: ExtensionRegistry
    @ObservedObject var installer: MarketInstaller
    @StateObject private var model = MarketplaceBrowseModel()

    private var installedIDs: Set<String> { Set(registry.records.map(\.id)) }

    var body: some View {
        // Build the installed-id set once per render, not once per row (a computed
        // property re-scans every reference) — keeps a 500-package list cheap.
        let installed = installedIDs
        return VStack(spacing: 0) {
            header
            Divider().overlay(Neon.stroke)
            content(installed: installed)
        }
        .background(MarketplaceBackdrop())
        .foregroundStyle(Neon.textPrimary)
        .onAppear { model.reload() }
        .sheet(item: Binding(get: { installer.kitSheet }, set: { if $0 == nil { installer.closeSheet() } })) { sheet in
            MarketKitSheetView(model: sheet, onInstall: { installer.installFromSheet() }, onCancel: { installer.closeSheet() })
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: sz(8)) {
            HStack(spacing: sz(8)) {
                Image(systemName: "magnifyingglass").foregroundStyle(Neon.blue)
                TextField("Search the marketplace\u{2026}", text: $model.query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Neon.textPrimary)
                    .onSubmit { model.reload(force: true) }
                MarketplaceSearchSpinner(loading: model.loading)
            }
            .padding(.horizontal, sz(12)).padding(.vertical, sz(8))
            .background(RoundedRectangle(cornerRadius: sz(8)).fill(Neon.card)
                .overlay(RoundedRectangle(cornerRadius: sz(8)).stroke(Neon.stroke)))

            HStack(spacing: sz(10)) {
                Picker("", selection: $model.category) {
                    ForEach(MarketplaceBrowseModel.Category.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()

                Spacer(minLength: sz(8))

                Picker("", selection: $model.sort) {
                    ForEach(MarketplaceBrowseModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
        .controlSize(.small)
        .padding(sz(12))
        // Debounced live search: each keystroke restarts a short timer keyed on the
        // current query, so we hit the server once the user pauses, not per character.
        // Clearing the field reloads the full list; the load-once dedupe makes the
        // post-Enter debounce a no-op.
        .task(id: model.query) {
            installer.installError = nil   // drop a stale per-package install error when the query changes
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            model.reload()
        }
    }

    // MARK: List

    private func content(installed: Set<String>) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let err = model.error ?? installer.installError {
                    VStack(alignment: .leading, spacing: sz(2)) {
                        Text(err).font(Neon.font(.caption)).foregroundStyle(Neon.magenta)
                        // A network error is retryable in place; reload() refetches
                        // because error != nil defeats the load-once dedupe.
                        if model.error != nil {
                            Text("Tap to retry").font(Neon.font(.caption2)).foregroundStyle(Neon.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(sz(16))
                    .contentShape(Rectangle())
                    .onTapGesture { if model.error != nil { model.reload(force: true) } }
                }
                // No `enumerated()`: that allocates an index array over the whole list
                // every render. first/last id are O(1) and give the divider + the
                // infinite-scroll trigger without the alloc.
                let firstID = model.packages.first?.id
                let lastID = model.packages.last?.id
                ForEach(model.packages) { pkg in
                    if pkg.id != firstID { NeonDivider() }
                    row(pkg, installed: installed)
                        .onAppear { if pkg.id == lastID { model.loadMore() } }
                }
                if model.packages.isEmpty && !model.loading && model.error == nil {
                    Text(model.query.isEmpty ? "No packages yet."
                                             : "No packages match \u{201C}\(model.query)\u{201D}.")
                        .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                        .frame(maxWidth: .infinity).padding(.vertical, sz(40))
                }
                if model.loading && !model.packages.isEmpty {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity).padding(.vertical, sz(16))
                }
            }
            .padding(sz(16))
        }
    }

    private func row(_ pkg: MarketClient.Package, installed: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            HStack(alignment: .top) {
                Image(systemName: pkg.icon ?? (pkg.isTheme ? "paintpalette" : pkg.isKit ? "terminal" : "puzzlepiece.extension"))
                    .foregroundColor(.accentColor).frame(width: sz(22))
                MarketplacePackageTexts(pkg: pkg)
                Spacer()
                if installer.installingID == pkg.id {
                    ProgressView().controlSize(.small)
                } else if installed.contains(pkg.id) {
                    Text("Installed").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                } else {
                    Button("Install") { installer.install(pkg) }.buttonStyle(.neon)
                }
            }
            if let preview = pkg.preview {
                ForEach(Array((preview.themes ?? []).enumerated()), id: \.offset) { _, swatch in
                    ThemePreviewStrip(swatch: swatch)
                }
            }
        }
        .padding(.vertical, sz(8))
    }

    /// The line an install failure shows; #984: a refused manifest reads as ExtensionLoadError's plain sentence.
    nonisolated static func installErrorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// #1251: a package's own texts in its row (title, THEME badge, version, description, author line), each drawn verbatim
/// through ExtensionRowText: a package is outside data written by its publisher. The title line is clipped to its bounds.
/// #919 S4: a kit adds the KIT badge, the Unreviewed line and its first summary lines (each through OutsideText, clipped).
struct MarketplacePackageTexts: View {
    let pkg: MarketClient.Package

    var body: some View {
        VStack(alignment: .leading, spacing: sz(2)) {
            HStack(spacing: sz(6)) {
                Text(verbatim: ExtensionRowText.title(pkg.title, id: pkg.id)).font(Neon.font(.body)).bold()
                    .lineLimit(1).clipped().layoutPriority(-1)
                if pkg.isTheme {
                    Text("THEME").font(Neon.font(.caption2)).bold()
                        .padding(.horizontal, sz(5)).padding(.vertical, sz(1))
                        .background(Color.accentColor.opacity(0.25))
                        .clipShape(Capsule())
                }
                if pkg.isKit { MarketKitBadge() }
                Text(verbatim: ExtensionRowText.version(pkg.latestVersion)).font(Neon.font(.caption)).foregroundColor(.secondary)
            }
            Text(verbatim: ExtensionRowText.description(pkg.description)).font(Neon.font(.caption)).foregroundColor(.secondary)
            Text(verbatim: ExtensionRowText.byLine(pkg.author) + " \u{00B7} \(pkg.downloads) downloads")
                .font(Neon.font(.caption2)).foregroundColor(.secondary)
            if pkg.isKit {
                Text(MarketKitText.unreviewed).font(Neon.font(.caption2)).foregroundStyle(Neon.magenta).lineLimit(1)
                ForEach(Array(MarketKitText.lines(pkg.preview?.kit?.summary ?? [], max: MarketKitText.rowSummaryLines).enumerated()),
                        id: \.offset) { _, line in
                    Text(verbatim: line).font(Neon.font(.caption2)).foregroundColor(.secondary).lineLimit(1).clipped()
                }
            }
        }
    }
}

/// The marketplace window's gradient/frost backdrop — mirrors `ChatBackdrop` so an
/// opacity/frost change re-renders only this, not the whole list.
private struct MarketplaceBackdrop: View {
    @ObservedObject private var theme = ThemeStore.shared
    var body: some View {
        ZStack {
            if ThemeRuntime.frost { VisualEffectBackground() }
            LinearGradient(colors: [Neon.bgTop, Neon.bgBottom],
                           startPoint: .top, endPoint: .bottom)
                .opacity(ThemeRuntime.backdropFillOpacity)
        }
    }
}

/// A miniature app mock that demonstrates a theme's look and feel: window
/// background, a sidebar strip, a card with two text lines, and the accent
/// swatches. Unknown tokens fall back to grey so a partial palette still renders.
struct ThemePreviewStrip: View {
    let swatch: MarketClient.ThemePreview.Swatch

    private func c(_ token: String) -> Color {
        swatch.colors[token].flatMap(Color.init(hex:)) ?? Color.gray.opacity(0.4)
    }

    var body: some View {
        HStack(spacing: 0) {
            c("sidebar").frame(width: sz(16))
            ZStack {
                LinearGradient(colors: [c("bgTop"), c("bgBottom")],
                               startPoint: .top, endPoint: .bottom)
                HStack(spacing: sz(8)) {
                    RoundedRectangle(cornerRadius: sz(4))
                        .fill(c("card"))
                        .overlay(
                            VStack(alignment: .leading, spacing: sz(3)) {
                                Capsule().fill(c("textPrimary")).frame(width: sz(46), height: sz(4))
                                Capsule().fill(c("textSecondary")).frame(width: sz(30), height: sz(3))
                            }, alignment: .topLeading)
                        .padding(sz(6))
                    Spacer(minLength: 0)
                    HStack(spacing: sz(4)) {
                        ForEach(["blue", "indigo", "magenta", "terminal"], id: \.self) { tok in
                            Circle().fill(c(tok)).frame(width: sz(7), height: sz(7))
                        }
                    }
                    .padding(.trailing, sz(8))
                }
            }
        }
        .frame(height: sz(44))
        .clipShape(RoundedRectangle(cornerRadius: sz(6)))
        .overlay(RoundedRectangle(cornerRadius: sz(6)).strokeBorder(.white.opacity(0.08)))
        .help(ExtensionRowText.help("\(swatch.title) \u{00B7} \(swatch.appearance ?? "dark")"))
    }
}
