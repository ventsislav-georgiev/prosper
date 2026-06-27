import SwiftUI
import AppKit

/// Which on-device role a model fills. The inline model is shared with the Translate
/// extension; the agent model is the coding agent's (loaded only during a run).
enum ModelRole: Hashable { case inline, agent }

/// Polls the live residency state (~1.5 s) so the AI Models pane shows, in real time,
/// which model is loaded right now and how much memory it's using — e.g. it lights up
/// the instant Translate auto-loads the inline model, and clears when idle-unload frees
/// it. All three reads are nonisolated globals, so no actor hops on the main thread.
@MainActor
final class LoadedModelMonitor: ObservableObject {
    @Published private(set) var inlineLoaded = false
    @Published private(set) var agentLoaded = false
    @Published private(set) var residentBytes: Int64 = 0
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let inline = MLXEngine.isInlineModelLoaded
                let agent = ModelResidencyCoordinator.isAgentActive
                // Skip the Metal allocator read when nothing is resident — it's 0 then.
                let bytes = (inline || agent) ? MLXEngine.residentMemoryBytes : 0
                // Assign only on change: a @Published write always fires objectWillChange,
                // so unconditional writes would re-render (and re-scan disk) every tick.
                if inline != self.inlineLoaded { self.inlineLoaded = inline }
                if agent != self.agentLoaded { self.agentLoaded = agent }
                if bytes != self.residentBytes { self.residentBytes = bytes }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

/// Unified model-management pane: live load state + RAM, download/delete, rename, and
/// "add your own" via a Hugging Face URL. Model *selection* still lives in the
/// Completions and Agent panes (this is the management hub).
struct AIModelsPane: View {
    /// One sheet at a time — SwiftUI only honours a single `.sheet` per view, so both
    /// the add-custom and rename flows route through this.
    private enum ActiveSheet: Identifiable {
        case addCustom
        case rename(RenameTarget)
        var id: String { switch self { case .addCustom: "add"; case .rename(let t): "rename-\(t.id)" } }
    }

    @ObservedObject var model: SettingsModel
    @ObservedObject private var downloads = ModelDownloadManager.shared
    @StateObject private var monitor = LoadedModelMonitor()
    @State private var loadingRoles: Set<ModelRole> = []
    @State private var sheet: ActiveSheet?
    /// Bumped on rename/add/remove so the plain (non-@Published) label reads recompute.
    @State private var refresh = 0
    /// Memoized per-model disk state, rebuilt only when downloads finish/delete
    /// (`downloads.revision`), a custom model is added/removed (`refresh`), or on appear —
    /// never during a render. Each entry is one `ModelFiles.diskState` walk.
    @State private var disk: [String: ModelFiles.DiskState] = [:]

    var body: some View {
        NeonScroll {
            PaneTitle(title: "AI Models",
                      subtitle: "Manage the on-device LLMs — download, delete, load, and add your own")

            statusSection

            if let err = downloads.errorMessage {
                Text("Download failed: \(err)")
                    .font(Neon.font(.caption)).foregroundStyle(Neon.magenta)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            NeonSection("Inline & Translate models",
                        footer: "The Gemma-4 family used for inline autocomplete and the Translate extension. Switching the active one lives in Completions → AI Model.") {
                catalogRows(AIModelSection.models.map {
                    Row(id: $0.0, fallbackLabel: $0.1, subtitle: nil, isCustom: false)
                }, role: .inline)
            }

            NeonSection("Coding-agent models",
                        footer: "Models for the coding agent (loaded only while a task runs). Add your own from a Hugging Face URL — it must be an MLX (.safetensors) checkpoint; whether it loads depends on architecture support.") {
                catalogRows(AgentModelRegistry.all().map {
                    Row(id: $0.id, fallbackLabel: $0.label, subtitle: $0.note,
                        isCustom: CustomModelStore.exists($0.id))
                }, role: .agent)
                NeonDivider()
                HStack {
                    Spacer()
                    Button("Add Model from Hugging Face…") { sheet = .addCustom }
                        .buttonStyle(.neon)
                }
            }
        }
        .onAppear { monitor.start(); rebuildDisk() }
        .onDisappear { monitor.stop() }
        .onChange(of: downloads.revision) { rebuildDisk() }
        .onChange(of: refresh) { rebuildDisk() }
        .sheet(item: $sheet) { which in
            switch which {
            case .addCustom:
                AddCustomModelSheet(onDone: { sheet = nil; refresh += 1 })
            case .rename(let t):
                RenameModelSheet(target: t, onDone: { sheet = nil; refresh += 1 })
            }
        }
    }

    // MARK: Live status

    private var statusSection: some View {
        NeonSection("Status",
                    footer: "Only one model is resident at a time — starting the agent frees the inline model, and it reloads afterwards. Memory shown is what MLX is actively using.") {
            statusRow(title: "Inline & Translate",
                      id: model.coreModel,
                      loaded: monitor.inlineLoaded,
                      role: .inline)
            NeonDivider()
            statusRow(title: "Coding agent",
                      id: model.agentModel,
                      loaded: monitor.agentLoaded,
                      role: .agent)
        }
    }

    @ViewBuilder
    private func statusRow(title: String, id: String, loaded: Bool, role: ModelRole) -> some View {
        let loading = loadingRoles.contains(role)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: sz(2)) {
                HStack(spacing: sz(6)) {
                    Text(title).foregroundStyle(Neon.textPrimary)
                    stateBadge(loaded: loaded, loading: loading)
                }
                Text(id.isEmpty ? "No model selected" : CustomModelStore.label(for: id, fallback: id))
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary).lineLimit(1)
                if loaded {
                    Text("Using \(MLXEngine.fmtBytes(monitor.residentBytes)) of memory")
                        .font(Neon.font(.caption2)).foregroundStyle(Neon.blue)
                }
            }
            Spacer(minLength: sz(12))
            if loading {
                ProgressView().controlSize(.small)
            } else if loaded {
                Button("Unload") { unload(role) }.buttonStyle(.neon)
            } else {
                Button("Load") { load(role) }.buttonStyle(.neon)
                    .disabled(id.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func stateBadge(loaded: Bool, loading: Bool) -> some View {
        let (text, color): (String, Color) =
            loading ? ("Loading…", Neon.magenta)
            : loaded ? ("Loaded", Neon.blue)
            : ("Unloaded", Neon.textSecondary)
        Text(text)
            .font(Neon.font(.caption2))
            .padding(.horizontal, sz(5)).padding(.vertical, sz(1))
            .background(color.opacity(0.18)).clipShape(Capsule())
            .foregroundStyle(color)
    }

    // Loads the currently *selected* model for the role: `coreModel` selection fires
    // onModelChanged → MLXEngine.shared tracks it; the agent loads Preferences.agentModel.
    private func load(_ role: ModelRole) {
        loadingRoles.insert(role)
        Task {
            switch role {
            case .inline: try? await MLXEngine.shared.load { _, _ in }
            case .agent:  _ = try? await ModelResidencyCoordinator.shared.acquireAgent { _, _ in }
            }
            await MainActor.run { loadingRoles.remove(role) }
        }
    }

    private func unload(_ role: ModelRole) {
        Task {
            switch role {
            case .inline: await MLXEngine.shared.requestUnload()
            case .agent:  await ModelResidencyCoordinator.shared.releaseAgent()
            }
        }
    }

    // MARK: Catalog

    private struct Row: Identifiable {
        let id: String
        let fallbackLabel: String
        let subtitle: String?
        let isCustom: Bool
    }

    /// All catalog model ids (inline + agent, incl. custom). Source of truth for which
    /// rows exist and which disk states to memoize.
    private func catalogIDs() -> [String] {
        AIModelSection.models.map(\.0) + AgentModelRegistry.all().map(\.id)
    }

    private func rebuildDisk() {
        var m: [String: ModelFiles.DiskState] = [:]
        for id in catalogIDs() { m[id] = ModelFiles.diskState(id) }
        disk = m
    }

    @ViewBuilder
    private func catalogRows(_ rows: [Row], role: ModelRole) -> some View {
        ForEach(rows) { row in
            if row.id != rows.first?.id { NeonDivider() }
            catalogRow(row, role: role)
        }
    }

    @ViewBuilder
    private func catalogRow(_ row: Row, role: ModelRole) -> some View {
        let state = disk[row.id] ?? ModelFiles.DiskState(downloaded: false, sizeBytes: nil)
        let downloaded = state.downloaded
        let isCurrent = (role == .inline ? model.coreModel : model.agentModel) == row.id
        let label = CustomModelStore.label(for: row.id, fallback: row.fallbackLabel)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: sz(2)) {
                HStack(spacing: sz(6)) {
                    Text(label).foregroundStyle(Neon.textPrimary).lineLimit(1)
                    if isCurrent { tag("In use", Neon.blue) }
                    if row.isCustom { tag("Custom", Neon.magenta) }
                }
                Text(subtitle(row, downloaded: downloaded))
                    .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary).lineLimit(2)
            }
            Spacer(minLength: sz(12))
            rowActions(row, role: role, downloaded: downloaded, isCurrent: isCurrent)
        }
    }

    private func subtitle(_ row: Row, downloaded: Bool) -> String {
        if downloads.isDownloading(row.id) { return downloads.status }
        if downloaded, let sz = disk[row.id]?.sizeBytes {
            return "Downloaded · \(MLXEngine.fmtBytes(sz)) on disk"
        }
        if let s = row.subtitle, !s.isEmpty { return s }
        return downloaded ? "Downloaded" : "Not downloaded"
    }

    @ViewBuilder
    private func rowActions(_ row: Row, role: ModelRole, downloaded: Bool, isCurrent: Bool) -> some View {
        if downloads.isDownloading(row.id) {
            HStack(spacing: sz(8)) {
                NeonProgressBar(progress: downloads.progress).frame(width: sz(90))
                Button("Stop") { downloads.cancel() }.buttonStyle(.neon)
            }
        } else {
            HStack(spacing: sz(6)) {
                if downloaded {
                    // Delete bumps downloads.revision when the async unlink finishes,
                    // which rebuilds disk state — no premature refresh needed.
                    Button("Delete") { downloads.delete(row.id) }
                        .buttonStyle(.neonDestructive)
                } else {
                    // One download at a time — disable the rest while one is in flight,
                    // else start() would silently cancel it.
                    Button("Download") { downloads.start(row.id) }.buttonStyle(.neon)
                        .disabled(downloads.activeModelId != nil)
                }
                Menu {
                    if !isCurrent {
                        Button(role == .inline ? "Use for inline" : "Use for agent") {
                            if role == .inline { model.coreModel = row.id } else { model.agentModel = row.id }
                        }
                    }
                    Button("Rename…") {
                        sheet = .rename(RenameTarget(id: row.id, currentLabel: row.fallbackLabel))
                    }
                    if row.isCustom {
                        Button("Remove from list", role: .destructive) {
                            // Don't leave the agent pointed at an id that no longer exists.
                            if model.agentModel == row.id { model.agentModel = AgentModelRegistry.recommendedId }
                            CustomModelStore.remove(row.id); refresh += 1
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Neon.font(.caption2))
            .padding(.horizontal, sz(5)).padding(.vertical, sz(1))
            .background(color.opacity(0.18)).clipShape(Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Rename sheet

struct RenameTarget: Identifiable {
    let id: String
    let currentLabel: String
}

/// Edits the display label override for a model (the "rename with my own clarifications
/// in brackets" feature). Clearing it reverts to the built-in name.
private struct RenameModelSheet: View {
    let target: RenameTarget
    let onDone: () -> Void
    @State private var label: String

    init(target: RenameTarget, onDone: @escaping () -> Void) {
        self.target = target
        self.onDone = onDone
        _label = State(initialValue: CustomModelStore.label(for: target.id, fallback: target.currentLabel))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: sz(14)) {
            Text("Rename Model").font(Neon.font(.headline)).foregroundStyle(Neon.textPrimary)
            Text(target.id).font(Neon.font(.caption, design: .monospaced)).foregroundStyle(Neon.textSecondary)
            TextField("Display name", text: $label).frame(width: sz(360))
            HStack {
                Button("Reset to default") { CustomModelStore.clearLabel(target.id); onDone() }
                    .buttonStyle(.neon)
                Spacer()
                Button("Cancel") { onDone() }.buttonStyle(.neon)
                Button("Save") { CustomModelStore.setLabel(target.id, label); onDone() }
                    .buttonStyle(.neon)
            }
        }
        .padding(sz(20)).frame(width: sz(420)).background(SettingsBackground())
    }
}

// MARK: - Add custom model sheet

/// Fetches metadata from a Hugging Face URL, lets the user adjust the name + tool
/// format, then saves it as a custom agent model. Download is started from the catalog
/// row afterwards.
private struct AddCustomModelSheet: View {
    let onDone: () -> Void
    @State private var urlText = ""
    @State private var fetching = false
    @State private var error: String?
    @State private var fetched: HFModelImporter.Imported?
    @State private var label = ""
    @State private var toolFormat: ToolCallFormat = .qwenXML

    var body: some View {
        VStack(alignment: .leading, spacing: sz(14)) {
            Text("Add Model from Hugging Face").font(Neon.font(.headline)).foregroundStyle(Neon.textPrimary)
            Text("Paste a model URL (e.g. https://huggingface.co/mlx-community/…) or an owner/name id. It must be an MLX .safetensors checkpoint.")
                .font(Neon.font(.caption)).foregroundStyle(Neon.textSecondary).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: sz(8)) {
                TextField("huggingface.co/owner/name", text: $urlText).frame(width: sz(320))
                Button(fetching ? "Fetching…" : "Fetch") { fetch() }
                    .buttonStyle(.neon)
                    .disabled(fetching || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error { Text(error).font(Neon.font(.caption)).foregroundStyle(Neon.magenta).fixedSize(horizontal: false, vertical: true) }

            if let f = fetched {
                NeonDivider()
                NeonRow("Name") { TextField("Display name", text: $label).frame(width: sz(280)) }
                NeonRow("Download size") {
                    Text(f.sizeBytes > 0 ? MLXEngine.fmtBytes(f.sizeBytes) : "unknown")
                        .foregroundStyle(Neon.textSecondary)
                }
                Picker("Tool-call format", selection: $toolFormat) {
                    ForEach(ToolCallFormat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Text("How the model emits tool calls — guessed from the name. Wrong choice breaks agent tool use; leave as-is if unsure.")
                    .font(Neon.font(.caption2)).foregroundStyle(Neon.textSecondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDone() }.buttonStyle(.neon)
                Button("Add") { save() }.buttonStyle(.neon).disabled(fetched == nil)
            }
        }
        .padding(sz(20)).frame(width: sz(480)).background(SettingsBackground())
    }

    private func fetch() {
        fetching = true; error = nil; fetched = nil
        Task {
            do {
                let f = try await HFModelImporter.fetch(urlText)
                await MainActor.run {
                    fetching = false
                    // A custom id that matches a built-in would duplicate it in the agent
                    // list (and the ForEach id). It's already available — no need to add.
                    if AgentModelRegistry.models.contains(where: { $0.id == f.id }) {
                        error = "That model is already in the built-in catalog."
                        return
                    }
                    fetched = f; label = f.label; toolFormat = f.toolFormat
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription; fetching = false
                }
            }
        }
    }

    private func save() {
        guard let f = fetched else { return }
        let note = "Custom" + (f.sizeBytes > 0 ? " · ~\(MLXEngine.fmtBytes(f.sizeBytes)) download" : "")
        CustomModelStore.upsert(CustomAgentModel(
            id: f.id,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? f.label : label,
            sizeBytes: f.sizeBytes, note: note, toolFormat: toolFormat))
        onDone()
    }
}
