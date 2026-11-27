// Native settings footer for Agent Island (#474), merged below the manifest's
// header like CalendarPane. Which socket dirs the island lists while Remote
// Terminal isolates its sessions, and (#500) what a row click does with a
// session that has no local terminal window. The poller reads the preference
// every tick and the controller reads the click ones on every click, so a change
// shows with no reload. The isolation toggle is observed (#477), so the picker
// follows it while Settings stays open. #751: Always allow permission prompts, read by the
// controller on every list change and pushed to it on every toggle.

import SwiftUI

struct AgentIslandPane: View {
    @State private var source = AgentIslandSource(raw: Preferences.agentIslandSessions)
    @State private var click = AgentIslandClick(raw: Preferences.agentIslandClick)
    @State private var terminal = Self.shownTerminal()
    private let terminals = AgentTerminal.available(installed: AgentTerminal.isInstalled)
    /// Preferences.Keys.isolateRemoteSessions (private there); a test pins the match.
    nonisolated static let isolateKey = "isolateRemoteSessions"
    /// Internal so a test can read it through the app's store (#486 B8).
    @AppStorage(AgentIslandPane.isolateKey, store: Preferences.defaults) var isolate = false
    /// #606: the New session command field; saved on commit.
    @State private var command = Preferences.agentIslandNewSessionCommand
    /// #1997: the Codex command field; saved on commit like the Claude one.
    @State private var codexCommand = Preferences.agentIslandCodexCommand
    /// #751: Always allow permission prompts.
    @State private var autoAllow = Preferences.agentIslandAutoAllow
    /// #1228: the Default model field, and why its last commit was refused (nil: saved).
    @State private var model = Preferences.agentIslandDefaultModel
    /// What the field last read or saved: leaving the pane commits only an edit (a pane torn down later never
    /// writes back a value the store has moved on from).
    @State private var modelSaved = Preferences.agentIslandDefaultModel
    /// Opened with a saved value written from outside that fails the rule: why (withModel does not use it).
    @State private var modelRefusal = Self.savedModelRefusal()
    nonisolated static func savedModelRefusal() -> String? {
        let m = Preferences.agentIslandDefaultModel
        return m.isEmpty ? nil : AgentIsland.modelRefusal(m).map { "Not used: " + $0 }
    }
    static let modelAliases = ["opus", "sonnet", "haiku"]
    static let modelHint = "Empty: Claude Code's own default"

    /// #1228: the Default model field's commit: trimmed; empty clears it; anything AgentIsland.modelRefusal refuses
    /// is not saved (the previous value stays) and its reason comes back. nil: saved.
    static func commitModel(_ text: String, _ c: AgentIslandController = .shared) -> String? {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty, let why = AgentIsland.modelRefusal(v) { return why }
        Preferences.agentIslandDefaultModel = v
        c.rowDetailsChanged()   // #1455: rows compare against the new Default at once
        return nil
    }

    private func aliasesMenu(_ title: String) -> some View {
        Menu(title) {
            ForEach(Self.modelAliases, id: \.self) { a in Button(a) { model = a; saveModel() } }
        }
        .controlSize(Self.aliasesControlSize(ThemeRuntime.scale))
        .fixedSize()
        .accessibilityLabel("Model aliases")
    }
    /// The Menu's size class per UI scale (regular is 24 high: right at 1.0 only; small, 20 high, stretched the field at 0.85: ticket 1 of #1237).
    static func aliasesControlSize(_ scale: CGFloat) -> ControlSize { scale < 1 ? .mini : .regular }

    private func saveModel() {
        modelRefusal = Self.commitModel(model)
        if modelRefusal == nil { model = Preferences.agentIslandDefaultModel; modelSaved = model }
    }

    /// #1454: the Default effort menu ("" = Claude Code picks); a saved value outside the levels shows as that.
    @State private var effort = Self.shownEffort()
    nonisolated static func shownEffort() -> String {
        AgentIsland.effortLevels.contains(Preferences.agentIslandDefaultEffort) ? Preferences.agentIslandDefaultEffort : ""
    }
    static let effortDefaultLabel = "Claude Code picks"
    /// #1454: the menu's pick, saved at once ("" clears the key; nothing else outside the levels is saved).
    static func commitEffort(_ v: String, _ c: AgentIslandController = .shared) {
        guard v.isEmpty || AgentIsland.effortLevels.contains(v) else { return }
        Preferences.agentIslandDefaultEffort = v
        c.rowDetailsChanged()   // #1455
    }

    /// #751: the Always allow toggle's hook (#754 INFO-R3: a function so a test drives it).
    static func autoAllowToggled(_ on: Bool, _ c: AgentIslandController = .shared) {
        Preferences.agentIslandAutoAllow = on
        c.autoAllowChanged()   // QA #581 F3: off drops every hold now
    }

    static let newSessionFooter = "What New session's Claude and Codex picks run in the chosen folder, e.g. headroom wrap claude --chrome."

    /// #606: the field's commit: stored trimmed, empty = unset; the field shows
    /// what was stored.
    static func commit(_ text: String) -> String {
        Preferences.agentIslandNewSessionCommand = text
        return Preferences.agentIslandNewSessionCommand
    }

    /// #1997: the Codex field's commit, the same way: stored trimmed, empty = unset (codex).
    static func commitCodex(_ text: String) -> String {
        Preferences.agentIslandCodexCommand = text
        return Preferences.agentIslandCodexCommand
    }

    /// #529 (QA #333 L-3): saved on every pick, not on change. With the stored
    /// terminal uninstalled the picker shows the fallback, and picking that same
    /// one must stick, or reinstalling the old terminal switches clicks back.
    var terminalPick: Binding<AgentTerminal> {
        Binding(get: { terminal }, set: { terminal = $0; Self.pickTerminal($0) })
    }
    /// What the picker shows on open: the stored terminal, else the fallback. Static so a test reads it with no
    /// view installed (QA #577: a State read outside a view is a SwiftUI runtime warning).
    nonisolated static func shownTerminal() -> AgentTerminal {
        AgentTerminal.resolve(raw: Preferences.agentIslandTerminal, installed: AgentTerminal.isInstalled)
    }
    static func pickTerminal(_ t: AgentTerminal) { Preferences.agentIslandTerminal = t.rawValue }

    var body: some View {
        NeonSection("Sessions") {
            NeonRow("Show sessions",
                    subtitle: isolate ? nil : "Applies when Remote Terminal › Isolate sessions is on") {
                // Menu, not segmented: segmented controls ignore the UI scale.
                Picker("", selection: $source) {
                    ForEach(AgentIslandSource.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .disabled(!isolate)
                .onChange(of: source) { _, v in Preferences.agentIslandSessions = v.rawValue }
            }
            NeonDivider()
            NeonRow("Click on a session",
                    subtitle: "Where a click on a session opens it") {
                Picker("", selection: $click) {
                    ForEach(AgentIslandClick.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .onChange(of: click) { _, v in Preferences.agentIslandClick = v.rawValue }
            }
            NeonDivider()
            NeonRow("Terminal") {
                Picker("", selection: terminalPick) {
                    ForEach(terminals, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .disabled(click != .open)
            }
        }
        NeonSection("Permission prompts",
                    footer: "Answers Claude Code's \"Do you want to proceed?\" with Yes, so commands and tool calls run without your review and your iPhone isn't notified. Only sessions that dch 1.30 or later reports as running Claude Code are answered. Never picks \"don't ask again\"; every other question is left to you.") {
            NeonRow("Always allow permission prompts") { Toggle("", isOn: $autoAllow).labelsHidden() }
        }
        .onChange(of: autoAllow) { _, v in Self.autoAllowToggled(v) }
        NeonSection("New session", footer: Self.newSessionFooter) {
            NeonRow("Claude command") {
                // Unset: inferred once from the sessions you run (and stored), else claude.
                // #1250: our own field, sized from its font at this scale (a SwiftUI TextField could keep the last scale's height).
                ScaledTextField(placeholder: "claude", text: $command, onSubmit: { command = Self.commit(command) })
                    .frame(width: sz(260))
                    .accessibilityLabel("Claude command")
            }
            NeonDivider()
            NeonRow("Codex command") {
                ScaledTextField(placeholder: "codex", text: $codexCommand, onSubmit: { codexCommand = Self.commitCodex(codexCommand) })
                    .frame(width: sz(260))
                    .accessibilityLabel("Codex command")
            }
            NeonDivider()
            // The subtitle is one slot: the hint, or the refusal in its place (nothing moves).
            NeonRow("Default model", subtitle: modelRefusal ?? Self.modelHint) {
                HStack(spacing: sz(6)) {
                    ScaledTextField(placeholder: "Claude Code's default", text: $model, onSubmit: { saveModel() })
                        .frame(width: sz(200))
                        .accessibilityLabel("Default model")   // the AX tree's node is SwiftUI's (an NSTextField's own label never reached it)
                    // #1237: a Menu ignores the UI scale (24 high at every scale): its control size follows it, so it is
                    // never taller than the field; fixedSize plus ViewThatFits is the house shape (SettingsWindow's
                    // ActivityControls), the short form only where "Aliases" does not fit. Both run on the main actor.
                    ViewThatFits(in: .horizontal) {
                        aliasesMenu("Aliases")
                        aliasesMenu("...")
                    }
                }
            }
            NeonDivider()
            NeonRow("Default effort") {
                // Menu, not segmented: segmented controls ignore the UI scale.
                Picker("", selection: $effort) {
                    Text(Self.effortDefaultLabel).tag("")
                    ForEach(AgentIsland.effortLevels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityLabel("Default effort")
                .onChange(of: effort) { _, v in Self.commitEffort(v) }
            }
        }
        .onAppear {
            guard command.isEmpty else { return }
            // Typed meanwhile: the user's text stays.
            AgentIslandController.shared.newSessionCommand { _ in
                if command.isEmpty { command = Preferences.agentIslandNewSessionCommand }
            }
        }
        .onDisappear {
            _ = Self.commit(command)
            _ = Self.commitCodex(codexCommand)
            if model != modelSaved { _ = Self.commitModel(model) }
        }
    }
}
