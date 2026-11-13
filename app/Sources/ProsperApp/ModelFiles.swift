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
    /// (see `holdsWeights`), skipping a model whose download is in progress.
    static var isModelDownloaded: Bool {
        let fm = FileManager.default
        guard let models = try? fm.contentsOfDirectory(
            at: ModelPaths.hubURL, includingPropertiesForKeys: nil
        ) else { return false }
        for model in models where model.lastPathComponent.hasPrefix("models--") && !downloadInProgress(model) {
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
    /// index is not complete either). Without an index (swift-huggingface queues every
    /// file by size descending, eight at a time, so with eight or more shards the index
    /// starts last and a cancelled fetch can leave shards and no index): shards named
    /// `*-XXXXX-of-NNNNN.safetensors` need all NNNNN present; otherwise any non-empty
    /// `*.safetensors`.
    // Weights only: a cancel after the shards but before a small file (config, tokenizer,
    // index) passes this. A Settings download closes that with its markers (#1005,
    // `downloadSnapshot`); a marker-less dir (a download older than the markers, or a
    // lazy load, which fetches any missing small file itself) is judged by this alone.
    private static func holdsWeights(_ dir: URL) -> Bool {
        let fm = FileManager.default
        // Snapshot files are symlinks into blobs/ (copies where symlinks fail).
        // fileExists follows the link (dangling = absent); attributesOfItem does not,
        // so size the resolved blob. A missing, dangling or zero-byte file is absent.
        func present(_ name: String) -> Bool {
            let file = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: file.path) else { return false }
            let blob = file.resolvingSymlinksInPath().path
            return ((try? fm.attributesOfItem(atPath: blob))?[.size] as? Int64 ?? 0) > 0
        }
        let index = dir.appendingPathComponent("model.safetensors.index.json")
        if let data = fm.contents(atPath: index.path) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let map = json["weight_map"] as? [String: String], !map.isEmpty
            else { return false }
            return Set(map.values).allSatisfy(present)
        }
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        let weights = files.filter { $0.hasSuffix(".safetensors") }
        // Shard count NNNNN from each "-XXXXX-of-NNNNN.safetensors" name.
        let shards = weights.compactMap { name -> (name: String, total: Int)? in
            let parts = name.dropLast(".safetensors".count).components(separatedBy: "-of-")
            guard parts.count == 2, let n = Int(parts[1]),
                  let i = parts[0].split(separator: "-").last, Int(i) != nil else { return nil }
            return (name, n)
        }
        if shards.isEmpty { return weights.contains(where: present) }
        let totals = Set(shards.map(\.total))
        guard totals.count == 1, let total = totals.first else { return false }
        return shards.filter { present($0.name) }.count == total
    }

    /// Hub cache subdir name for a model id: `mlx-community/gemma-4-e2b-it-4bit`
    /// → `models--mlx-community--gemma-4-e2b-it-4bit`.
    private static func cacheDirName(for modelId: String) -> String {
        "models--" + modelId.replacingOccurrences(of: "/", with: "--")
    }

    /// Download markers (#1005), empty files in `models--<id>/` so Delete removes them with
    /// the model; only their names are read. `start` creates `downloadingMarker` before the
    /// first byte; after the last file and the checks it is renamed to `completeMarker`.
    /// A dir holding `downloadingMarker` is never ready; any other dir is judged by
    /// `holdsWeights` (marker-less = downloaded before the markers, or by a lazy load).
    static let downloadingMarker = ".prosper-download-incomplete"
    static let completeMarker = ".prosper-download-complete"

    /// `hub/models--<sanitized id>`, the dir Delete removes. `hubURL` is injectable for tests.
    static func modelDir(_ modelId: String, hubURL: URL = ModelPaths.hubURL) -> URL {
        hubURL.appendingPathComponent(cacheDirName(for: modelId))
    }

    private static func downloadInProgress(_ modelDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: modelDir.appendingPathComponent(downloadingMarker).path)
    }

    struct DownloadIncomplete: LocalizedError {
        var errorDescription: String? { "The download did not finish. Check the connection and download again." }
    }

    /// Settings download of a Hugging Face snapshot between the two markers. `fetch` downloads
    /// and returns whether every listed file landed (false when the library fell back to a
    /// partial cached snapshot). The complete marker is written only after that AND
    /// `holdsWeights`; a throw (cancel, error, incomplete) leaves the in-progress marker.
    static func downloadSnapshot(
        _ modelId: String, hubURL: URL = ModelPaths.hubURL,
        fetch: @Sendable () async throws -> Bool
    ) async throws {
        let fm = FileManager.default
        let dir = modelDir(modelId, hubURL: hubURL)
        let downloading = dir.appendingPathComponent(downloadingMarker)
        let complete = dir.appendingPathComponent(completeMarker)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard fm.createFile(atPath: downloading.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: downloading.path])
        }
        // After the in-progress marker: a crash between leaves both, and in-progress wins.
        if fm.fileExists(atPath: complete.path) { try fm.removeItem(at: complete) }
        guard try await fetch(), weightsOnDisk(modelId, hubURL: hubURL) else { throw DownloadIncomplete() }
        let err = markComplete(dir)
        guard err == 0 else { throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO) }
    }

    /// A load of `modelId` that SUCCEEDED settles an interrupted Settings download: the
    /// loader fetched what was missing, so in-progress + `weightsOnDisk` becomes complete.
    /// A marker-less dir stays marker-less (legacy rule). Never fails the load: a failed
    /// rename is logged. Costs one stat when no marker exists (every ordinary load).
    static func settleAfterLoad(_ modelId: String, hubURL: URL = ModelPaths.hubURL) {
        let dir = modelDir(modelId, hubURL: hubURL)
        guard downloadInProgress(dir), weightsOnDisk(modelId, hubURL: hubURL) else { return }
        let err = markComplete(dir)
        if err != 0 { NSLog("prosper: could not settle the download marker of %@ (errno %d)", modelId, err) }
    }

    /// rename(2) in-progress -> complete, one atomic step. Returns 0 when the complete marker is
    /// in place: renamed now, or ENOENT with the complete marker present (a load and a Settings
    /// download of the same model both finished; the other one renamed first). Else errno.
    private static func markComplete(_ dir: URL) -> Int32 {
        let complete = dir.appendingPathComponent(completeMarker).path
        if rename(dir.appendingPathComponent(downloadingMarker).path, complete) == 0 { return 0 }
        let err = errno
        if err == ENOENT, FileManager.default.fileExists(atPath: complete) { return 0 }
        return err
    }

    /// True when the hub `Progress` of a snapshot download shows every listed file landed:
    /// each file's child is set complete when it lands, so completed == total only then.
    /// nil (the library's offline fallback never reports progress) or zero total is false.
    static func everyFileLanded(_ p: Progress?) -> Bool {
        guard let p, p.totalUnitCount > 0 else { return false }
        return p.completedUnitCount >= p.totalUnitCount
    }

    /// True when THIS model is ready: on disk (see `weightsOnDisk`) and not inside a
    /// download that has not completed (`downloadingMarker`). `hubURL` is injectable for tests.
    static func isModelDownloaded(_ modelId: String, hubURL: URL = ModelPaths.hubURL) -> Bool {
        !downloadInProgress(modelDir(modelId, hubURL: hubURL)) && weightsOnDisk(modelId, hubURL: hubURL)
    }

    /// Today's file checks without the markers: the GGUF file exists, or a
    /// `hub/models--<sanitized id>/snapshots/*` dir holds a complete weight set (see
    /// `holdsWeights`). The crash-loop guard asks this: a load that dies after a lazy load
    /// finished an interrupted download must still arm it (#435, #1005).
    static func weightsOnDisk(_ modelId: String, hubURL: URL = ModelPaths.hubURL) -> Bool {
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
        let root = modelDir(modelId, hubURL: hubURL)
        guard !downloadInProgress(root) else { return DiskState(downloaded: false, sizeBytes: nil) }
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
