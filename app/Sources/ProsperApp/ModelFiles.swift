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
    /// step is done. Scans `hub/models--*/snapshots/*` for a complete weight set
    /// (see `holdsWeights`).
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
            if revs.contains(where: holdsWeights) { return true }
        }
        return false
    }

    /// True when `dir` holds a complete weight set: with a `model.safetensors.index.json`,
    /// every distinct file in its `weight_map` exists in `dir` with a size above zero (a
    /// sharded download cancelled after its first shard is not complete; an unparseable
    /// index is not complete either); without an index, any `*.safetensors`.
    private static func holdsWeights(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let index = dir.appendingPathComponent("model.safetensors.index.json")
        if let data = fm.contents(atPath: index.path) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let map = json["weight_map"] as? [String: String], !map.isEmpty
            else { return false }
            // Snapshot files are symlinks into blobs/ (copies where symlinks fail).
            // fileExists follows the link (dangling = absent); attributesOfItem does not,
            // so size the resolved blob. A missing, dangling or zero-byte shard is absent.
            return Set(map.values).allSatisfy {
                let shard = dir.appendingPathComponent($0)
                guard fm.fileExists(atPath: shard.path) else { return false }
                let blob = shard.resolvingSymlinksInPath().path
                return ((try? fm.attributesOfItem(atPath: blob))?[.size] as? Int64 ?? 0) > 0
            }
        }
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        return files.contains(where: { $0.hasSuffix(".safetensors") })
    }

    /// Hub cache subdir name for a model id: `mlx-community/gemma-4-e2b-it-4bit`
    /// → `models--mlx-community--gemma-4-e2b-it-4bit`.
    private static func cacheDirName(for modelId: String) -> String {
        "models--" + modelId.replacingOccurrences(of: "/", with: "--")
    }

    /// True when THIS specific model's weights are on disk (download done).
    /// Scans `hub/models--<sanitized id>/snapshots/*` for a complete weight set
    /// (see `holdsWeights`). `hubURL` is injectable for tests.
    static func isModelDownloaded(_ modelId: String, hubURL: URL = ModelPaths.hubURL) -> Bool {
        guard !modelId.isEmpty else { return false }
        if let gguf = AgentModelRegistry.gguf(for: modelId) {
            return FileManager.default.fileExists(
                atPath: LlamaAgentEngine.fileURL(fileName: gguf.fileName).path)
        }
        let fm = FileManager.default
        let snapshots = hubURL
            .appendingPathComponent(cacheDirName(for: modelId))
            .appendingPathComponent("snapshots")
        guard let revs = try? fm.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: nil
        ) else { return false }
        return revs.contains(where: holdsWeights)
    }

    struct DiskState: Equatable { let downloaded: Bool; let sizeBytes: Int64? }

    /// Download state for a model in ONE filesystem walk: whether weights are present
    /// and the real on-disk size. `hubURL` is injectable for tests.
    ///
    /// HF cache layout: real bytes live in `blobs/<sha>` (no extension); the
    /// `.safetensors` name is on the `snapshots/*` symlinks pointing at those blobs. So:
    ///   - size = sum of *real* files only — symlinks are skipped (following one would
    ///     double-count the blob it targets),
    ///   - "has weights" = a directory holding a `*.safetensors` entry (symlink OR regular
    ///     file) passes `holdsWeights` (complete shard set when an index exists), which
    ///     also covers a flat, non-cache layout.
    /// One walk, not two (vs separate `isModelDownloaded` + size), because the AI Models
    /// pane computes this for every catalog row.
    static func diskState(_ modelId: String, hubURL: URL = ModelPaths.hubURL) -> DiskState {
        guard !modelId.isEmpty else { return DiskState(downloaded: false, sizeBytes: nil) }
        if let gguf = AgentModelRegistry.gguf(for: modelId) {
            // Single-file GGUF (llama.cpp agent rows) — no HF cache walk.
            let path = LlamaAgentEngine.fileURL(fileName: gguf.fileName).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int64
            else { return DiskState(downloaded: false, sizeBytes: nil) }
            return DiskState(downloaded: true, sizeBytes: size)
        }
        let fm = FileManager.default
        let root = hubURL.appendingPathComponent(cacheDirName(for: modelId))
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            return DiskState(downloaded: false, sizeBytes: nil)
        }
        var total: Int64 = 0
        var weightDirs = Set<URL>()
        for case let url as URL in en {
            if url.pathExtension == "safetensors" { weightDirs.insert(url.deletingLastPathComponent()) }
            guard let v = try? url.resourceValues(forKeys: keys),
                  v.isSymbolicLink != true, v.isRegularFile == true, let sz = v.fileSize
            else { continue }
            total += Int64(sz)
        }
        let hasWeights = weightDirs.contains(where: holdsWeights)
        return DiskState(downloaded: hasWeights, sizeBytes: hasWeights ? total : nil)
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
            .first(where: { isModelDownloaded($0) })
    }

    /// Reveals one model's files in Finder: the GGUF file for llama.cpp agent
    /// rows, the hub cache dir for HF snapshot rows. Falls back to the generic
    /// cache reveal when the model has nothing on disk.
    static func reveal(_ modelId: String) {
        let url: URL = if let gguf = AgentModelRegistry.gguf(for: modelId) {
            LlamaAgentEngine.fileURL(fileName: gguf.fileName)
        } else {
            ModelPaths.hubURL.appendingPathComponent(cacheDirName(for: modelId))
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return reveal() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
