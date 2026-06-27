import Foundation

/// A user-added coding-agent model (fetched from a Hugging Face URL in the AI Models
/// pane). Custom models only fill the AGENT role: the inline-autocomplete path is
/// locked to the Gemma-4 VLM family (tokenizer + loader constraints), so an arbitrary
/// HF checkpoint won't load there. The agent path loads many architectures.
struct CustomAgentModel: Codable, Identifiable, Equatable, Sendable {
    let id: String              // Hugging Face repo id, e.g. "mlx-community/Foo-4bit"
    var label: String           // display name (user-editable)
    var sizeBytes: Int64        // total download size from the HF API (0 if unknown)
    var note: String            // one-line note shown under the label
    var toolFormat: ToolCallFormat
}

/// Persistent store for user-added agent models plus per-model display-label overrides
/// (the "rename with my own clarifications in brackets" feature). Both are small JSON
/// blobs in UserDefaults — no migration machinery needed for a handful of entries.
enum CustomModelStore {
    private static var defaults: UserDefaults { .standard }
    private static let modelsKey = "customAgentModelsV1"
    private static let labelsKey = "modelLabelOverridesV1"

    // MARK: Custom agent models

    static func all() -> [CustomAgentModel] {
        guard let data = defaults.data(forKey: modelsKey),
              let list = try? JSONDecoder().decode([CustomAgentModel].self, from: data)
        else { return [] }
        return list
    }

    static func exists(_ id: String) -> Bool { all().contains { $0.id == id } }

    /// Insert or replace by id, then persist.
    static func upsert(_ model: CustomAgentModel) {
        var list = all().filter { $0.id != model.id }
        list.append(model)
        save(list)
    }

    static func remove(_ id: String) {
        save(all().filter { $0.id != id })
        clearLabel(id)
    }

    private static func save(_ list: [CustomAgentModel]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: modelsKey)
    }

    /// Custom models as `AgentModel` rows so they drop straight into the agent picker
    /// and `AgentModelRegistry.all()`. RAM estimate = download size × 1.15 (weights
    /// expand slightly once resident); the install floor adds a small headroom.
    static func asAgentModels() -> [AgentModel] {
        all().map { c in
            let ramGB = c.sizeBytes > 0 ? Double(c.sizeBytes) / 1_000_000_000 * 1.15 : 0
            let minRAM = ramGB > 0 ? max(8, Int(ramGB.rounded(.up)) + 2) : 8
            return AgentModel(id: c.id, label: c.label, approxRAMGB: ramGB,
                              minRAMGB: minRAM, toolFormat: c.toolFormat, note: c.note)
        }
    }

    // MARK: Label overrides

    private static func overrides() -> [String: String] {
        defaults.dictionary(forKey: labelsKey) as? [String: String] ?? [:]
    }

    /// User-chosen display label for a model id, or `fallback` when none is set.
    static func label(for id: String, fallback: String) -> String {
        let o = overrides()[id]
        return (o?.isEmpty == false) ? o! : fallback
    }

    static func setLabel(_ id: String, _ label: String) {
        var o = overrides()
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { o.removeValue(forKey: id) } else { o[id] = trimmed }
        defaults.set(o, forKey: labelsKey)
    }

    static func clearLabel(_ id: String) {
        var o = overrides()
        o.removeValue(forKey: id)
        defaults.set(o, forKey: labelsKey)
    }
}
