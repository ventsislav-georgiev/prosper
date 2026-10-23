// Native settings footer for Agent Island (#474), merged below the manifest's
// header like CalendarPane. One setting: which socket dirs the island lists
// while Remote Terminal isolates its sessions. The poller reads the preference
// every tick, so a change shows on the next poll with no reload.

import SwiftUI

struct AgentIslandPane: View {
    @State private var source = AgentIslandSource(raw: Preferences.agentIslandSessions)
    private let isolate = Preferences.isolateRemoteSessions

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
        }
    }
}
