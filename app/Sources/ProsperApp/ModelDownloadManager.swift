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
    func start(_ modelId: String) {
        guard !modelId.isEmpty,
              activeModelId != modelId,
              !ModelFiles.isModelDownloaded(modelId) else { return }
        cancel()
        errorMessage = nil
        activeModelId = modelId
        progress = nil
        status = "Starting download…"
        task = Task {
            do {
                try await MLXEngine.downloadModelFiles(modelId: modelId) { p, s in
                    Task { @MainActor in
                        guard ModelDownloadManager.shared.activeModelId == modelId else { return }
                        ModelDownloadManager.shared.progress = p
                        ModelDownloadManager.shared.status = s
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

    /// Stop the in-flight download (if any) and clear progress state.
    func cancel() {
        task?.cancel()
        task = nil
        if activeModelId != nil { reset() }
    }

    /// Remove a downloaded model's files from disk. Cancels first if it's downloading.
    /// The unlink runs off-main — a multi-GB checkpoint tree can take a noticeable
    /// moment, and blocking the main thread would freeze the UI.
    func delete(_ modelId: String) {
        guard !modelId.isEmpty else { return }
        if activeModelId == modelId { cancel() }
        let dir = ModelPaths.hubURL.appendingPathComponent(
            "models--" + modelId.replacingOccurrences(of: "/", with: "--"))
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
