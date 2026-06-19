import AppKit
import SwiftUI

/// Settings pane for managing extensions: list installed (system + user), toggle
/// enable/disable, trust newly installed ones, reset system extensions, uninstall
/// user ones, browse + install from the marketplace, publish your own, and install
/// from a GitHub URL. See docs/ADR-002-extensibility.md (D8/D9) and the trust gate
/// in ExtensionRegistry (installed-but-inert until the user clicks Trust).
struct ExtensionsPane: View {
    @ObservedObject var registry: ExtensionRegistry

    @State private var installURL = ""
    @State private var installing = false
    @State private var errorMessage: String?
    @State private var checkingUpdates = false

    // Per-section collapse state, persisted across opens (user > system > marketplace).
    @AppStorage("ext.collapse.user") private var userCollapsed = true
    @AppStorage("ext.collapse.system") private var systemCollapsed = true
    @AppStorage("ext.collapse.market") private var marketCollapsed = false

    private var userRecords: [ExtensionRecord] { registry.records.filter { !$0.isSystem } }
    private var systemRecords: [ExtensionRecord] { registry.records.filter(\.isSystem) }

    /// Render a divider-separated list of extension rows, or an empty-state caption.
    @ViewBuilder
    private func installedList(_ records: [ExtensionRecord], emptyText: String) -> some View {
        if records.isEmpty {
            Text(emptyText).foregroundStyle(Neon.textSecondary).font(.caption)
        } else {
            ForEach(Array(records.enumerated()), id: \.element.id) { idx, record in
                if idx > 0 { NeonDivider() }
                ExtensionRow(registry: registry, record: record)
            }
        }
    }

    var body: some View {
        NeonScroll {
            VStack(alignment: .leading, spacing: 3) {
                Text("Extensions")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Neon.textPrimary)
                Text("Install and manage Lua extensions")
                    .font(.system(size: 12)).foregroundStyle(Neon.textSecondary)
            }
            .padding(.bottom, 2)

            // User-installed extensions first (what the user added / is publishing),
            // then the bundled system ones. Two sections so the distinction is clear.
            NeonSection("User Extensions", collapsed: $userCollapsed) {
                HStack {
                    if let status = registry.updateStatus {
                        Text(status).font(.caption).foregroundStyle(Neon.textSecondary)
                    }
                    Spacer()
                    if checkingUpdates {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check for Updates", action: checkUpdates)
                            .buttonStyle(.borderless).font(.caption)
                            .help("Poll GitHub- and marketplace-installed extensions for newer versions and update them")
                    }
                }
                NeonDivider()
                installedList(userRecords, emptyText: "No user extensions installed yet.")
            }

            NeonSection("System Extensions", collapsed: $systemCollapsed) {
                installedList(systemRecords, emptyText: "No system extensions found.")
            }

            MarketBrowseSection(registry: registry, collapsed: $marketCollapsed)

            NeonSection("Install from GitHub",
                        footer: "Point at a repository, or a sub-directory containing extension.toml.") {
                HStack {
                    TextField("https://github.com/owner/repo[/tree/branch/subdir]", text: $installURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(installing)
                        .onSubmit(install)
                    if installing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Install", action: install)
                            .buttonStyle(.neon)
                            .disabled(installURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(Neon.magenta)
                }
            }
        }
    }

    private func checkUpdates() {
        checkingUpdates = true
        Task {
            await registry.checkForUpdates(force: true)
            await MainActor.run { checkingUpdates = false }
        }
    }

    private func install() {
        let url = installURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        errorMessage = nil
        installing = true
        Task {
            do {
                try await registry.installRemote(url: url)
                await MainActor.run {
                    installing = false
                    installURL = ""
                }
            } catch {
                await MainActor.run {
                    installing = false
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                }
            }
        }
    }
}

/// One row in the installed-extensions list. Handles enable/reset/uninstall, the
/// trust gate (untrusted rows are inert and show Trust + a review prompt), and
/// publishing a user extension to the marketplace.
private struct ExtensionRow: View {
    @ObservedObject var registry: ExtensionRegistry
    let record: ExtensionRecord

    @State private var publishing = false
    @State private var published = false
    /// Errors from this row's own actions (trust/publish/uninstall/…) render
    /// inline here, not in the unrelated GitHub-install section below the list.
    @State private var rowError: String?

    private var meta: ExtensionMeta { record.manifest.extension }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: meta.icon ?? "puzzlepiece.extension")
                    .foregroundColor(.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(meta.title).font(.body).bold()
                        if record.isSystem {
                            badge("SYSTEM")
                        } else if !record.trusted {
                            badge("UNTRUSTED")
                        }
                        Text("v\(meta.version)").font(.caption).foregroundColor(.secondary)
                    }
                    Text(meta.description).font(.caption).foregroundColor(.secondary)
                    Text("by \(meta.author)").font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { record.enabled },
                    set: { setEnabled($0) }))
                    .labelsHidden()
                    .disabled(!record.trusted)
                    .help(record.trusted ? "" : "Trust this extension to enable it")
            }

            if !record.isSystem && !record.trusted {
                Text("Not loaded. Review the files, then Trust to load its commands.")
                    .font(.caption).foregroundStyle(Neon.magenta)
            }

            HStack(spacing: 12) {
                Button("Reveal in Finder") {
                    if let dir = registry.directory(id: record.id) {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }.buttonStyle(.borderless).font(.caption)

                if record.isSystem {
                    Button("Reset", action: reset)
                        .buttonStyle(.borderless).font(.caption)
                        .help("Restore this system extension to its bundled version")
                } else {
                    if record.trusted {
                        Button("Untrust", action: untrust)
                            .buttonStyle(.borderless).font(.caption)
                            .help("Stop loading this extension until you trust it again")
                        publishButton
                    } else {
                        Button("Trust", action: trust)
                            .buttonStyle(.borderless).font(.caption).bold()
                    }
                    Button(role: .destructive, action: uninstall) { Text("Uninstall") }
                        .buttonStyle(.borderless).font(.caption)
                }
            }

            if let rowError {
                Text(rowError).font(.caption).foregroundStyle(Neon.magenta)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var publishButton: some View {
        if publishing {
            ProgressView().controlSize(.small)
        } else {
            Button(published ? "Published" : "Publish", action: publish)
                .buttonStyle(.borderless).font(.caption)
                .disabled(published)
                .help("Publish this extension to the marketplace (or push a new version)")
        }
    }

    /// Derive the marketplace category + look-and-feel preview from an extension's
    /// contributed themes. No themes → ("extension", nil). Reads each theme.json's
    /// flat color map straight off disk (declarative data, no VM).
    static func themePreview(themes: [ThemeContribution], dir: URL)
        -> (kind: String, preview: MarketClient.ThemePreview?) {
        guard !themes.isEmpty else { return ("extension", nil) }
        var swatches: [MarketClient.ThemePreview.Swatch] = []
        for t in themes {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(t.path)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let colors = obj["colors"] as? [String: String] else { continue }
            swatches.append(.init(
                title: t.title,
                appearance: t.appearance ?? (obj["appearance"] as? String) ?? "dark",
                colors: colors))
        }
        return ("theme", swatches.isEmpty ? nil : .init(themes: swatches))
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2).bold()
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.2))
            .clipShape(Capsule())
    }

    // MARK: Actions

    private func setEnabled(_ on: Bool) {
        rowError = nil
        do { try registry.setEnabled(on, id: record.id) }
        catch { rowError = String(describing: error) }
    }

    private func trust() {
        rowError = nil
        do { try registry.trust(id: record.id) }
        catch { rowError = String(describing: error) }
    }

    private func untrust() {
        rowError = nil
        do { try registry.untrust(id: record.id) }
        catch { rowError = String(describing: error) }
    }

    private func reset() {
        rowError = nil
        do { try registry.reset(id: record.id) }
        catch { rowError = String(describing: error) }
    }

    private func uninstall() {
        rowError = nil
        do { try registry.uninstall(id: record.id) }
        catch { rowError = String(describing: error) }
    }

    private func publish() {
        guard let dir = registry.directory(id: record.id) else { return }
        rowError = nil
        publishing = true
        let m = meta
        let themes = record.manifest.contributes?.allThemes ?? []
        Task {
            do {
                // packageForPublish spawns tar + gzip + base64 (sync). This Task
                // inherits the View's MainActor, so run the blocking work off-main
                // to keep the UI responsive while a (≤256KB) artifact is packed.
                let blob = try await Task.detached { try RemoteInstaller.packageForPublish(dir) }.value
                let manifest = MarketClient.PublishManifest(
                    id: m.id, name: m.name, title: m.title, description: m.description,
                    version: m.version, author: m.author, icon: m.icon, license: m.license)
                let (kind, preview) = Self.themePreview(themes: themes, dir: dir)
                try await MarketClient.publish(manifest: manifest, blobBase64: blob,
                                               kind: kind, preview: preview)
                await MainActor.run { publishing = false; published = true }
            } catch {
                await MainActor.run {
                    publishing = false
                    rowError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                }
            }
        }
    }
}

/// Marketplace browse + one-click install. Installed packages land UNTRUSTED — the
/// user reviews + trusts them in the Installed list above.
private struct MarketBrowseSection: View {
    @ObservedObject var registry: ExtensionRegistry
    @Binding var collapsed: Bool

    /// All | Themes | Extensions. nil kind = no server filter.
    private enum Category: String, CaseIterable, Identifiable {
        case all = "All", themes = "Themes", extensions = "Extensions"
        var id: String { rawValue }
        var kind: String? {
            switch self {
            case .all: return nil
            case .themes: return "theme"
            case .extensions: return "extension"
            }
        }
    }

    @State private var query = ""
    @State private var category: Category = .all
    @State private var packages: [MarketClient.Package] = []
    @State private var loading = false
    @State private var installingID: String?
    @State private var error: String?

    private var installedIDs: Set<String> { Set(registry.records.map(\.id)) }

    var body: some View {
        NeonSection("Marketplace",
                    footer: "Anyone can publish. Installed extensions stay inert until you review and trust them.",
                    collapsed: $collapsed) {
            Picker("", selection: $category) {
                ForEach(Category.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: category) { _ in load() }

            HStack {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(load)
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Search", action: load).buttonStyle(.borderless).font(.caption)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Neon.magenta)
            }
            ForEach(packages) { pkg in
                NeonDivider()
                row(pkg)
            }
            if packages.isEmpty && !loading {
                Text("No packages.").font(.caption).foregroundStyle(Neon.textSecondary)
            }
        }
        .onAppear { if packages.isEmpty { load() } }
    }

    private func row(_ pkg: MarketClient.Package) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: pkg.icon ?? (pkg.isTheme ? "paintpalette" : "puzzlepiece.extension"))
                    .foregroundColor(.accentColor).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pkg.title).font(.body).bold()
                        if pkg.isTheme {
                            Text("THEME").font(.caption2).bold()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.25))
                                .clipShape(Capsule())
                        }
                        Text("v\(pkg.latestVersion)").font(.caption).foregroundColor(.secondary)
                    }
                    Text(pkg.description).font(.caption).foregroundColor(.secondary)
                    Text("by \(pkg.author) · \(pkg.downloads) downloads")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                if installingID == pkg.id {
                    ProgressView().controlSize(.small)
                } else if installedIDs.contains(pkg.id) {
                    Text("Installed").font(.caption).foregroundStyle(Neon.textSecondary)
                } else {
                    Button("Install") { install(pkg) }.buttonStyle(.neon)
                }
            }
            if let preview = pkg.preview {
                ForEach(Array(preview.themes.enumerated()), id: \.offset) { _, swatch in
                    ThemePreviewStrip(swatch: swatch)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func load() {
        loading = true
        error = nil
        let q = query.trimmingCharacters(in: .whitespaces)
        let kind = category.kind
        Task {
            let result = await MarketClient.browse(query: q, kind: kind)
            await MainActor.run { packages = result.packages; loading = false }
        }
    }

    private func install(_ pkg: MarketClient.Package) {
        installingID = pkg.id
        error = nil
        Task {
            do {
                try await registry.installFromMarket(id: pkg.id, version: pkg.latestVersion)
                await MainActor.run { installingID = nil }
            } catch {
                await MainActor.run {
                    installingID = nil
                    self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                }
            }
        }
    }
}

/// A miniature app mock that demonstrates a theme's look and feel: window
/// background, a sidebar strip, a card with two text lines, and the accent
/// swatches. Unknown tokens fall back to grey so a partial palette still renders.
private struct ThemePreviewStrip: View {
    let swatch: MarketClient.ThemePreview.Swatch

    private func c(_ token: String) -> Color {
        swatch.colors[token].flatMap(Color.init(hex:)) ?? Color.gray.opacity(0.4)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar.
            c("sidebar").frame(width: 16)
            // Content: card with two "text" lines over the window background.
            ZStack {
                LinearGradient(colors: [c("bgTop"), c("bgBottom")],
                               startPoint: .top, endPoint: .bottom)
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(c("card"))
                        .overlay(
                            VStack(alignment: .leading, spacing: 3) {
                                Capsule().fill(c("textPrimary")).frame(width: 46, height: 4)
                                Capsule().fill(c("textSecondary")).frame(width: 30, height: 3)
                            }, alignment: .topLeading)
                        .padding(6)
                    Spacer(minLength: 0)
                    // Accent dots.
                    HStack(spacing: 4) {
                        ForEach(["blue", "indigo", "magenta", "terminal"], id: \.self) { tok in
                            Circle().fill(c(tok)).frame(width: 7, height: 7)
                        }
                    }
                    .padding(.trailing, 8)
                }
            }
        }
        .frame(height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
        .help("\(swatch.title) · \(swatch.appearance ?? "dark")")
    }
}
