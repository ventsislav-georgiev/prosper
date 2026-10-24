// Native settings footer for Agent Island (#474), merged below the manifest's
// header like CalendarPane. Which socket dirs the island lists while Remote
// Terminal isolates its sessions, and (#500) what a row click does with a
// session that has no local terminal window. The poller reads the preference
// every tick and the controller reads the click ones on every click, so a change
// shows with no reload. The isolation toggle is observed (#477), so the picker
// follows it while Settings stays open.

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
    }
}
