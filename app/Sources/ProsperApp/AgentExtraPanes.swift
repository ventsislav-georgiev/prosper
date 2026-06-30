import SwiftUI
import AppKit

// MARK: - Commands pane (F5)

/// Custom slash-commands: reusable prompt templates invoked as `/<name>` in the chat
/// composer. Stored as markdown in ~/.config/prosper/commands.
struct CommandsPane: View {
    @State private var commands: [SlashCommand] = []
    @State private var editing: SlashCommand?
    @State private var isNew = false

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Commands",
                      subtitle: "Reusable prompt templates invoked as /name in chat")

            NeonSection("Slash Commands",
                        footer: "Type /name in the chat composer to expand a command. Use $ARGUMENTS in the body for the text after the name (otherwise it's appended). Stored in ~/.config/prosper/commands.") {
                if commands.isEmpty {
                    Text("No commands defined.").font(Neon.font(.callout)).foregroundStyle(Neon.textSecondary)
                }
                ForEach(commands) { cmd in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: sz(2)) {
                            Text("/\(cmd.name)").font(Neon.font(.body, design: .monospaced))
                                .foregroundStyle(Neon.textPrimary)
                            Text(cmd.body).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary).lineLimit(1)
                        }
                        Spacer(minLength: sz(12))
                        Button("Edit") { isNew = false; editing = cmd }.buttonStyle(.neon)
                        Button { delete(cmd) } label: { Image(systemName: "trash") }.buttonStyle(.neon)
                    }
                    if cmd.id != commands.last?.id { NeonDivider() }
                }
                NeonDivider()
                HStack {
                    Spacer()
                    Button("Add Command") { isNew = true; editing = SlashCommand(name: "", body: "") }
                        .buttonStyle(.neon)
                }
            }
        }
        .onAppear { reload() }
        .sheet(item: $editing) { cmd in
            CommandEditor(command: cmd, isNew: isNew,
                          onSave: { save($0) },
                          onCancel: { editing = nil })
        }
    }

    private func reload() { commands = CommandStore.all() }
    private func delete(_ c: SlashCommand) { CommandStore.delete(name: c.name); reload() }
    private func save(_ c: SlashCommand) {
        CommandStore.save(name: c.name, body: c.body)
        editing = nil
        reload()
    }
}

private struct CommandEditor: View {
    @State private var name: String
    @State private var body0: String
    let isNew: Bool
    let onSave: (SlashCommand) -> Void
    let onCancel: () -> Void

    init(command: SlashCommand, isNew: Bool,
         onSave: @escaping (SlashCommand) -> Void, onCancel: @escaping () -> Void) {
        _name = State(initialValue: command.name)
        _body0 = State(initialValue: command.body)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !body0.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(14)) {
            Text(isNew ? "Add Command" : "Edit Command")
                .font(Neon.font(.headline)).foregroundStyle(Neon.textPrimary)
            NeonRow("Name", subtitle: "Invoked as /name (lowercased, no spaces)") {
                TextField("review", text: $name).frame(width: sz(220)).disabled(!isNew)
            }
            VStack(alignment: .leading, spacing: sz(4)) {
                Text("Prompt template ($ARGUMENTS for trailing text)")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                TextEditor(text: $body0)
                    .frame(height: sz(160)).font(Neon.font(.body, design: .monospaced))
                    .scrollContentBackground(.hidden).background(Neon.blue.opacity(0.06))
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }.buttonStyle(.neon)
                Button("Save") { onSave(SlashCommand(name: CommandStore.sanitize(name), body: body0)) }
                    .buttonStyle(.neon).disabled(!canSave)
            }
        }
        .padding(sz(20)).frame(width: sz(520)).background(SettingsBackground())
    }
}

// MARK: - Agents pane (F3b personas)

/// Personas: selectable system-prompt presets the agent runs under. Two are built in;
/// custom ones are markdown files in ~/.config/prosper/agents.
struct AgentsPane: View {
    @State private var personas: [AgentPersona] = []
    @State private var editing: AgentPersona?
    @State private var isNew = false
    @State private var defaultPersona = Preferences.agentPersona

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Personas",
                      subtitle: "System-prompt presets the agent can run under")

            NeonSection("Default Persona",
                        footer: "The system-prompt preset new chats start with. Override per session from the chat header.") {
                Picker("Persona", selection: $defaultPersona) {
                    ForEach(personas) { Text($0.title).tag($0.id) }
                }
                .onChange(of: defaultPersona) { _, new in
                    Preferences.agentPersona = new
                    AgentController.shared.applyAgentConfigChange()
                }
            }

            NeonSection("Personas",
                        footer: "Pick the active persona from the chat header. Built-in personas can't be edited. Custom ones live in ~/.config/prosper/agents.") {
                ForEach(personas) { p in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: sz(2)) {
                            HStack(spacing: sz(6)) {
                                Text(p.title).foregroundStyle(Neon.textPrimary)
                                if p.isBuiltIn {
                                    Text("BUILT-IN").font(Neon.font(.caption2)).bold()
                                        .padding(.horizontal, sz(5)).padding(.vertical, sz(1))
                                        .background(Color.secondary.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                            }
                            if !p.prompt.isEmpty {
                                Text(p.prompt).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: sz(12))
                        if !p.isBuiltIn {
                            Button("Edit") { isNew = false; editing = p }.buttonStyle(.neon)
                            Button { delete(p) } label: { Image(systemName: "trash") }.buttonStyle(.neon)
                        }
                    }
                    if p.id != personas.last?.id { NeonDivider() }
                }
                NeonDivider()
                HStack {
                    Spacer()
                    Button("Add Persona") {
                        isNew = true
                        editing = AgentPersona(id: "", title: "", prompt: "", isBuiltIn: false)
                    }.buttonStyle(.neon)
                }
            }
        }
        .onAppear { reload() }
        .sheet(item: $editing) { p in
            PersonaEditor(persona: p, isNew: isNew,
                          onSave: { save($0) },
                          onCancel: { editing = nil })
        }
    }

    private func reload() { personas = AgentPersonaStore.all() }
    private func delete(_ p: AgentPersona) {
        AgentPersonaStore.delete(id: p.id)
        if Preferences.agentPersona == p.id { Preferences.agentPersona = "build" }
        reload()
    }
    private func save(_ p: AgentPersona) {
        AgentPersonaStore.save(id: p.title, title: p.title, prompt: p.prompt)
        editing = nil
        reload()
        AgentController.shared.applyAgentConfigChange()
    }
}

private struct PersonaEditor: View {
    @State private var title: String
    @State private var prompt: String
    let isNew: Bool
    let onSave: (AgentPersona) -> Void
    let onCancel: () -> Void

    init(persona: AgentPersona, isNew: Bool,
         onSave: @escaping (AgentPersona) -> Void, onCancel: @escaping () -> Void) {
        _title = State(initialValue: persona.title)
        _prompt = State(initialValue: persona.prompt)
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !prompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(14)) {
            Text(isNew ? "Add Persona" : "Edit Persona")
                .font(Neon.font(.headline)).foregroundStyle(Neon.textPrimary)
            NeonRow("Title") {
                TextField("Reviewer", text: $title).frame(width: sz(220))
            }
            VStack(alignment: .leading, spacing: sz(4)) {
                Text("System prompt").font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                TextEditor(text: $prompt)
                    .frame(height: sz(200)).font(Neon.font(.body, design: .monospaced))
                    .scrollContentBackground(.hidden).background(Neon.blue.opacity(0.06))
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }.buttonStyle(.neon)
                Button("Save") { onSave(AgentPersona(id: title, title: title, prompt: prompt, isBuiltIn: false)) }
                    .buttonStyle(.neon).disabled(!canSave)
            }
        }
        .padding(sz(20)).frame(width: sz(520)).background(SettingsBackground())
    }
}

// MARK: - Permissions pane (F4)

/// What the agent is allowed to do without asking. Maps to codex's approval policy +
/// sandbox: bypass = no approvals + full filesystem; otherwise a network-gated
/// workspace-write sandbox with an allowlist of extra writable folders.
struct PermissionsPane: View {
    @State private var bypass = Preferences.agentBypassAll
    @State private var policy = Preferences.agentApprovalPolicy
    @State private var network = Preferences.agentNetworkAccess
    @State private var roots = Preferences.agentWritableRoots

    private let policies: [(String, String)] = [
        ("untrusted", "Ask unless trusted"),
        ("on-request", "Ask on request"),
        ("on-failure", "Ask only on failure"),
        ("never", "Never ask"),
    ]

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Permissions",
                      subtitle: "What the coding agent may do without asking")

            NeonSection("Bypass",
                        footer: "Bypass disables ALL approvals and grants full filesystem + network access — the agent runs commands and edits files without confirmation. Use only in trusted directories.") {
                Toggle(isOn: $bypass) {
                    Text("Bypass all approvals (YOLO mode)").foregroundStyle(bypass ? Neon.magenta : Neon.textPrimary)
                }
                .onChange(of: bypass) { _, v in Preferences.agentBypassAll = v; apply() }
            }

            if !bypass {
                NeonSection("Approvals",
                            footer: "When the agent runs a command or edits files, this decides whether it asks first.") {
                    Picker("Approval policy", selection: $policy) {
                        ForEach(policies, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .onChange(of: policy) { _, v in Preferences.agentApprovalPolicy = v; apply() }
                }

                NeonSection("Sandbox") {
                    NeonRow("Allow network access", subtitle: "Let the sandboxed agent reach the internet") {
                        Toggle("", isOn: $network).labelsHidden()
                            .onChange(of: network) { _, v in Preferences.agentNetworkAccess = v; apply() }
                    }
                }

                NeonSection("Writable Folders",
                            footer: "The working directory is always writable. Add extra folders the agent may modify without leaving the sandbox.") {
                    if roots.isEmpty {
                        Text("No extra folders.").font(Neon.font(.callout)).foregroundStyle(Neon.textSecondary)
                    }
                    ForEach(roots, id: \.self) { path in
                        HStack {
                            Text(path).font(Neon.font(.caption, design: .monospaced))
                                .foregroundStyle(Neon.textSecondary).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: sz(12))
                            Button { removeRoot(path) } label: { Image(systemName: "trash") }.buttonStyle(.neon)
                        }
                        if path != roots.last { NeonDivider() }
                    }
                    NeonDivider()
                    HStack {
                        Spacer()
                        Button("Add Folder…") { addRoot() }.buttonStyle(.neon)
                    }
                }
            }
        }
    }

    private func apply() { AgentController.shared.applyAgentConfigChange() }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !roots.contains(url.path) { roots.append(url.path) }
        Preferences.agentWritableRoots = roots
        apply()
    }

    private func removeRoot(_ path: String) {
        roots.removeAll { $0 == path }
        Preferences.agentWritableRoots = roots
        apply()
    }
}
