import SwiftUI

// #1109 (design #1105 D14, rider R7): Settings › Text Viewer's Edit with and editor command, native (the TOML
// kinds cannot show the detected editor or the dch gate). The only writer of the two Preferences keys.

struct TextViewerPane: View {
    @State private var editWith = Preferences.textViewerEditWith
    @State private var command = Preferences.textViewerEditorCommand
    @State private var detected: String?
    @State private var gate: String?

    static let builtinLabel = "Built-in editor"
    static let terminalLabel = "Terminal editor (dch)"
    static let footer = "The editor command runs as a program with the file's path as its last argument, as your shell profile would run it."

    /// The field's commit: stored trimmed, empty = detected; the field shows what was stored.
    static func commit(_ text: String) -> String {
        Preferences.textViewerEditorCommand = text
        return Preferences.textViewerEditorCommand
    }

    /// What the dch row says for a gate answer.
    nonisolated static func gateText(_ gate: DchCommand.Gate) -> String {
        switch gate {
        case .ok(let path): "Ready (\(path))"
        case .refused: TerminalEditor.needsDch
        }
    }

    var body: some View {
        NeonSection("Editing", footer: Self.footer) {
            NeonRow("Edit with") {
                // Menu, not segmented: segmented controls ignore the UI scale.
                Picker("", selection: $editWith) {
                    Text(Self.builtinLabel).tag("builtin")
                    Text(Self.terminalLabel).tag(Preferences.textViewerEditWithTerminal)
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .accessibilityLabel("Edit with")
                .onChange(of: editWith) { _, v in Preferences.textViewerEditWith = v }
            }
            NeonDivider()
            NeonRow("Editor command", subtitle: detected ?? "Looking in your login shell\u{2026}") {
                ScaledTextField(placeholder: "From your login shell", text: $command, onSubmit: { command = Self.commit(command) })
                    .frame(width: sz(200))
                    .accessibilityLabel("Editor command")
            }
            NeonDivider()
            NeonRow("dch", subtitle: gate ?? "Checking\u{2026}") { EmptyView() }
        }
        .onDisappear { _ = Self.commit(command) }
        // D13: detection runs when this page is shown (or on Edit), never at launch; off main.
        .task {
            let io = TerminalEditorIO.current
            let found = await Task.detached(priority: .utility) {
                (TerminalEditor.detectedText(TerminalEditor.detect(io.probe)), Self.gateText(io.gate()))
            }.value
            detected = found.0
            gate = found.1
        }
    }
}
