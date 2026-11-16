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
    @State private var terminal = AgentTerminal.resolve(raw: Preferences.agentIslandTerminal,
                                                         installed: AgentTerminal.isInstalled)
    private let terminals = AgentTerminal.available(installed: AgentTerminal.isInstalled)
    /// Preferences.Keys.isolateRemoteSessions (private there); a test pins the match.
    nonisolated static let isolateKey = "isolateRemoteSessions"
    /// Internal so a test can read it through the app's store (#486 B8).
    @AppStorage(AgentIslandPane.isolateKey, store: Preferences.defaults) var isolate = false
    /// #606: the New session command field; saved on commit.
    @State private var command = Preferences.agentIslandNewSessionCommand
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
    static func commitModel(_ text: String) -> String? {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty, let why = AgentIsland.modelRefusal(v) { return why }
        Preferences.agentIslandDefaultModel = v
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

    /// #1338: the Pairs field, what it last read or saved (leaving commits only an edit), and why its last commit
    /// was refused (nil: saved).
    @State private var suffix = Preferences.agentIslandSidekickSuffix
    @State private var suffixSaved = Preferences.agentIslandSidekickSuffix
    @State private var suffixRefusal: String?
    static let suffixRule = "1 to 16 letters, digits, \".\", \"_\" or \"-\""

    /// #1338: the Pairs row's line for the stored suffix: what it does, off, or why a value written from outside is
    /// not used (AgentIsland.groups reads it as off; it is never rewritten).
    static func suffixHint(_ s: String) -> String {
        if s.isEmpty { return "Off: no pairs by name. Type a suffix to turn pairs on" }
        guard AgentIsland.suffixOK(s) else { return "Not used, pairs are off: " + suffixRule }
        return "<name> and <name>\(s) act as a pair: Stop both, Resume both. Empty turns pairs off"
    }

    /// #1338 (spec-pairs S6): the Pairs field's commit: trimmed; empty is stored as "" (pairs off); a value suffixOK
    /// refuses is not saved (the previous one stays) and the reason comes back. A save regroups the island at once.
    static func commitSuffix(_ text: String, _ c: AgentIslandController = .shared) -> String? {
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.isEmpty || AgentIsland.suffixOK(v) else { return "Not saved: " + suffixRule }
        Preferences.agentIslandSidekickSuffix = v
        c.rowDetailsChanged()
        return nil
    }

    private func saveSuffix() {
        suffixRefusal = Self.commitSuffix(suffix)
        if suffixRefusal == nil { suffix = Preferences.agentIslandSidekickSuffix; suffixSaved = suffix }
    }

    /// #751: the Always allow toggle's hook (#754 INFO-R3: a function so a test drives it).
    static func autoAllowToggled(_ on: Bool, _ c: AgentIslandController = .shared) {
        Preferences.agentIslandAutoAllow = on
        c.autoAllowChanged()   // QA #581 F3: off drops every hold now
    }

    /// #606: the field's commit: stored trimmed, empty = unset; the field shows
    /// what was stored.
    static func commit(_ text: String) -> String {
        Preferences.agentIslandNewSessionCommand = text
        return Preferences.agentIslandNewSessionCommand
    }

    /// #529 (QA #333 L-3): saved on every pick, not on change. With the stored
    /// terminal uninstalled the picker shows the fallback, and picking that same
    /// one must stick, or reinstalling the old terminal switches clicks back.
    var terminalPick: Binding<AgentTerminal> {
        Binding(get: { terminal }, set: { terminal = $0; Preferences.agentIslandTerminal = $0.rawValue })
    }

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
                    subtitle: "When it is not open in a terminal window on this Mac") {
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
        NeonSection("New session",
                    footer: "What New session runs in the chosen folder, e.g. claude or headroom wrap claude --chrome.") {
            NeonRow("Command") {
                // Unset: inferred once from the sessions you run (and stored), else claude.
                TextField("claude", text: $command)
                    .font(Neon.font(.body, design: .monospaced)).lineLimit(1).frame(width: sz(260))
                    .onSubmit { command = Self.commit(command) }
            }
            NeonDivider()
            // The subtitle is one slot: the hint, or the refusal in its place (nothing moves).
            NeonRow("Default model", subtitle: modelRefusal ?? Self.modelHint) {
                HStack(spacing: sz(6)) {
                    TextField("Claude Code's default", text: $model)
                        .font(Neon.font(.body, design: .monospaced)).lineLimit(1).frame(width: sz(200))
                        .accessibilityLabel("Default model")
                        .onSubmit { saveModel() }
                    // #1237: a Menu ignores the UI scale (24 high at every scale): its control size follows it, so it is
                    // never taller than the field; fixedSize plus ViewThatFits is the house shape (SettingsWindow's
                    // ActivityControls), the short form only where "Aliases" does not fit. Both run on the main actor.
                    ViewThatFits(in: .horizontal) {
                        aliasesMenu("Aliases")
                        aliasesMenu("...")
                    }
                }
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
            if model != modelSaved { _ = Self.commitModel(model) }
        }
        // #1338: per Mac; not the Sidekicks tab pattern (synced), which only picks that tab.
        NeonSection("Pairs", footer: "Not the Sidekick pattern, which only picks the Sidekicks tab.") {
            NeonRow("Sidekick suffix", subtitle: suffixRefusal ?? Self.suffixHint(suffixSaved)) {
                TextField(AgentIsland.sidekickDefault, text: $suffix)
                    .font(Neon.font(.body, design: .monospaced)).lineLimit(1).frame(width: sz(80))
                    .accessibilityLabel("Sidekick suffix")
                    .onSubmit { saveSuffix() }
            }
        }
        .onDisappear { if suffix != suffixSaved { _ = Self.commitSuffix(suffix) } }
    }
}
