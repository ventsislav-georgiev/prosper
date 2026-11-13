import Combine
import XCTest
@testable import ProsperApp

/// The Settings download's markers (#1005): `ModelFiles.downloadSnapshot` with a fake fetch
/// that writes small plain files into a temp hub. No network, no real model dir, no load.
final class ModelDownloadMarkerTests: XCTestCase {
    private var hub: URL!

    override func setUpWithError() throws {
        hub = tempDir("dlmarker")
    }

    /// What a fake fetch saw in `models--<id>/` when it ran.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String]?
        func set(_ v: [String]) { lock.lock(); value = v; lock.unlock() }
        func get() -> [String]? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static let shards = ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]

    /// Writes plain files (the copy layout) into `snapshots/main`; the index names both shards.
    private static func write(_ names: [String], root: URL) throws {
        let snap = root.appendingPathComponent("snapshots/main")
        try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
        for name in names {
            let data: Data
            if name == "model.safetensors.index.json" {
                data = try JSONSerialization.data(withJSONObject: ["weight_map": ["a": shards[0], "b": shards[1]]])
            } else {
                data = Data(count: 100)
            }
            try data.write(to: snap.appendingPathComponent(name))
        }
    }

    private func list(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func dirOf(_ id: String) -> URL { ModelFiles.modelDir(id, hubURL: hub) }

    func testCompletedDownloadWritesCompleteMarkerAfterTheFilesAndIsReady() async throws {
        let root = dirOf("ok/m")
        let seen = Seen()
        try await ModelFiles.downloadSnapshot("ok/m", hubURL: hub) {
            try seen.set(FileManager.default.contentsOfDirectory(atPath: root.path).sorted())
            try Self.write(["config.json", "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
                            "model.safetensors.index.json", "tokenizer.json"], root: root)
            return true
        }
        XCTAssertEqual(seen.get(), [".prosper-download-incomplete"])
        XCTAssertEqual(try list(root), [".prosper-download-complete", "snapshots"])
        XCTAssertTrue(ModelFiles.isModelDownloaded("ok/m", hubURL: hub))
        XCTAssertTrue(ModelFiles.diskState("ok/m", hubURL: hub).downloaded)
    }

    // The gap: every weight landed, config.json did not (the library's offline fallback
    // returns the partial snapshot as success; the fetch reports it).
    func testNotEveryFileLandedKeepsInProgressAndIsNotReady() async throws {
        let root = dirOf("gap/m")
        do {
            try await ModelFiles.downloadSnapshot("gap/m", hubURL: hub) {
                try Self.write(["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
                                "model.safetensors.index.json", "tokenizer.json"], root: root)
                return false
            }
            XCTFail("expected DownloadIncomplete")
        } catch is ModelFiles.DownloadIncomplete {}
        XCTAssertEqual(try list(root), [".prosper-download-incomplete", "snapshots"])
        XCTAssertEqual(try list(root.appendingPathComponent("snapshots/main")), [
            "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
            "model.safetensors.index.json", "tokenizer.json",
        ])
        XCTAssertTrue(ModelFiles.weightsOnDisk("gap/m", hubURL: hub))   // today's checks pass
        XCTAssertFalse(ModelFiles.isModelDownloaded("gap/m", hubURL: hub))
        XCTAssertFalse(ModelFiles.diskState("gap/m", hubURL: hub).downloaded)
    }

    // Every listed file landed but the weight check fails (one shard of two): no complete marker.
    func testWeightsIncompleteAfterFetchKeepsInProgress() async throws {
        let root = dirOf("half/m")
        do {
            try await ModelFiles.downloadSnapshot("half/m", hubURL: hub) {
                try Self.write(["config.json", "model-00001-of-00002.safetensors",
                                "model.safetensors.index.json"], root: root)
                return true
            }
            XCTFail("expected DownloadIncomplete")
        } catch is ModelFiles.DownloadIncomplete {}
        XCTAssertEqual(try list(root), [".prosper-download-incomplete", "snapshots"])
        XCTAssertFalse(ModelFiles.isModelDownloaded("half/m", hubURL: hub))
    }

    // A restart over a completed dir drops the old completion marker before the first byte;
    // a cancel then leaves only the in-progress marker.
    func testRestartOverCompletedDirDropsCompleteMarkerFirst() async throws {
        let root = dirOf("again/m")
        try Self.write(["config.json", "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
                        "model.safetensors.index.json"], root: root)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appendingPathComponent(".prosper-download-complete").path, contents: nil))
        XCTAssertTrue(ModelFiles.isModelDownloaded("again/m", hubURL: hub))
        let seen = Seen()
        do {
            try await ModelFiles.downloadSnapshot("again/m", hubURL: hub) {
                try seen.set(FileManager.default.contentsOfDirectory(atPath: root.path).sorted())
                throw CancellationError()
            }
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        XCTAssertEqual(seen.get(), [".prosper-download-incomplete", "snapshots"])
        XCTAssertEqual(try list(root), [".prosper-download-incomplete", "snapshots"])
        XCTAssertFalse(ModelFiles.isModelDownloaded("again/m", hubURL: hub))
    }

    // The crash-loop guard's question: weights on disk, markers aside.
    func testWeightsOnDiskIgnoresInProgressMarker() throws {
        let root = dirOf("guard/m")
        try Self.write(["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
                        "model.safetensors.index.json"], root: root)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appendingPathComponent(".prosper-download-incomplete").path, contents: nil))
        XCTAssertTrue(ModelFiles.weightsOnDisk("guard/m", hubURL: hub))
        XCTAssertFalse(ModelFiles.isModelDownloaded("guard/m", hubURL: hub))
    }

    // Same Progress tree swift-huggingface builds: one child per file, pending = its weight,
    // set complete when the file lands.
    func testEveryFileLandedOnlyWhenEveryChildCompleted() {
        XCTAssertFalse(ModelFiles.everyFileLanded(nil))
        XCTAssertFalse(ModelFiles.everyFileLanded(Progress(totalUnitCount: 0)))
        let parent = Progress(totalUnitCount: 300)
        let big = Progress(totalUnitCount: 200, parent: parent, pendingUnitCount: 200)
        let small = Progress(totalUnitCount: 100, parent: parent, pendingUnitCount: 100)
        XCTAssertFalse(ModelFiles.everyFileLanded(parent))
        big.completedUnitCount = 200
        XCTAssertFalse(ModelFiles.everyFileLanded(parent))
        small.completedUnitCount = 100
        XCTAssertTrue(ModelFiles.everyFileLanded(parent))
    }

    // A load that succeeded settles an interrupted Settings download (round 2).
    func testSettleAfterLoadCompletesInterruptedDownload() throws {
        let root = dirOf("settle/m")
        try Self.write(["config.json", "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
                        "model.safetensors.index.json"], root: root)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appendingPathComponent(".prosper-download-incomplete").path, contents: nil))
        XCTAssertFalse(ModelFiles.isModelDownloaded("settle/m", hubURL: hub))
        ModelFiles.settleAfterLoad("settle/m", hubURL: hub)
        XCTAssertEqual(try list(root), [".prosper-download-complete", "snapshots"])
        XCTAssertTrue(ModelFiles.isModelDownloaded("settle/m", hubURL: hub))
        XCTAssertTrue(ModelFiles.diskState("settle/m", hubURL: hub).downloaded)
    }

    func testSettleAfterLoadLeavesMarkerlessDirMarkerless() throws {
        let root = dirOf("legacy/m")
        try Self.write(["config.json", "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
                        "model.safetensors.index.json"], root: root)
        ModelFiles.settleAfterLoad("legacy/m", hubURL: hub)
        XCTAssertEqual(try list(root), ["snapshots"])
        XCTAssertTrue(ModelFiles.isModelDownloaded("legacy/m", hubURL: hub))
    }

    func testSettleAfterLoadWithOneShardOfTwoChangesNothing() throws {
        let root = dirOf("halfload/m")
        try Self.write(["config.json", "model-00001-of-00002.safetensors", "model.safetensors.index.json"], root: root)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: root.appendingPathComponent(".prosper-download-incomplete").path, contents: nil))
        ModelFiles.settleAfterLoad("halfload/m", hubURL: hub)
        XCTAssertEqual(try list(root), [".prosper-download-incomplete", "snapshots"])
        XCTAssertFalse(ModelFiles.isModelDownloaded("halfload/m", hubURL: hub))
    }

    // The race: a load of the same model settles the marker while the Settings download runs;
    // the download's own rename then finds no in-progress file and must still complete.
    func testDownloadWhoseMarkerALoadSettledFirstCompletes() async throws {
        let root = dirOf("race/m")
        let hub = self.hub!
        try await ModelFiles.downloadSnapshot("race/m", hubURL: hub) {
            try Self.write(["config.json", "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
                            "model.safetensors.index.json"], root: root)
            ModelFiles.settleAfterLoad("race/m", hubURL: hub)
            return true
        }
        XCTAssertEqual(try list(root), [".prosper-download-complete", "snapshots"])
        XCTAssertTrue(ModelFiles.isModelDownloaded("race/m", hubURL: hub))
    }

    // ENOENT with no complete marker is not "settled": the rename error still throws.
    func testInProgressMarkerGoneWithoutCompleteMarkerThrows() async throws {
        let root = dirOf("gone/m")
        do {
            try await ModelFiles.downloadSnapshot("gone/m", hubURL: hub) {
                try Self.write(["config.json", "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
                                "model.safetensors.index.json"], root: root)
                try FileManager.default.removeItem(at: root.appendingPathComponent(".prosper-download-incomplete"))
                return true
            }
            XCTFail("expected POSIXError ENOENT")
        } catch let e as POSIXError {
            XCTAssertEqual(e.code, .ENOENT)
        }
        XCTAssertEqual(try list(root), ["snapshots"])
    }

    @MainActor
    func testDeleteRemovesModelDirWithBothMarkers() async throws {
        let root = dirOf("del/m")
        try Self.write(["config.json", "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
                        "model.safetensors.index.json"], root: root)
        for name in [".prosper-download-incomplete", ".prosper-download-complete"] {
            XCTAssertTrue(FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil))
        }
        XCTAssertEqual(try list(root), [".prosper-download-complete", ".prosper-download-incomplete", "snapshots"])
        let manager = ModelDownloadManager.shared
        let start = manager.revision
        let deleted = expectation(description: "delete bumps revision")
        deleted.assertForOverFulfill = false
        let sub = manager.$revision.sink { if $0 > start { deleted.fulfill() } }
        manager.delete("del/m", hubURL: hub)
        await fulfillment(of: [deleted], timeout: 10)
        sub.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(try list(hub), [])
    }
}
