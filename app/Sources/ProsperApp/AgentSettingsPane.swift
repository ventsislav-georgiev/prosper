import SwiftUI
import AppKit

/// "Agent" pane: the model to run plus the default persona (system-prompt preset).
/// MCP servers, plugins/hooks, commands, personas and permissions each live in their
/// own sibling pane under the "Coding Agent" sidebar group.
struct AgentPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @State private var temperature = Preferences.agentTemperature
    @State private var topP = Preferences.agentTopP

    /// Warns when the selected model's minimum RAM exceeds this Mac's physical memory
    /// (the model will likely fail to load or thrash to swap).
    private var agentRAMWarning: String? {
        let m = AgentModelRegistry.model(for: model.agentModel)
        let physicalGB = Int(ProcessInfo.processInfo.physicalMemory / 1_000_000_000)
        guard m.minRAMGB > physicalGB else { return nil }
        return "Needs ~\(m.minRAMGB) GB RAM; this Mac has \(physicalGB) GB. "
            + "It may fail to load or run very slowly. Pick a smaller agent model."
    }

    /// Download/Stop/Delete controls for the selected model. Selecting a model auto-
    /// starts its download (see the picker's onChange); these buttons let the user
    /// stop and restart it, or delete a model already on disk.
    @ViewBuilder private var modelDownloadControls: some View {
        let id = model.agentModel
        if downloads.isDownloading(id) {
            VStack(alignment: .leading, spacing: sz(6)) {
                NeonProgressBar(progress: downloads.progress)
                HStack {
                    Text(downloads.status).font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                    Spacer()
                    Button("Stop") { downloads.cancel() }.buttonStyle(.neon)
                }
            }
        } else if ModelFiles.isModelDownloaded(id) {
            HStack {
                Text("Downloaded.").font(Neon.font(.callout)).foregroundStyle(Neon.textSecondary)
                Spacer()
                Button("Delete") { downloads.delete(id) }.buttonStyle(.neonDestructive)
            }
        } else {
            HStack {
                if let err = downloads.errorMessage {
                    Text(err).font(Neon.font(.caption)).foregroundStyle(Neon.magenta).lineLimit(2)
                } else {
                    Text("Not downloaded.").font(Neon.font(.callout)).foregroundStyle(Neon.textSecondary)
                }
                Spacer()
                Button("Download") { downloads.start(id) }.buttonStyle(.neon)
            }
        }
    }

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Model",
                      subtitle: "The model the goal-prompt agent runs")

            NeonSection("Model",
                        footer: "Sizes shown are the on-disk download; expect it to use somewhat more RAM than that once loaded. Loaded only while an agent task runs — the inline model unloads to free RAM, then reloads after. Switching downloads the model if needed; no restart required.") {
                Picker("Agent model", selection: $model.agentModel) {
                    ForEach(AgentModelRegistry.models, id: \.id) {
                        let base = "\($0.label) — \($0.note)"
                        Text(ModelFiles.pickerLabel(for: $0.id, base: base)).tag($0.id)
                    }
                }
                .onChange(of: model.agentModel) { _, new in downloads.start(new) }
                .disabled(downloads.activeModelId != nil)
                NeonDivider()
                modelDownloadControls
                if let warning = agentRAMWarning {
                    NeonDivider()
                    Text(warning).font(Neon.font(.callout)).foregroundStyle(Neon.magenta)
                }
            }

            NeonSection("Sampling",
                        footer: "How the model picks tokens. Lower temperature = more focused and repeatable; higher = more varied. Read per request, so changes apply on the next turn — no restart.") {
                NeonRow("Temperature", subtitle: "0 = deterministic · 0.7 = balanced · higher = more creative") {
                    HStack(spacing: sz(10)) {
                        Slider(value: $temperature, in: 0 ... 2, step: 0.05)
                            .frame(width: sz(160))
                            .onChange(of: temperature) { _, new in Preferences.agentTemperature = new }
                        Text(String(format: "%.2f", temperature))
                            .font(Neon.font(.body, design: .monospaced)).foregroundStyle(Neon.textPrimary)
                            .frame(width: sz(44), alignment: .trailing)
                    }
                }
                NeonDivider()
                NeonRow("Top-p", subtitle: "Nucleus sampling. 1.0 = off; lower trims the unlikely tail") {
                    HStack(spacing: sz(10)) {
                        Slider(value: $topP, in: 0.1 ... 1, step: 0.05)
                            .frame(width: sz(160))
                            .onChange(of: topP) { _, new in Preferences.agentTopP = new }
                        Text(String(format: "%.2f", topP))
                            .font(Neon.font(.body, design: .monospaced)).foregroundStyle(Neon.textPrimary)
                            .frame(width: sz(44), alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - MCP Servers pane

/// MCP tool servers for the agent, plus a one-click list of servers already
/// configured by other tools on this Mac (Claude Code / opencode / codex).
struct MCPServersPane: View {
    @ObservedObject var model: SettingsModel
    @State private var editing: MCPServer?
    @State private var editingOriginalID: String?
    @State private var discovered: [ExternalConfigScanner.FoundServer] = []

    /// Discovered servers not already in our list.
    private var freshDiscovered: [ExternalConfigScanner.FoundServer] {
        let have = Set(model.mcpServers.map(\.id))
        return discovered.filter { !have.contains($0.server.id) }
    }

    var body: some View {
        NeonScroll {
            PaneTitle(title: "MCP Servers",
                      subtitle: "Model Context Protocol tool servers the agent can call")

            NeonSection("Configured",
                        footer: "Stored in ~/.config/prosper/mcp.json (Claude Code schema) — changes apply to the next agent run.") {
                if model.mcpServers.isEmpty {
                    Text("No MCP servers configured.").font(Neon.font(.callout)).foregroundStyle(Neon.textSecondary)
                }
                ForEach(model.mcpServers) { server in
                    MCPServerRow(server: server,
                                 onToggle: { toggle(server) },
                                 onEdit: { presentEdit(server) },
                                 onDelete: { delete(server) })
                    if server.id != model.mcpServers.last?.id { NeonDivider() }
                }
                NeonDivider()
                HStack {
                    Button("Import…") { importFromFile() }.buttonStyle(.neon)
                    Button("Open Config File") { revealConfigFile() }.buttonStyle(.neon)
                    Spacer()
                    Button("Add MCP Server") { presentAdd() }.buttonStyle(.neon)
                }
            }

            if !freshDiscovered.isEmpty {
                NeonSection("Found on this Mac",
                            footer: "MCP servers configured by other coding tools. Add the ones you want.") {
                    ForEach(freshDiscovered) { found in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: sz(2)) {
                                HStack(spacing: sz(6)) {
                                    Text(found.server.id).foregroundStyle(Neon.textPrimary)
                                    Text(found.source).font(Neon.font(.caption2))
                                        .padding(.horizontal, sz(5)).padding(.vertical, sz(1))
                                        .background(Neon.magenta.opacity(0.18))
                                        .clipShape(Capsule()).foregroundStyle(Neon.magenta)
                                }
                                Text(serverSummary(found.server))
                                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary).lineLimit(1)
                            }
                            Spacer(minLength: sz(12))
                            Button("Add") { add(found.server) }.buttonStyle(.neon)
                        }
                        if found.id != freshDiscovered.last?.id { NeonDivider() }
                    }
                }
            }
        }
        .onAppear { discovered = ExternalConfigScanner.servers() }
        .sheet(item: $editing) { server in
            MCPServerEditor(server: server, isNew: editingOriginalID == nil,
                            onSave: { save($0) },
                            onCancel: { editing = nil; editingOriginalID = nil })
        }
    }

    private func serverSummary(_ s: MCPServer) -> String {
        switch s.transport {
        case .stdio: return ([s.command] + s.args).joined(separator: " ")
        case .http:  return s.url
        }
    }

    private func add(_ s: MCPServer) {
        var list = model.mcpServers
        if let i = list.firstIndex(where: { $0.id == s.id }) { list[i] = s } else { list.append(s) }
        model.mcpServers = list
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Import MCP servers from a Claude Code, codex, or opencode config"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let imported = MCPConfigStore.importServers(from: text)
        guard !imported.isEmpty else {
            notify("No MCP servers found", "Couldn't find any MCP server definitions in \(url.lastPathComponent).")
            return
        }
        var list = model.mcpServers
        for s in imported {
            if let i = list.firstIndex(where: { $0.id == s.id }) { list[i] = s } else { list.append(s) }
        }
        model.mcpServers = list
        notify("Imported \(imported.count) MCP server\(imported.count == 1 ? "" : "s")",
               imported.map(\.id).joined(separator: ", "))
    }

    private func revealConfigFile() {
        let url = MCPConfigStore.fileURL
        if !FileManager.default.fileExists(atPath: url.path) { MCPConfigStore.writeFile(model.mcpServers) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func notify(_ title: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.runModal()
    }

    private func presentAdd() { editingOriginalID = nil; editing = MCPServer() }
    private func presentEdit(_ s: MCPServer) { editingOriginalID = s.id; editing = s }

    private func toggle(_ s: MCPServer) {
        guard let i = model.mcpServers.firstIndex(where: { $0.id == s.id }) else { return }
        var list = model.mcpServers
        list[i].enabled.toggle()
        model.mcpServers = list
    }

    private func delete(_ s: MCPServer) {
        model.mcpServers.removeAll { $0.id == s.id }
    }

    private func save(_ s: MCPServer) {
        var list = model.mcpServers
        if let orig = editingOriginalID, let i = list.firstIndex(where: { $0.id == orig }) {
            list[i] = s
        } else {
            list.append(s)
        }
        model.mcpServers = list
        editing = nil
        editingOriginalID = nil
    }
}

// MARK: - Plugins & Hooks pane

/// opencode JS/TS plugins (run via the Bun bridge) plus lifecycle hooks. Both are
/// read by codex at app-server launch, so changes apply to the next agent run.
struct PluginsHooksPane: View {
    @ObservedObject var model: SettingsModel
    @State private var plugins: [String] = []           // plugin filenames in our dir
    @State private var discovered: [ExternalConfigScanner.FoundPlugin] = []
    @State private var installedCommands: Set<String> = []   // command slugs already in the store

    private var freshDiscovered: [ExternalConfigScanner.FoundPlugin] {
        let have = Set(plugins)
        // Hide opencode files we've already copied in; CC plugins (no opencodeFile) always show.
        return discovered.filter { found in
            guard let f = found.opencodeFile else { return true }
            return !have.contains(f.lastPathComponent)
        }
    }

    var body: some View {
        NeonScroll {
            PaneTitle(title: "Plugins & Hooks",
                      subtitle: "opencode plugins and lifecycle hooks for the agent")

            NeonSection("Plugins",
                        footer: "opencode JS/TS plugins in ~/.config/prosper/plugins, bridged into the agent via Bun. Applied on the next agent run.") {
                if plugins.isEmpty {
                    Text("No plugins installed.").font(Neon.font(.callout)).foregroundStyle(Neon.textSecondary)
                }
                ForEach(plugins, id: \.self) { name in
                    HStack {
                        Text(name).font(Neon.font(.body, design: .monospaced)).foregroundStyle(Neon.textPrimary)
                        Spacer(minLength: sz(12))
                        Button { deletePlugin(name) } label: { Image(systemName: "trash") }.buttonStyle(.neon)
                    }
                    if name != plugins.last { NeonDivider() }
                }
                NeonDivider()
                HStack {
                    Button("Add Plugin…") { addPluginFromFile() }.buttonStyle(.neon)
                    Button("Open Plugins Folder") { revealPluginsDir() }.buttonStyle(.neon)
                }
            }

            if !freshDiscovered.isEmpty {
                NeonSection("Found on this Mac",
                            footer: "Plugins configured by other tools. opencode plugins run via the Bun bridge; Claude Code plugins contribute their slash commands.") {
                    ForEach(freshDiscovered) { found in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: sz(2)) {
                                HStack(spacing: sz(6)) {
                                    Text(found.name)
                                        .font(Neon.font(.body, design: .monospaced))
                                        .foregroundStyle(Neon.textPrimary)
                                    Text(found.source).font(Neon.font(.caption2))
                                        .padding(.horizontal, sz(5)).padding(.vertical, sz(1))
                                        .background(Neon.magenta.opacity(0.18))
                                        .clipShape(Capsule()).foregroundStyle(Neon.magenta)
                                }
                                Text(found.detail).font(Neon.font(.caption2)).foregroundStyle(Neon.textSecondary)
                            }
                            Spacer(minLength: sz(12))
                            if isImported(found) {
                                Label("Imported", systemImage: "checkmark")
                                    .font(Neon.font(.caption2)).foregroundStyle(Neon.textSecondary)
                            } else if found.opencodeFile != nil || !found.commandFiles.isEmpty {
                                Button("Add") { addFound(found) }.buttonStyle(.neon)
                            }
                        }
                        if found.id != freshDiscovered.last?.id { NeonDivider() }
                    }
                }
            }

            NeonSection("Hooks",
                        footer: "Shell commands the agent runs on lifecycle events (the Claude Code hooks contract). Stored in ~/.config/prosper/hooks.json. Applies on the next agent run.") {
                if model.hooks.isEmpty {
                    Text("No hooks configured.").font(Neon.font(.callout)).foregroundStyle(Neon.textSecondary)
                }
                ForEach(model.hooks) { hook in
                    HookRuleRow(hook: hook, onToggle: { toggleHook(hook) }, onDelete: { deleteHook(hook) })
                    if hook.id != model.hooks.last?.id { NeonDivider() }
                }
                NeonDivider()
                HStack {
                    Button("Import…") { importHooksFromFile() }.buttonStyle(.neon)
                    Button("Open Config File") { revealHooksConfigFile() }.buttonStyle(.neon)
                }
            }
        }
        .onAppear { reloadPlugins(); discovered = ExternalConfigScanner.plugins(); reloadInstalledCommands() }
    }

    // MARK: Plugins

    private func reloadInstalledCommands() {
        installedCommands = Set(CommandStore.all().map(\.name))
    }

    /// A CC plugin counts as imported once every slash command it carries is in the store.
    /// ponytail: command-presence is the proxy; imported hooks aren't re-checked.
    private func isImported(_ found: ExternalConfigScanner.FoundPlugin) -> Bool {
        guard found.opencodeFile == nil, !found.commandFiles.isEmpty else { return false }
        return found.commandFiles.allSatisfy { url in
            installedCommands.contains(CommandStore.sanitize(url.deletingPathExtension().lastPathComponent))
        }
    }

    private func reloadPlugins() {
        let dir = BunHarness.pluginsDir
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        plugins = names.filter { !$0.hasPrefix(".") && $0.range(of: #"\.(m?[jt]s)$"#, options: .regularExpression) != nil }
            .sorted()
    }

    private func addPluginFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.message = "Pick an opencode plugin (.js / .ts)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addPlugin(url)
    }

    /// Import a discovered plugin: an opencode JS file gets copied into the Bun dir; a
    /// Claude Code plugin contributes its slash commands to our command store.
    private func addFound(_ found: ExternalConfigScanner.FoundPlugin) {
        if let file = found.opencodeFile { addPlugin(file); return }
        for cmd in found.commandFiles {
            guard let parsed = ExternalConfigScanner.commandBody(cmd) else { continue }
            CommandStore.save(name: parsed.name, body: parsed.body)
        }
        // Also pull in any lifecycle hooks the plugin ships, deduped against existing.
        if let root = found.claudeRoot {
            func key(_ h: HookRule) -> String { "\(h.event.rawValue)\u{0}\(h.matcher)\u{0}\(h.command)" }
            let existing = Set(model.hooks.map(key))
            model.hooks += ExternalConfigScanner.claudeHooks(root: root).filter { !existing.contains(key($0)) }
        }
        reloadInstalledCommands()
        discovered = ExternalConfigScanner.plugins()
    }

    private func addPlugin(_ src: URL) {
        let dir = BunHarness.pluginsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: src, to: dest)
        reloadPlugins()
        AgentController.shared.applyAgentConfigChange()
    }

    private func deletePlugin(_ name: String) {
        try? FileManager.default.removeItem(at: BunHarness.pluginsDir.appendingPathComponent(name))
        reloadPlugins()
        AgentController.shared.applyAgentConfigChange()
    }

    private func revealPluginsDir() {
        let dir = BunHarness.pluginsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    // MARK: Hooks

    private func importHooksFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Import hooks from a Claude Code settings.json or codex config"
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let imported = HooksConfigStore.importHooks(from: text)
        guard !imported.isEmpty else {
            notify("No hooks found", "Couldn't find any hook definitions in \(url.lastPathComponent).")
            return
        }
        func key(_ h: HookRule) -> String { "\(h.event.rawValue)\u{0}\(h.matcher)\u{0}\(h.command)" }
        let existing = Set(model.hooks.map(key))
        let fresh = imported.filter { !existing.contains(key($0)) }
        guard !fresh.isEmpty else {
            notify("Already imported", "All \(imported.count) hook\(imported.count == 1 ? "" : "s") from \(url.lastPathComponent) are already present.")
            return
        }
        model.hooks += fresh
        notify("Imported \(fresh.count) hook\(fresh.count == 1 ? "" : "s")",
               fresh.map { "\($0.event.rawValue): \($0.command)" }.joined(separator: "\n"))
    }

    private func revealHooksConfigFile() {
        let url = HooksConfigStore.fileURL
        if !FileManager.default.fileExists(atPath: url.path) { HooksConfigStore.writeFile(model.hooks) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func toggleHook(_ h: HookRule) {
        guard let i = model.hooks.firstIndex(where: { $0.id == h.id }) else { return }
        var list = model.hooks
        list[i].enabled.toggle()
        model.hooks = list
    }

    private func deleteHook(_ h: HookRule) {
        model.hooks.removeAll { $0.id == h.id }
    }

    private func notify(_ title: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.runModal()
    }
}

/// One row in the hooks list: event badge + matcher + command summary, enable + delete.
private struct HookRuleRow: View {
    let hook: HookRule
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: sz(2)) {
                HStack(spacing: sz(6)) {
                    Text(hook.event.rawValue)
                        .font(Neon.font(.caption2))
                        .padding(.horizontal, sz(5)).padding(.vertical, sz(1))
                        .background(Neon.blue.opacity(0.18))
                        .clipShape(Capsule())
                        .foregroundStyle(Neon.blue)
                    if hook.event.usesMatcher && !hook.matcher.isEmpty {
                        Text(hook.matcher)
                            .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                    }
                }
                Text(hook.command.isEmpty ? "(no command)" : hook.command)
                    .font(Neon.font(.caption, design: .monospaced))
                    .foregroundStyle(Neon.textSecondary).lineLimit(1)
            }
            Spacer(minLength: sz(12))
            Toggle("", isOn: Binding(get: { hook.enabled }, set: { _ in onToggle() }))
                .labelsHidden()
            Button { onDelete() } label: { Image(systemName: "trash") }.buttonStyle(.neon)
        }
    }
}

/// One row in the MCP servers list: name + transport badge + summary, with enable
/// toggle, edit, and delete controls.
private struct MCPServerRow: View {
    let server: MCPServer
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var summary: String {
        switch server.transport {
        case .stdio: return ([server.command] + server.args).joined(separator: " ")
        case .http:  return server.url
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: sz(2)) {
                HStack(spacing: sz(6)) {
                    Text(server.id.isEmpty ? "(unnamed)" : server.id)
                        .foregroundStyle(Neon.textPrimary)
                    Text(server.transport.rawValue)
                        .font(Neon.font(.caption2))
                        .padding(.horizontal, sz(5)).padding(.vertical, sz(1))
                        .background(Neon.blue.opacity(0.18))
                        .clipShape(Capsule())
                        .foregroundStyle(Neon.blue)
                }
                Text(summary)
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary).lineLimit(1)
            }
            Spacer(minLength: sz(12))
            Toggle("", isOn: Binding(get: { server.enabled }, set: { _ in onToggle() }))
                .labelsHidden()
            Button("Edit") { onEdit() }.buttonStyle(.neon)
            Button { onDelete() } label: { Image(systemName: "trash") }.buttonStyle(.neon)
        }
    }
}

/// Add/edit sheet for one MCP server. `args` and `env` are edited as plain text
/// (one entry / one `KEY=VALUE` per line) and parsed back into the model on save.
private struct MCPServerEditor: View {
    @State private var draft: MCPServer
    @State private var argsText: String
    @State private var envText: String
    let isNew: Bool
    let onSave: (MCPServer) -> Void
    let onCancel: () -> Void

    init(server: MCPServer, isNew: Bool,
         onSave: @escaping (MCPServer) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: server)
        _argsText = State(initialValue: server.args.joined(separator: "\n"))
        _envText = State(initialValue: server.env.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private func assembled() -> MCPServer {
        var s = draft
        s.args = argsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var env: [String: String] = [:]
        for line in envText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let k = parts[0].trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { continue }
            env[k] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        s.env = env
        return s
    }

    private var canSave: Bool { assembled().isValid }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(14)) {
            Text(isNew ? "Add MCP Server" : "Edit MCP Server")
                .font(Neon.font(.headline)).foregroundStyle(Neon.textPrimary)

            NeonRow("Name", subtitle: "Unique id, used as the config key") {
                TextField("context7", text: $draft.id).frame(width: sz(220))
            }

            Picker("Transport", selection: $draft.transport) {
                Text("stdio (local process)").tag(MCPServer.Transport.stdio)
                Text("HTTP (remote)").tag(MCPServer.Transport.http)
            }.pickerStyle(.segmented)

            if draft.transport == .stdio {
                NeonRow("Command") {
                    TextField("npx", text: $draft.command).frame(width: sz(220))
                }
                VStack(alignment: .leading, spacing: sz(4)) {
                    Text("Arguments (one per line)")
                        .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                    TextEditor(text: $argsText)
                        .frame(height: sz(64)).font(Neon.font(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(Neon.blue.opacity(0.06))
                }
                VStack(alignment: .leading, spacing: sz(4)) {
                    Text("Environment (KEY=VALUE, one per line)")
                        .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary)
                    TextEditor(text: $envText)
                        .frame(height: sz(64)).font(Neon.font(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(Neon.blue.opacity(0.06))
                }
            } else {
                NeonRow("URL") {
                    TextField("https://mcp.example.com/mcp", text: $draft.url).frame(width: sz(260))
                }
                NeonRow("Bearer token env var", subtitle: "Name of an env var holding the token (optional)") {
                    TextField("MY_TOKEN", text: $draft.bearerTokenEnvVar).frame(width: sz(220))
                }
            }

            Picker("Tool approval", selection: $draft.approvalMode) {
                Text("Auto").tag(MCPServer.ApprovalMode.auto)
                Text("Prompt").tag(MCPServer.ApprovalMode.prompt)
                Text("Approve").tag(MCPServer.ApprovalMode.approve)
            }.pickerStyle(.segmented)

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }.buttonStyle(.neon)
                Button("Save") { onSave(assembled()) }.buttonStyle(.neon).disabled(!canSave)
            }
        }
        .padding(sz(20))
        .frame(width: sz(460))
        .background(SettingsBackground())
    }
}
