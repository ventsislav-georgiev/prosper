import Foundation
import Combine

/// Drives explicit, user-triggered model downloads from Settings: download-on-select
/// plus the Stop/Download toggle and Delete. Only one download runs at a time —
/// selecting a new model cancels the previous one. The agent's lazy load in
/// `ModelResidencyCoordinator.acquireAgent` stays the fallback for models that were
/// never pre-fetched here.
@MainActor
final class ModelDownloadManager: ObservableObject {
    static let shared = ModelDownloadManager()

    /// Model id currently downloading, or nil when idle.
    @Published private(set) var activeModelId: String?
    /// 0…1, or nil while total size is still unknown (indeterminate bar).
    @Published private(set) var progress: Double?
    /// Status line shown under the bar.
    @Published private(set) var status: String = ""
    /// Last error message, cleared on the next start.
    @Published private(set) var errorMessage: String?
    /// Bumped when a download finishes or a model is deleted, so views reading
    /// `ModelFiles.isModelDownloaded` (plain disk check, not @Published) recompute.
    @Published private(set) var revision = 0

    private var task: Task<Void, Never>?

    func isDownloading(_ modelId: String) -> Bool { activeModelId == modelId }

    /// Begin downloading `modelId` if not already on disk. No-op if it's the active
    /// download or already downloaded.
    /// `gguf`, `isDownloaded` and `fetch` are test seams (#1300): defaults are the registry, the
    /// disk check and the real download.
    func start(_ modelId: String,
               gguf lookup: @escaping ModelFiles.GGUFLookup = ModelFiles.registeredGGUF,
               isDownloaded: (String) -> Bool = { ModelFiles.isModelDownloaded($0) },
               fetch: @escaping GGUFDownload.Fetch = GGUFDownload.live) {
        guard !modelId.isEmpty,
              activeModelId != modelId,
              !isDownloaded(modelId) else { return }
        cancel()
        errorMessage = nil
        activeModelId = modelId
        progress = nil
        status = "Starting download…"
        task = Task {
            do {
                if let gguf = AgentModelRegistry.gguf(for: modelId), let reg = lookup(modelId) {
                    // Single-file GGUF (llama.cpp agent rows).
                    let dest = reg.url
                    // R1040-n1 (#1300): the guard ran before this Task did; one stat through the same
                    // helper right before the delete, so a file that is at the registered size by now
                    // (or a later change to the guard) never loses a good multi-GB file.
                    if ModelFiles.fileSize(dest) == reg.bytes {
                        guard self.activeModelId == modelId else { return }
                        self.revision += 1
                        self.reset()
                        return
                    }
                    // Not intact (#1040): fetch() would otherwise treat a leftover as present, so clear it.
                    try? FileManager.default.removeItem(at: dest)
                    try await fetch(gguf.downloadURL, dest, reg.bytes) { p, s in
                        Task { @MainActor in
                            guard ModelDownloadManager.shared.activeModelId == modelId else { return }
                            ModelDownloadManager.shared.progress = p
                            ModelDownloadManager.shared.status = s
                        }
                    }
                    guard self.activeModelId == modelId else { return }
                    self.revision += 1
                    self.reset()
                    return
                }
                try await ModelFiles.downloadSnapshot(modelId) {
                    try await MLXEngine.downloadModelFiles(modelId: modelId) { p, s in
                        Task { @MainActor in
                            guard ModelDownloadManager.shared.activeModelId == modelId else { return }
                            ModelDownloadManager.shared.progress = p
                            ModelDownloadManager.shared.status = s
                        }
                    }
                }
                guard self.activeModelId == modelId else { return }
                self.revision += 1
                self.reset()
            } catch is CancellationError {
                // Stop button — state already reset by cancel().
            } catch {
                guard self.activeModelId == modelId else { return }
                self.errorMessage = error.localizedDescription
                self.reset()
            }
        }
    }

    /// Test seam (#1300): resolves when the current download Task ends.
    func waitForTask() async { await task?.value }

    /// Stop the in-flight download (if any) and clear progress state.
    func cancel() {
        task?.cancel()
        task = nil
        if activeModelId != nil { reset() }
    }

    /// Remove a downloaded model's files from disk. Cancels first if it's downloading.
    /// The unlink runs off-main — a multi-GB checkpoint tree can take a noticeable
    /// moment, and blocking the main thread would freeze the UI. The whole model dir goes,
    /// download markers included (#1005). `hubURL` is injectable for tests.
    func delete(_ modelId: String, hubURL: URL = ModelPaths.hubURL) {
        guard !modelId.isEmpty else { return }
        if activeModelId == modelId { cancel() }
        let dir: URL
        if let gguf = AgentModelRegistry.gguf(for: modelId) {
            dir = LlamaAgentEngine.fileURL(fileName: gguf.fileName)
        } else {
            dir = ModelFiles.modelDir(modelId, hubURL: hubURL)
        }
        Task { [weak self] in
            await Task.detached { try? FileManager.default.removeItem(at: dir) }.value
            self?.revision += 1   // back on @MainActor → triggers the pane's disk rebuild
        }
    }

    private func reset() {
        activeModelId = nil
        progress = nil
        status = ""
    }
}
