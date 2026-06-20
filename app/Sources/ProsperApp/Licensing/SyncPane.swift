import SwiftUI

/// Settings → Sync. Status of cross-device settings sync: encryption-key mode,
/// last sync, a manual Sync-now button, what's included, and anything skipped
/// (e.g. an extension/plugin too large or with dependencies).
struct SyncPane: View {
    @ObservedObject private var coordinator = SyncCoordinator.shared
    @ObservedObject private var client = SupporterClient.shared
    @State private var enabled = true

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Sync",
                      subtitle: "Your settings, encrypted end-to-end and synced across your Macs")

            if !client.isSignedIn {
                NeonSection("Sign in required",
                            footer: "Settings sync needs an account. Sign in from the Account tab.") {
                    Text("You're signed out — sync is paused.")
                        .foregroundStyle(Neon.textSecondary)
                }
            }

            NeonSection("Settings Sync", footer: footer) {
                Toggle("Sync my settings across devices", isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in coordinator.enabled = newValue }

                NeonDivider()
                NeonRow("Encryption key", subtitle: keyDetail) {
                    Text(coordinator.keyMode == .icloud ? "iCLOUD" : "LOCAL")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(coordinator.keyMode == .icloud ? Neon.terminal : Neon.textSecondary)
                }

                NeonDivider()
                NeonRow("Last sync",
                        subtitle: coordinator.lastSync.map(Self.stamp.string(from:)) ?? "Never") {
                    Button(coordinator.isSyncing ? "Syncing…" : "Sync now") {
                        Task { await coordinator.syncNow() }
                    }
                    .buttonStyle(.neon)
                    .disabled(coordinator.isSyncing || !client.isSignedIn || !enabled)
                }

                if let error = coordinator.lastError {
                    NeonDivider()
                    Text(error).font(.system(size: 12)).foregroundStyle(Neon.magenta)
                }
            }

            NeonSection("What's synced",
                        footer: "Settings are end-to-end encrypted. Machine-local state (paths, runtime timers, pane layout) never leaves this Mac.") {
                ForEach(Array(Self.syncedCategories.enumerated()), id: \.offset) { idx, cat in
                    if idx > 0 { NeonDivider() }
                    NeonRow(cat.0, subtitle: cat.1) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Neon.terminal)
                    }
                }
            }

            if coordinator.report.includedDefaults > 0 || !coordinator.report.includedFiles.isEmpty {
                NeonSection("Included",
                            footer: "\(coordinator.report.includedDefaults) settings plus the items below.") {
                    if coordinator.report.includedFiles.isEmpty {
                        Text("Preferences only — no extra files.").foregroundStyle(Neon.textSecondary)
                    } else {
                        ForEach(coordinator.report.includedFiles) { item in
                            NeonRow(item.name, subtitle: item.detail) { EmptyView() }
                        }
                    }
                }
            }

            if !coordinator.report.excluded.isEmpty {
                NeonSection("Not synced",
                            footer: "Items skipped because they're too large or have dependencies. Pure, small extensions/plugins (≤ 5 KB compressed) sync automatically.") {
                    ForEach(coordinator.report.excluded) { item in
                        NeonRow(item.name, subtitle: item.detail) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Neon.magenta)
                        }
                    }
                }
            }
        }
        .onAppear {
            enabled = coordinator.enabled
            Task { await coordinator.refreshReport() }
        }
    }

    private var footer: String {
        coordinator.keyMode == .icloud
            ? "Settings are encrypted with a key stored in your iCloud Keychain, so only your devices can read them — the server never sees plaintext."
            : "Encrypting with this Mac's local key. Settings won't sync across devices until iCloud Keychain is available (after the Developer ID / entitlement setup)."
    }

    private var keyDetail: String {
        coordinator.keyMode == .icloud
            ? "Synced via iCloud Keychain — end-to-end encrypted"
            : "Local device key — single-device only for now"
    }

    /// The settings categories that sync, shown so it's clear what carries across
    /// devices — including any extension you install from the marketplace.
    private static let syncedCategories: [(String, String)] = [
        ("App preferences", "Completions, personalization, per-app rules, vision, clipboard, UI, updates, coding agent, LoRA"),
        ("Keyboard shortcuts", "Every per-action and custom shortcut"),
        ("Extension settings", "Every extension's settings — marketplace installs sync automatically"),
        ("Extensions & plugins", "Pure, small ones (≤ 5 KB compressed); see Included / Not synced below"),
        ("Config files", "quicklinks, quickdirs, MCP servers, hooks, agents, commands"),
    ]

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
