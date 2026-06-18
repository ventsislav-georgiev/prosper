import AppKit
import SwiftUI

/// Settings pane for managing extensions: list installed (system + user), toggle
/// enable/disable, reset system extensions, uninstall user ones, edit their
/// declared settings (rendered natively from the manifest schema), and install
/// new extensions from a GitHub URL. See docs/ADR-002-extensibility.md (D8/D9).
struct ExtensionsPane: View {
    @ObservedObject var registry: ExtensionRegistry

    @State private var installURL = ""
    @State private var installing = false
    @State private var errorMessage: String?
    @State private var checkingUpdates = false

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

            NeonSection("Installed") {
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
                            .help("Poll GitHub-installed extensions for newer versions and update them")
                    }
                }
                if !registry.records.isEmpty { NeonDivider() }
                if registry.records.isEmpty {
                    Text("No extensions found.").foregroundStyle(Neon.textSecondary).font(.caption)
                } else {
                    ForEach(Array(registry.records.enumerated()), id: \.element.id) { idx, record in
                        if idx > 0 { NeonDivider() }
                        ExtensionRow(
                            registry: registry,
                            record: record,
                            onError: { errorMessage = $0 }
                        )
                    }
                }
            }

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

/// One row in the installed-extensions list. Extension settings live in their own
/// sidebar sections (Tier A/B); this row handles enable/reset/uninstall only.
private struct ExtensionRow: View {
    @ObservedObject var registry: ExtensionRegistry
    let record: ExtensionRecord
    let onError: (String) -> Void

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
                            Text("SYSTEM").font(.caption2).bold()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.2))
                                .clipShape(Capsule())
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
                    Button(role: .destructive, action: uninstall) { Text("Uninstall") }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Actions

    private func setEnabled(_ on: Bool) {
        do { try registry.setEnabled(on, id: record.id) }
        catch { onError(String(describing: error)) }
    }

    private func reset() {
        do { try registry.reset(id: record.id) }
        catch { onError(String(describing: error)) }
    }

    private func uninstall() {
        do { try registry.uninstall(id: record.id) }
        catch { onError(String(describing: error)) }
    }
}
