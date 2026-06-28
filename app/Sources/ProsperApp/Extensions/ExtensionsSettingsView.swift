import AppKit
import SwiftUI

/// Settings pane for managing extensions: list installed (system + user), toggle
/// enable/disable, trust newly installed ones, reset system extensions, uninstall
/// user ones, browse + install from the marketplace, and publish your own.
/// See docs/ADR-002-extensibility.md (D8/D9) and the trust gate
/// in ExtensionRegistry (installed-but-inert until the user clicks Trust).
struct ExtensionsPane: View {
    @ObservedObject var registry: ExtensionRegistry

    @State private var checkingUpdates = false

    // Per-section collapse state, persisted across opens (user > system).
    @AppStorage("ext.collapse.user") private var userCollapsed = true
    @AppStorage("ext.collapse.system") private var systemCollapsed = true

    private var userRecords: [ExtensionRecord] { registry.records.filter { !$0.isSystem } }
    private var systemRecords: [ExtensionRecord] { registry.records.filter(\.isSystem) }

    /// Render a divider-separated list of extension rows, or an empty-state caption.
    @ViewBuilder
    private func installedList(_ records: [ExtensionRecord], emptyText: String) -> some View {
        if records.isEmpty {
            Text(emptyText).foregroundStyle(Neon.textSecondary).font(Neon.font(.caption))
        } else {
            ForEach(Array(records.enumerated()), id: \.element.id) { idx, record in
                if idx > 0 { NeonDivider() }
                ExtensionRow(registry: registry, record: record)
            }
        }
    }

    var body: some View {
        NeonScroll {
            VStack(alignment: .leading, spacing: sz(3)) {
                Text("Extensions")
                    .font(Neon.font(22, weight: .bold, design: .rounded))
                    .foregroundStyle(Neon.textPrimary)
                Text("Install and manage Lua extensions")
                    .font(Neon.font(12)).foregroundStyle(Neon.textSecondary)
            }
            .padding(.bottom, sz(2))

            // Discovery lives in its own window — a marketplace full of packages wants
            // room to search/sort/scroll, which would crowd this settings pane.
            HStack {
                Button {
                    MarketplaceWindow.shared.show()
                } label: {
                    Label("Browse Marketplace", systemImage: "bag")
                }
                .buttonStyle(.neon)
                .help("Open the extension marketplace in its own window")
                Spacer()
            }
            .padding(.bottom, sz(4))

            NeonSection("User Extensions", collapsed: $userCollapsed) {
                HStack {
                    if let status = registry.updateStatus {
                        Text(status).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                    }
                    Spacer()
                    if checkingUpdates {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check for Updates", action: checkUpdates)
                            .rowAction()
                            .help("Poll GitHub- and marketplace-installed extensions for newer versions and update them")
                    }
                }
                NeonDivider()
                installedList(userRecords, emptyText: "No user extensions installed yet.")
            }

            NeonSection("System Extensions", collapsed: $systemCollapsed) {
                installedList(systemRecords, emptyText: "No system extensions found.")
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
}

/// One row in the installed-extensions list. Handles enable/reset/uninstall, the
/// trust gate (untrusted rows are inert and show Trust + a review prompt), and
/// publishing a user extension to the marketplace.
private struct ExtensionRow: View {
    @ObservedObject var registry: ExtensionRegistry
    let record: ExtensionRecord

    @State private var publishing = false
    /// Latest version live on the marketplace for this id (nil = never published /
    /// yanked / not yet fetched). Drives the Publish vs Published-badge UX.
    @State private var publishedVersion: String?
    /// Errors from this row's own actions (trust/publish/uninstall/…) render
    /// inline here, not in the unrelated GitHub-install section below the list.
    @State private var rowError: String?

    private var meta: ExtensionMeta { record.manifest.extension }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            HStack(alignment: .top) {
                Image(systemName: meta.icon ?? "puzzlepiece.extension")
                    .foregroundColor(.accentColor)
                    .frame(width: sz(22))
                VStack(alignment: .leading, spacing: sz(2)) {
                    HStack(spacing: sz(6)) {
                        Text(meta.title).font(Neon.font(.body)).bold()
                        if record.isSystem {
                            badge("SYSTEM")
                        } else if !record.trusted {
                            badge("UNTRUSTED")
                        }
                        if record.privileged && !record.isSystem {
                            badge("PRIVILEGED")
                        }
                        Text("v\(meta.version)").font(Neon.font(.caption)).foregroundColor(.secondary)
                    }
                    Text(meta.description).font(Neon.font(.caption)).foregroundColor(.secondary)
                    Text("by \(meta.author)").font(Neon.font(.caption2)).foregroundColor(.secondary)
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
                    .font(Neon.font(.caption)).foregroundStyle(Neon.magenta)
            }

            if record.privileged && !record.isSystem {
                Text("System access granted: this extension can run shell commands, the coding-agent, and delete files as you. Revoke if unsure.")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.magenta)
            }

            HStack(spacing: sz(12)) {
                Button("Reveal in Finder") {
                    if let dir = registry.directory(id: record.id) {
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }.rowAction()

                if record.isSystem {
                    Button("Reset", action: reset)
                        .rowAction()
                        .help("Restore this system extension to its bundled version")
                } else {
                    if record.trusted {
                        Button("Untrust", action: untrust)
                            .rowAction()
                            .help("Stop loading this extension until you trust it again")
                        if record.privileged {
                            Button("Revoke System Access", action: revokePrivilege)
                                .rowAction()
                                .help("Drop back to the automation tier — no shell, coding-agent, or file deletion")
                        } else {
                            Button("Grant System Access", action: grantPrivilege)
                                .rowAction()
                                .help("Allow host.shell, the coding-agent, and destructive file ops. This extension could run any command as you — only grant configs you have read.")
                        }
                        publishButton
                    } else {
                        Button("Trust", action: trust)
                            .rowAction(prominent: true)
                    }
                    Button(role: .destructive, action: uninstall) { Text("Uninstall") }
                        .rowAction()
                }
            }

            if let rowError {
                Text(rowError).font(Neon.font(.caption)).foregroundStyle(Neon.magenta)
            }
        }
        .padding(.vertical, sz(4))
        .task(id: record.id) { await refreshPublishedVersion() }
    }

    @ViewBuilder private var publishButton: some View {
        if publishing {
            ProgressView().controlSize(.small)
        } else if let pv = publishedVersion {
            if SemanticVersion(meta.version) > SemanticVersion(pv) {
                // Local build is ahead of the marketplace — show what's live AND
                // offer the version bump.
                badge("v\(pv) published")
                    .help("Version \(pv) is live on the marketplace")
                Button("Publish v\(meta.version)", action: publish)
                    .rowAction(prominent: true)
                    .help("Push the newer local version (\(meta.version)) to the marketplace")
            } else {
                // Up to date (local == live, or somehow behind) — nothing to push.
                badge("Published v\(pv)")
                    .help("This version is live on the marketplace")
            }
        } else {
            Button("Publish", action: publish)
                .rowAction()
                .help("Publish this extension to the marketplace")
        }
    }

    private func refreshPublishedVersion() async {
        guard !record.isSystem else { return }
        let v = await MarketClient.publishedVersion(id: record.id)
        await MainActor.run { publishedVersion = v }
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
        Text(text).font(Neon.font(.caption2)).bold()
            .padding(.horizontal, sz(5)).padding(.vertical, sz(1))
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

    private func grantPrivilege() {
        rowError = nil
        do { try registry.grantPrivilege(id: record.id) }
        catch { rowError = String(describing: error) }
    }

    private func revokePrivilege() {
        rowError = nil
        do { try registry.revokePrivilege(id: record.id) }
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
                await MainActor.run { publishing = false; publishedVersion = m.version }
            } catch {
                await MainActor.run {
                    publishing = false
                    rowError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                }
            }
        }
    }
}

/// Borderless text actions read as labels, not buttons (no cursor change, no
/// affordance). This styles them accent-colored with pressed feedback, and the
/// `.rowAction` modifier adds a pointing-hand cursor on hover.
private struct RowActionStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Neon.font(.caption))
            .fontWeight(prominent ? .bold : .regular)
            .foregroundStyle(configuration.role == .destructive ? Neon.magenta : Color.accentColor)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .contentShape(Rectangle())
    }
}

private extension View {
    func rowAction(prominent: Bool = false) -> some View {
        buttonStyle(RowActionStyle(prominent: prominent))
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}
