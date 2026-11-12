import SwiftUI

/// #871 P2a: the ccpool Settings pane. Not mounted anywhere in this phase (P2b adds the Settings
/// entry). House Neon components and `sz()` throughout; rows that may not fit at a small UI scale
/// fall back to a stacked layout through `ViewThatFits`. No NSAlert: Remove confirms inline.
struct CCPoolPane: View {
    @ObservedObject var model: CCPoolPaneModel

    static let mintHint = "Mint it with `claude setup-token` while logged into that account."
    /// Errata C6: the label is stored in the clear.
    static let labelHint = "Labels are visible to local processes (the proxy health answer, the state file, the Keychain item name); the token is not."
    static let refreshHint = "Costs one tiny request per account, straight to Anthropic."
    static let routeTitle = "Start new Claude sessions through the pool"

    var body: some View {
        // Re-render on the minute so "limited until", "held until" and usage ages stay true.
        TimelineView(.periodic(from: .now, by: 30)) { _ in sections }
    }

    /// The pane without its clock (the tests read its strings from here).
    var sections: some View {
        VStack(alignment: .leading, spacing: sz(18)) {
            proxySection
            accountsSection
            addSection
            usageSection
            sessionsSection
            terminalSection
            if model.importVisible { importSection }
        }
    }

    // MARK: Proxy

    private var proxySection: some View {
        NeonSection("Proxy") {
            VStack(alignment: .leading, spacing: sz(10)) {
                NeonRow(model.proxyText, subtitle: "Current account: \(model.currentText)") {
                    Button(model.proxyRunning ? "Restart proxy" : "Start proxy") {
                        if model.proxyRunning { _ = model.restartProxy() } else { _ = model.startProxy() }
                    }
                    .buttonStyle(.neon)
                    .disabled(model.proxyBusy)
                    .fixedSize()
                }
                if let warn = model.unreachableWarning {
                    NeonDivider()
                    caption(warn, color: Neon.magenta)
                }
            }
        }
    }

    // MARK: Accounts

    private var accountsSection: some View {
        NeonSection("Accounts", footer: "Tried in this order. Remove deletes the Keychain item too.") {
            VStack(alignment: .leading, spacing: sz(10)) {
                if let problem = model.storeProblem { caption(problem, color: Neon.magenta) }
                if let notice = model.notice { caption(notice, color: Neon.blueBright) }
                let rows = model.rows
                if rows.isEmpty { caption("No accounts yet.") }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { NeonDivider() }
                    NeonRow(row.label, subtitle: "\(row.stateText) · \(row.usageText)") {
                        Button(model.selected == row.label ? "Done" : "Edit") { model.select(row.label) }
                            .buttonStyle(.neon).fixedSize()
                    }
                    if model.selected == row.label { actions(row.label, index: i, count: rows.count) }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ label: String, index: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: sz(8)) {
            if model.confirmingRemove == label {
                fitting {
                    caption("Remove \(label) and its Keychain item?")
                    Button("Remove") { model.confirmRemove() }.buttonStyle(.neonDestructive).fixedSize()
                    Button("Cancel") { model.cancelRemove() }.buttonStyle(.neon).fixedSize()
                }
            }
            fitting {
                TextField("Label", text: $model.renameDraft).textFieldStyle(.roundedBorder).frame(maxWidth: sz(200))
                Button("Rename") { model.rename(label, to: model.renameDraft) }.buttonStyle(.neon).fixedSize()
                    .disabled(model.renameDraft.trimmingCharacters(in: .whitespaces).isEmpty || model.renameDraft == label)
            }
            fitting {
                Button("Move up") { model.move(label, by: -1) }.buttonStyle(.neon).fixedSize().disabled(index == 0)
                Button("Move down") { model.move(label, by: 1) }.buttonStyle(.neon).fixedSize().disabled(index == count - 1)
                Button("Remove…") { model.requestRemove(label) }.buttonStyle(.neonDestructive).fixedSize()
                    .disabled(model.busy || model.confirmingRemove == label)
            }
            fitting {
                Button("Hold 1 h") { model.hold(label, hours: 1) }.buttonStyle(.neon).fixedSize()
                Button("Hold 5 h") { model.hold(label, hours: 5) }.buttonStyle(.neon).fixedSize()
                TextField("Hours", text: $model.customHours).textFieldStyle(.roundedBorder).frame(width: sz(64))
                Button("Hold") { model.holdCustom(label) }.buttonStyle(.neon).fixedSize()
                Button("Release") { model.release(label) }.buttonStyle(.neon).fixedSize()
            }
        }
        .padding(.leading, sz(12))
    }

    // MARK: Add

    private var addSection: some View {
        NeonSection("Add account") {
            VStack(alignment: .leading, spacing: sz(10)) {
                NeonRow("Label") {
                    TextField("work, personal…", text: $model.labelDraft).textFieldStyle(.roundedBorder).frame(maxWidth: sz(260))
                }
                NeonRow("Token") {
                    SecureField("sk-ant-oat…", text: $model.tokenDraft).textFieldStyle(.roundedBorder).frame(maxWidth: sz(260))
                }
                caption(Self.mintHint)
                caption(Self.labelHint)
                HStack {
                    Spacer(minLength: 0)
                    Button(model.busy ? "Checking…" : "Add") { model.addAccount() }
                        .buttonStyle(.neon).fixedSize()
                        .disabled(model.busy || model.labelDraft.trimmingCharacters(in: .whitespaces).isEmpty || model.tokenDraft.isEmpty)
                }
            }
        }
    }

    // MARK: Usage

    private var usageSection: some View {
        NeonSection("Usage") {
            VStack(alignment: .leading, spacing: sz(10)) {
                NeonRow("Refresh usage", subtitle: Self.refreshHint) {
                    Button(model.refreshing ? "Refreshing…" : "Refresh") { model.refreshUsage() }
                        .buttonStyle(.neon).fixedSize()
                        .disabled(model.refreshing || model.rows.isEmpty)
                }
                if let pool = model.poolText {
                    NeonDivider()
                    caption("Pool headroom: \(pool)")
                }
            }
        }
    }

    // MARK: Agent Sessions

    private var sessionsSection: some View {
        let reason = model.routeDisabledReason
        return NeonSection("Agent Sessions") {
            NeonRow(Self.routeTitle, subtitle: reason ?? "Applies to sessions started after the change.") {
                Toggle("", isOn: $model.routeAgentSessions)
                    .labelsHidden()
                    .disabled(reason != nil)
            }
        }
    }

    // MARK: Terminal use

    private var terminalSection: some View {
        NeonSection("Terminal use") {
            VStack(alignment: .leading, spacing: sz(6)) {
                Text(model.terminalCommand)
                    .font(Neon.font(12, design: .monospaced))
                    .foregroundStyle(Neon.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                caption(model.launcherText)
            }
        }
    }

    // MARK: Import

    private var importSection: some View {
        NeonSection("Import from ccpool") {
            VStack(alignment: .leading, spacing: sz(10)) {
                switch model.importPhase {
                case .idle:
                    NeonRow("Import from ccpool", subtitle: "Copies the Homebrew ccpool accounts into the Keychain.") {
                        Button("Import…") { model.beginImport() }.buttonStyle(.neon).fixedSize().disabled(model.busy)
                    }
                case .review(let plan):
                    caption("Accounts in the old vault: \(plan.labels.joined(separator: ", "))")
                    ForEach(plan.conflicts, id: \.self) { label in
                        fitting {
                            caption("\(label) is already in the pool.")
                            choiceButton(label, .replace, "Replace")
                            choiceButton(label, .skip, "Skip")
                        }
                    }
                    fitting {
                        Button("Import") { model.runImport() }.buttonStyle(.neon).fixedSize().disabled(!model.canRunImport)
                        Button("Cancel") { model.dismissImport() }.buttonStyle(.neon).fixedSize()
                    }
                case .imported(let outcome):
                    ForEach(CCPoolPaneModel.summary(outcome), id: \.self) { caption($0) }
                    fitting {
                        Button("Move the old vault to the Trash") { model.finishImport(trash: true) }.buttonStyle(.neon).fixedSize()
                        Button("Keep it") { model.finishImport(trash: false) }.buttonStyle(.neon).fixedSize()
                    }
                case .finished(let text):
                    NeonRow(text) {
                        Button("Done") { model.dismissImport() }.buttonStyle(.neon).fixedSize()
                    }
                }
            }
        }
    }

    private func choiceButton(_ label: String, _ choice: CCPoolMigration.Choice, _ title: String) -> some View {
        Button(model.importChoices[label] == choice ? "✓ \(title)" : title) { model.importChoices[label] = choice }
            .buttonStyle(.neon).fixedSize()
    }

    // MARK: Helpers

    private func caption(_ text: String, color: Color = Neon.textSecondary) -> some View {
        Text(text).font(Neon.font(.caption)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One row when it fits, stacked when it does not.
    private func fitting<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        let c = content()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: sz(8)) { c }
            VStack(alignment: .leading, spacing: sz(6)) { c }
        }
    }
}
