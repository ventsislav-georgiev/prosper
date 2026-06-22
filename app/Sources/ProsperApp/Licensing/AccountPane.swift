import AppKit
import SwiftUI

/// Settings → Account. Drives the optional supporter flow: passwordless
/// sign-in, supporter status, device management, and a "buy me a coffee" link.
///
/// Nothing here is required to use Prosper — every feature is free and works
/// signed-out. The pane only surfaces account features when the backend is
/// configured.
struct AccountPane: View {
    @ObservedObject private var ent = Entitlements.shared
    @ObservedObject private var client = SupporterClient.shared

    @State private var email = ""
    @State private var confirmingDelete = false

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Account",
                      subtitle: "Optional sign-in for supporter status and settings sync")

            if !ProsperServer.isConfigured {
                NeonSection("Not configured",
                            footer: "Set the Worker URL in ProsperServer.swift (or PROSPER_SERVER_URL) to enable accounts.") {
                    Text("The Prosper backend URL hasn't been set yet.")
                        .foregroundStyle(Neon.textSecondary)
                }
            } else if client.isSignedIn {
                signedIn
            } else {
                signedOut
            }

            supportSection
        }
        .onAppear {
            if client.isSignedIn { Task { await client.loadDevices() } }
        }
    }

    // MARK: - Signed out

    private var signedOut: some View {
        NeonSection("Sign in",
                    footer: "We email you a one-time link. Click it in your browser and Prosper signs in automatically — no password.") {
            HStack {
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBusy)
                Button(signInButtonTitle) { client.login(email: email) }
                    .buttonStyle(.neon)
                    .disabled(email.isEmpty || isBusy)
            }
            if let status = loginStatus {
                NeonDivider()
                Text(status).foregroundStyle(Neon.textSecondary).font(Neon.font(12))
            }
        }
    }

    private var isBusy: Bool {
        switch client.loginState {
        case .sending, .awaitingClick: return true
        default: return false
        }
    }

    private var signInButtonTitle: String {
        switch client.loginState {
        case .sending: return "Sending…"
        case .awaitingClick: return "Check email…"
        default: return "Send link"
        }
    }

    private var loginStatus: String? {
        switch client.loginState {
        case .awaitingClick: return "Link sent — open it in your browser, then come back here."
        case .failed(let msg): return msg
        case .success: return "Signed in."
        default: return nil
        }
    }

    // MARK: - Signed in

    private var signedIn: some View {
        Group {
            NeonSection("Status") {
                NeonRow("Status", subtitle: ent.email ?? "") {
                    Text(planLabel)
                        .font(Neon.font(11, weight: .bold, design: .monospaced))
                        .foregroundStyle(ent.isSupporter ? Neon.terminal : Neon.textSecondary)
                }
                if let expiry = ent.expiry {
                    NeonDivider()
                    NeonRow("Status refreshes by", subtitle: Self.stamp.string(from: expiry)) {
                        Button("Refresh now") { Task { await client.refreshStatus() } }
                            .buttonStyle(.neon)
                    }
                }
            }

            NeonSection("Devices",
                        footer: "Sign-ins are capped per account. Remove a device to free a slot.") {
                if client.devices.isEmpty {
                    Text("No devices loaded.").foregroundStyle(Neon.textSecondary)
                } else {
                    ForEach(Array(client.devices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { NeonDivider() }
                        NeonRow(device.name ?? "Unknown",
                                subtitle: "Last seen \(Self.stamp.string(from: Date(timeIntervalSince1970: TimeInterval(device.last_seen))))") {
                            if device.device_id == SupporterStore.deviceID() {
                                Text("THIS MAC")
                                    .font(Neon.font(10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Neon.blue)
                            } else {
                                Button("Remove") { Task { await client.deactivate(deviceID: device.device_id) } }
                                    .buttonStyle(.neon)
                            }
                        }
                    }
                }
            }

            NeonSection("Account",
                        footer: confirmingDelete ? "This permanently deletes your account and synced settings. Purchase records are retained for accounting." : nil) {
                NeonRow("Sign out", subtitle: "Keeps your data on the server") {
                    Button("Sign out") { client.signOut() }.buttonStyle(.neon)
                }
                NeonDivider()
                NeonRow("Delete account", subtitle: "Remove your data from the server") {
                    Button(confirmingDelete ? "Confirm delete" : "Delete…") {
                        if confirmingDelete { Task { await client.deleteAccount() } }
                        confirmingDelete.toggle()
                    }
                    .buttonStyle(.neon)
                }
            }
        }
    }

    private var planLabel: String {
        switch ent.status {
        case .free: return "FREE"
        case .supporter: return "SUPPORTER ♥"
        }
    }

    // MARK: - Support

    private var supportSection: some View {
        NeonSection("Support Prosper",
                    footer: "Prosper is free, forever — every feature, no paywall. If it's earned a place in your workflow, you can chip in (pay what you want, as often as you like). Supporters get a badge; the most recent 100 are listed in About.") {
            NeonRow("Buy me a coffee", subtitle: ent.isSupporter ? "Thank you for supporting Prosper ♥ — chip in again anytime" : "Pay what you want — anytime") {
                Button(ent.isSupporter ? "Support again ♥" : "Support ♥") {
                    NSWorkspace.shared.open(ProsperServer.checkoutURL)
                }
                .buttonStyle(.neon)
            }
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
