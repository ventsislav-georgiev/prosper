import AppKit

/// Locates and reveals the on-disk model cache used by swift-transformers /
/// MLXHuggingFace. The Hub download base is `~/.config/prosper/hf` (set via
/// `HF_HOME` / `HF_HUB_CACHE` in `ModelPaths.bootstrap()`); snapshots live
/// under `hub/models--<owner>--<name>/snapshots/...`.
enum ModelFiles {

    /// Hub download base: `~/.config/prosper/hf`.
    static var hubBaseURL: URL {
        ModelPaths.baseURL
    }

    /// HubCache root: `~/.config/prosper/hf/hub`.
    static var activeModelURL: URL {
        ModelPaths.hubURL
    }

    /// True when a model snapshot with weights is on disk — i.e. setup's download
    /// step is done. Scans for a `*.safetensors` under any
    /// `hub/models--*/snapshots/*`.
    static var isModelDownloaded: Bool {
        let fm = FileManager.default
        guard let models = try? fm.contentsOfDirectory(
            at: ModelPaths.hubURL, includingPropertiesForKeys: nil
        ) else { return false }
        for model in models where model.lastPathComponent.hasPrefix("models--") {
            let snapshots = model.appendingPathComponent("snapshots")
            guard let revs = try? fm.contentsOfDirectory(
                at: snapshots, includingPropertiesForKeys: nil
            ) else { continue }
            for rev in revs {
                if let files = try? fm.contentsOfDirectory(atPath: rev.path),
                   files.contains(where: { $0.hasSuffix(".safetensors") }) {
                    return true
                }
            }
        }
        return false
    }

    /// Hub cache subdir name for a model id: `mlx-community/gemma-4-e2b-it-4bit`
    /// → `models--mlx-community--gemma-4-e2b-it-4bit`.
    private static func cacheDirName(for modelId: String) -> String {
        "models--" + modelId.replacingOccurrences(of: "/", with: "--")
    }

    /// True when THIS specific model's weights are on disk (download done).
    /// Scans `hub/models--<sanitized id>/snapshots/*` for any `*.safetensors`.
    static func isModelDownloaded(_ modelId: String) -> Bool {
        guard !modelId.isEmpty else { return false }
        let fm = FileManager.default
        let snapshots = ModelPaths.hubURL
            .appendingPathComponent(cacheDirName(for: modelId))
            .appendingPathComponent("snapshots")
        guard let revs = try? fm.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil
        ) else { return false }
        for rev in revs {
            if let files = try? fm.contentsOfDirectory(atPath: rev.path),
               files.contains(where: { $0.hasSuffix(".safetensors") }) {
                return true
            }
        }
        return false
    }

    /// Decorates a model picker row label with a download-state marker so the user
    /// can see, at a glance, which models are already on disk and which will be
    /// fetched on selection. Empty id (the "None" row) is returned unchanged.
    static func pickerLabel(for modelId: String, base: String) -> String {
        guard !modelId.isEmpty else { return base }
        return isModelDownloaded(modelId) ? "✓ \(base)" : "↓ \(base)"
    }

    /// First fully-downloaded selectable model (recommended → default → alternate),
    /// or nil when none are present. Used to pick a revert target after a cancelled
    /// or failed switch.
    static func firstDownloadedModel() -> String? {
        (Preferences.selectableModelIds
            + [Preferences.liteModelId,
               Preferences.defaultModelId,
               Preferences.alternateModelId])
            .first(where: isModelDownloaded)
    }

    /// Opens the most specific existing dir in Finder: the hub cache root if
    /// present, else the HF home base, else ~/.config/prosper (creating nothing).
    static func reveal() {
        let fm = FileManager.default
        let candidates = [ModelPaths.hubURL, ModelPaths.baseURL]
        for url in candidates where fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        // Nothing downloaded yet — open ~/.config/prosper so the user can see
        // where files will appear once the model is fetched.
        NSWorkspace.shared.open(ModelPaths.baseURL.deletingLastPathComponent())
    }
}
