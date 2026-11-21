import SwiftUI

/// #871 P2a: the ccpool Settings pane, mounted (P2b-1) as the footer of the bundled ccpool
/// extension's Settings page on `CCPoolRuntime.shared.model`. House Neon components and `sz()` throughout; rows that may not fit at a small UI scale
/// fall back to a stacked layout through `ViewThatFits`. No NSAlert: Remove confirms inline.
struct CCPoolPane: View {
    @ObservedObject var model: CCPoolPaneModel

    static let mintHint = "Get one by running claude setup-token in a terminal while signed in to that account."
    /// Errata C6: the label is stored in the clear.
    static let labelHint = "Labels are not secret: other programs on this Mac can see them (in the proxy's status reply, its state file "
        + "and the Keychain item name). Tokens stay in the Keychain."
    static let refreshHint = "Costs one tiny request per account, straight to Anthropic."
    static let routeTitle = "Start new Claude sessions through the pool"
    /// P2b-2: what the toggle reaches, as built (spec 3.6; no global routing in v1). #1219 step 2: a single Resume is
    /// routed as a new session; Resume interrupted (one --revive --all per folder) runs with the control environment only.
    static let routeScope = "New sessions started from Prosper that run claude. "
        + "Shells, headroom, other programs and sessions started in a terminal are not routed. Resume interrupted is not routed."
    /// #1499: below dch 1.94.0 a resumed session takes dch's login-shell env, rc files' ANTHROPIC_* included; from it
    /// Resume passes the routing with --env, which wins. Keys and tokens are kept (OQ-132), so only the base URL matters.
    static let shellLimit = " A resumed session is not routed if your shell startup files set ANTHROPIC_BASE_URL."
    static func routeScope(dch: [Int]?) -> String {
        dch.map { DchCommand.isAtLeast($0, AgentIsland.reviveEnvMinimum) } == true ? routeScope : routeScope + shellLimit
    }
    /// #1838: CCPoolCore.route: a new session goes to CCPoolCore.place's pick and stays there; keyless requests use pick.
    static let accountsFooter = "Each new session gets the account with the most room for one more session and keeps it, "
        + "so its prompt cache stays warm; other clients share one account until it runs out. Remove deletes the Keychain item too."

    /// The account row's second line; the live session count only when there is one.
    static func rowSubtitle(_ row: CCPoolPaneModel.Row) -> String {
        ([row.stateText] + (row.sessions > 0 ? [CCPoolPaneModel.count(row.sessions, "session")] : []) + [row.usageText])
            .joined(separator: " · ")
    }

    var body: some View {
        // QA #739 INFO-9: a state change in the store (a limit, a hold, `current`) republishes the
        // model at once (CCPoolPaneModel.republisher); this tick only keeps the clock texts true
        // ("limited until" lapsing, usage ages), which move on the minute.
        TimelineView(.periodic(from: .now, by: 30)) { _ in sections }
            .onAppear { model.checkVault() }
    }

    /// The pane without its clock (the tests read its strings from here).
    var sections: some View {
        VStack(alignment: .leading, spacing: sz(18)) {
            proxySection
            accountsSection
            addSection
            usageSection
            thresholdSection
            CCPoolUsageStatsSection(model: model.usageStats)
            // Shown since the spawn path applies the env (P2b-2 flipped CCPool.routingWired).
            if CCPool.routingWired { sessionsSection }
            terminalSection
            if model.importVisible { importSection }
        }
    }

    // MARK: Proxy

    private var proxySection: some View {
        NeonSection("Proxy") {
            VStack(alignment: .leading, spacing: sz(10)) {
                NeonRow(model.proxyText, subtitle: model.proxySubtitle) {
                    Button(model.proxyButtonTitle) { model.proxyButtonAction() }
                    .buttonStyle(.neon)
                    .accessibilityLabel(model.proxyButtonTitle)
                    .disabled(model.proxyBusy || !model.store.hasAccounts)
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
        NeonSection("Accounts", footer: Self.accountsFooter) {
            VStack(alignment: .leading, spacing: sz(10)) {
                if let problem = model.storeProblem { caption(problem, color: Neon.magenta) }
                if let notice = model.notice { caption(notice, color: Neon.blueBright) }
                let rows = model.rows
                if rows.isEmpty { caption("No accounts yet.") }
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { NeonDivider() }
                    NeonRow(row.label, subtitle: Self.rowSubtitle(row)) {
                        Button(model.selected == row.label ? "Done" : "Edit") { model.select(row.label) }
                            .buttonStyle(.neon).fixedSize()
                            .accessibilityLabel(model.selected == row.label ? "Close the actions for \(row.label)" : "Edit \(row.label)")
                    }
                    if model.selected == row.label { actions(row.label) }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ label: String) -> some View {
        VStack(alignment: .leading, spacing: sz(8)) {
            if model.confirmingRemove == label {
                fitting {
                    caption("Remove \(label) and its Keychain item?")
                    Button("Remove") { model.confirmRemove() }.buttonStyle(.neonDestructive).fixedSize()
                        .disabled(model.busy)
                    Button("Cancel") { model.cancelRemove() }.buttonStyle(.neon).fixedSize()
                }
            }
            fitting {
                TextField("Label", text: $model.renameDraft).textFieldStyle(.roundedBorder).frame(maxWidth: sz(200))
                Button("Rename") { model.rename(label, to: model.renameDraft) }.buttonStyle(.neon).fixedSize()
                    .disabled(model.renameDraft.trimmingCharacters(in: .whitespaces).isEmpty || model.renameDraft == label)
                    .accessibilityLabel("Rename \(label)")
            }
            fitting {
                Button("Remove…") { model.requestRemove(label) }.buttonStyle(.neonDestructive).fixedSize()
                    .disabled(model.busy || model.confirmingRemove == label)
                    .accessibilityLabel("Remove \(label)")
            }
            fitting {
                Button("Hold 1 h") { model.hold(label, hours: 1) }.buttonStyle(.neon).fixedSize()
                    .accessibilityLabel("Hold \(label) for 1 hour")
                Button("Hold 5 h") { model.hold(label, hours: 5) }.buttonStyle(.neon).fixedSize()
                    .accessibilityLabel("Hold \(label) for 5 hours")
                TextField("Hours", text: $model.customHours).textFieldStyle(.roundedBorder).frame(width: sz(64))
                    .accessibilityLabel("Hours to hold \(label)")
                Button("Hold") { model.holdCustom(label) }.buttonStyle(.neon).fixedSize()
                    .accessibilityLabel("Hold \(label) for the hours entered")
                Button("Release") { model.release(label) }.buttonStyle(.neon).fixedSize()
                    .accessibilityLabel("Release \(label)")
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
                        .disabled(model.refreshing || model.importRunning || model.rows.isEmpty)
                }
                if let pool = model.poolText {
                    NeonDivider()
                    caption("Free across all accounts: \(pool)")
                }
            }
        }
    }

    // MARK: Agent Sessions

    private var sessionsSection: some View {
        let reason = model.routeDisabledReason
        return NeonSection("Agent Sessions") {
            VStack(alignment: .leading, spacing: sz(6)) {
                NeonRow(Self.routeTitle, subtitle: reason ?? "Applies to sessions started after the change.") {
                    // Shows off while there is no account; writes only the stored choice (QA #739 F1). Never disabled:
                    // switching off always works, switching on is refused while `reason` holds (O2, QA #751 INFO-3).
                    Toggle("", isOn: Binding(get: { model.routeToggleShown }, set: { model.setRouteAgentSessions($0) }))
                        .labelsHidden()
                        .accessibilityLabel(Self.routeTitle)
                }
                caption(Self.routeScope(dch: AgentIslandController.shared.store?.controlDch?.version))
            }
        }
    }

    /// #1677: the share is a soft preference for new sessions (CCPoolCore.place); it never pauses an account.
    static let thresholdCaption = "Below 100 %, new sessions start on an account under this share when one is; nothing is paused."
    /// #1677 (n21): VoiceOver reads the value, not only the label.
    static func thresholdValue(_ pct: Int) -> String { "\(pct) percent" }

    private var thresholdSection: some View {
        let pct = Int((model.exhaustedThreshold * 100).rounded())
        return NeonSection("Account switching") {
            VStack(alignment: .leading, spacing: sz(6)) {
                NeonRow("Move off an account at") {
                    HStack(spacing: sz(10)) {
                        Text("\(pct) %")
                            .font(Neon.font(13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Neon.textPrimary)
                            .frame(minWidth: sz(44), alignment: .trailing)
                        Stepper("", value: Binding(get: { pct }, set: { model.setExhaustedThreshold(Double($0) / 100) }),
                                in: 50...100, step: 5)
                            .labelsHidden()
                            .accessibilityLabel("Move off an account at")
                            .accessibilityValue(Self.thresholdValue(pct))
                    }
                }
                caption(Self.thresholdCaption)
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
                // #915: selectable, so the path can be copied by hand; no copy button (no pasteboard here).
                caption(model.launcherText).textSelection(.enabled)
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
                    if let why = model.trashBlockedReason {
                        caption(why, color: Neon.magenta)
                        Button("Keep it") { model.finishImport(trash: false) }.buttonStyle(.neon).fixedSize().disabled(model.busy)
                    } else {
                        fitting {
                            Button("Move the old vault to the Trash") { model.finishImport(trash: true) }.buttonStyle(.neon).fixedSize()
                                .disabled(model.busy)
                            Button("Keep it") { model.finishImport(trash: false) }.buttonStyle(.neon).fixedSize().disabled(model.busy)
                        }
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
