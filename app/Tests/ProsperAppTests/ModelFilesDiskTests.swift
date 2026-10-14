import XCTest
@testable import ProsperApp

/// `ModelFiles.diskState` against a synthesized HF cache tree (real `blobs/` + symlinked
/// `snapshots/`), plus a hot-path budget. The AI Models pane memoizes this, but it still
/// runs once per catalog model on appear / after a download — so it must be cheap and
/// must not double-count blobs via their snapshot symlinks.
final class ModelFilesDiskTests: XCTestCase {
    private var hub: URL!

    override func setUpWithError() throws {
        hub = tempDir("diskstate")
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: hub)
    }

    /// Builds `models--<id>/{blobs,snapshots/main}` with real blobs + name-bearing
    /// symlinks, mirroring the swift-transformers cache.
    @discardableResult
    private func makeCachedModel(_ id: String, blobs: [(name: String, link: String, bytes: Int)]) throws -> URL {
        let fm = FileManager.default
        let root = hub.appendingPathComponent("models--" + id.replacingOccurrences(of: "/", with: "--"))
        let blobDir = root.appendingPathComponent("blobs")
        let snapDir = root.appendingPathComponent("snapshots/main")
        try fm.createDirectory(at: blobDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapDir, withIntermediateDirectories: true)
        for b in blobs {
            let blob = blobDir.appendingPathComponent(b.name)            // sha-named, no ext
            try Data(count: b.bytes).write(to: blob)
            let link = snapDir.appendingPathComponent(b.link)            // model.safetensors → blob
            try fm.createSymbolicLink(at: link, withDestinationURL: blob)
        }
        return root
    }

    func testCacheLayoutSumsBlobsOnceAndDetectsWeights() throws {
        try makeCachedModel("owner/name", blobs: [
            ("sha-weights", "model.safetensors", 1000),
            ("sha-config", "config.json", 50),
        ])
        let s = ModelFiles.diskState("owner/name", hubURL: hub)
        XCTAssertTrue(s.downloaded)            // .safetensors symlink present
        XCTAssertEqual(s.sizeBytes, 1050)      // blobs only — symlinks not double-counted
    }

    func testNotDownloaded() {
        let s = ModelFiles.diskState("nobody/missing", hubURL: hub)
        XCTAssertFalse(s.downloaded)
        XCTAssertNil(s.sizeBytes)
    }

    func testConfigOnlyIsNotDownloaded() throws {
        // tokenizer/config present but no weights yet (partial/aborted fetch)
        try makeCachedModel("owner/partial", blobs: [("sha-config", "config.json", 50)])
        let s = ModelFiles.diskState("owner/partial", hubURL: hub)
        XCTAssertFalse(s.downloaded)
        XCTAssertNil(s.sizeBytes)
    }

    func testFlatLayoutRegularSafetensorsCounts() throws {
        // non-cache layout: a real .safetensors file directly under the model dir
        let fm = FileManager.default
        let root = hub.appendingPathComponent("models--flat--m")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(count: 2048).write(to: root.appendingPathComponent("model.safetensors"))
        let s = ModelFiles.diskState("flat/m", hubURL: hub)
        XCTAssertTrue(s.downloaded)
        XCTAssertEqual(s.sizeBytes, 2048)
    }

    func testEmptyIdIsSafe() {
        let s = ModelFiles.diskState("", hubURL: hub)
        XCTAssertFalse(s.downloaded)
        XCTAssertNil(s.sizeBytes)
    }

    // Sharded checkpoints: model.safetensors.index.json names the shard set; a download
    // cancelled after its first shard must not count as on disk (#441).
    private func writeIndex(_ root: URL, shards: [String]) throws {
        var map: [String: String] = [:]
        for (i, f) in shards.enumerated() { map["layer.\(i).weight"] = f; map["layer.\(i).bias"] = f }
        let data = try JSONSerialization.data(withJSONObject: ["metadata": [:], "weight_map": map])
        try data.write(to: root.appendingPathComponent("snapshots/main/model.safetensors.index.json"))
    }

    private let twoShards = ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]

    func testShardedIndexWithOneShardMissingIsNotDownloaded() throws {
        let root = try makeCachedModel("shard/half", blobs: [("sha-1", twoShards[0], 100)])
        try writeIndex(root, shards: twoShards)
        XCTAssertFalse(ModelFiles.diskState("shard/half", hubURL: hub).downloaded)
        XCTAssertFalse(ModelFiles.isModelDownloaded("shard/half", hubURL: hub))
    }

    func testShardedIndexWithAllShardsIsDownloaded() throws {
        let root = try makeCachedModel("shard/full", blobs: [
            ("sha-1", twoShards[0], 100), ("sha-2", twoShards[1], 100),
        ])
        try writeIndex(root, shards: twoShards)
        let s = ModelFiles.diskState("shard/full", hubURL: hub)
        XCTAssertTrue(s.downloaded)
        XCTAssertNotNil(s.sizeBytes)
        XCTAssertTrue(ModelFiles.isModelDownloaded("shard/full", hubURL: hub))
    }

    func testNoIndexSingleSafetensorsIsDownloaded() throws {
        try makeCachedModel("single/m", blobs: [("sha-w", "model.safetensors", 100)])
        XCTAssertTrue(ModelFiles.diskState("single/m", hubURL: hub).downloaded)
        XCTAssertTrue(ModelFiles.isModelDownloaded("single/m", hubURL: hub))
    }

    func testIndexWithNoShardFilesIsNotDownloaded() throws {
        let root = try makeCachedModel("shard/none", blobs: [("sha-config", "config.json", 50)])
        try writeIndex(root, shards: twoShards)
        XCTAssertFalse(ModelFiles.diskState("shard/none", hubURL: hub).downloaded)
        XCTAssertFalse(ModelFiles.isModelDownloaded("shard/none", hubURL: hub))
    }

    func testZeroByteListedShardIsNotDownloaded() throws {
        let root = try makeCachedModel("shard/empty", blobs: [
            ("sha-1", twoShards[0], 100), ("sha-2", twoShards[1], 0),
        ])
        try writeIndex(root, shards: twoShards)
        XCTAssertFalse(ModelFiles.diskState("shard/empty", hubURL: hub).downloaded)
        XCTAssertFalse(ModelFiles.isModelDownloaded("shard/empty", hubURL: hub))
    }

    func testDanglingShardSymlinkIsNotDownloaded() throws {
        let root = try makeCachedModel("shard/dangling", blobs: [
            ("sha-1", twoShards[0], 100), ("sha-2", twoShards[1], 100),
        ])
        try writeIndex(root, shards: twoShards)
        try FileManager.default.removeItem(at: root.appendingPathComponent("blobs/sha-2"))
        XCTAssertFalse(ModelFiles.diskState("shard/dangling", hubURL: hub).downloaded)
        XCTAssertFalse(ModelFiles.isModelDownloaded("shard/dangling", hubURL: hub))
    }

    // Copy fallback (no symlinks): plain shard files, one of them zero bytes.
    func testPlainFileShardsZeroByteIsNotDownloadedCompleteIs() throws {
        let root = try makeCachedModel("shard/plain", blobs: [])
        let snap = root.appendingPathComponent("snapshots/main")
        try writeIndex(root, shards: twoShards)
        try Data(count: 100).write(to: snap.appendingPathComponent(twoShards[0]))
        try Data().write(to: snap.appendingPathComponent(twoShards[1]))
        XCTAssertFalse(ModelFiles.diskState("shard/plain", hubURL: hub).downloaded)
        XCTAssertFalse(ModelFiles.isModelDownloaded("shard/plain", hubURL: hub))
        try Data(count: 100).write(to: snap.appendingPathComponent(twoShards[1]))
        XCTAssertTrue(ModelFiles.diskState("shard/plain", hubURL: hub).downloaded)
        XCTAssertTrue(ModelFiles.isModelDownloaded("shard/plain", hubURL: hub))
    }

    func testInvalidIndexIsNotDownloadedEvenWithSafetensors() throws {
        let root = try makeCachedModel("shard/badindex", blobs: [("sha-w", "model.safetensors", 100)])
        try Data("{not json".utf8).write(
            to: root.appendingPathComponent("snapshots/main/model.safetensors.index.json"))
        XCTAssertFalse(ModelFiles.diskState("shard/badindex", hubURL: hub).downloaded)
        XCTAssertFalse(ModelFiles.isModelDownloaded("shard/badindex", hubURL: hub))
    }

    // No index: swift-huggingface queues every file by size descending, eight at a time,
    // so with eight or more shards the index starts last and a cancel leaves shards, no index.
    func testNoIndexOneOfTwoShardsIsNotDownloaded() throws {
        try makeCachedModel("noidx/half", blobs: [("sha-1", twoShards[0], 100)])
        XCTAssertFalse(ModelFiles.diskState("noidx/half", hubURL: hub).downloaded)
        XCTAssertFalse(ModelFiles.isModelDownloaded("noidx/half", hubURL: hub))
    }

    func testNoIndexAllShardsIsDownloaded() throws {
        try makeCachedModel("noidx/full", blobs: [("sha-1", twoShards[0], 100), ("sha-2", twoShards[1], 100)])
        XCTAssertTrue(ModelFiles.diskState("noidx/full", hubURL: hub).downloaded)
        XCTAssertTrue(ModelFiles.isModelDownloaded("noidx/full", hubURL: hub))
    }

    func testNoIndexAllShardsOneZeroByteIsNotDownloaded() throws {
        try makeCachedModel("noidx/zero", blobs: [("sha-1", twoShards[0], 100), ("sha-2", twoShards[1], 0)])
        XCTAssertFalse(ModelFiles.diskState("noidx/zero", hubURL: hub).downloaded)
        XCTAssertFalse(ModelFiles.isModelDownloaded("noidx/zero", hubURL: hub))
    }

    func testNoIndexTwoOfThreeShardsIsNotDownloaded() throws {
        try makeCachedModel("noidx/three", blobs: [
            ("sha-1", "model-00001-of-00003.safetensors", 100),
            ("sha-2", "model-00002-of-00003.safetensors", 100),
        ])
        XCTAssertFalse(ModelFiles.diskState("noidx/three", hubURL: hub).downloaded)
        XCTAssertFalse(ModelFiles.isModelDownloaded("noidx/three", hubURL: hub))
    }

    func testNoIndexShardsDisagreeOnTotalIsNotDownloaded() throws {
        // A complete 2-shard family plus a stray shard from a 3-shard family.
        try makeCachedModel("noidx/mixed", blobs: [
            ("sha-1", "model-00001-of-00002.safetensors", 100),
            ("sha-2", "model-00002-of-00002.safetensors", 100),
            ("sha-3", "model-00003-of-00003.safetensors", 100),
        ])
        XCTAssertFalse(ModelFiles.diskState("noidx/mixed", hubURL: hub).downloaded)
        XCTAssertFalse(ModelFiles.isModelDownloaded("noidx/mixed", hubURL: hub))
    }

    func testNoIndexZeroByteSingleFileIsNotDownloaded() throws {
        try makeCachedModel("noidx/empty", blobs: [("sha-w", "model.safetensors", 0)])
        XCTAssertFalse(ModelFiles.diskState("noidx/empty", hubURL: hub).downloaded)
        XCTAssertFalse(ModelFiles.isModelDownloaded("noidx/empty", hubURL: hub))
    }

    func testIndexWithEmptyWeightMapIsNotDownloaded() throws {
        let root = try makeCachedModel("shard/emptymap", blobs: [("sha-w", "model.safetensors", 100)])
        try writeIndex(root, shards: [])
        XCTAssertFalse(ModelFiles.diskState("shard/emptymap", hubURL: hub).downloaded)
        XCTAssertFalse(ModelFiles.isModelDownloaded("shard/emptymap", hubURL: hub))
    }

    // Hot-path budget: the pane calls diskState per catalog model. A sharded weights
    // checkpoint (many blobs) must still resolve in well under a frame.
    func testDiskStatePerfBudget() throws {
        let blobs = (0..<40).map { (name: "sha-\($0)", link: "model-\($0).safetensors", bytes: 4096) }
        try makeCachedModel("perf/big", blobs: blobs)
        let start = Date()
        let s = ModelFiles.diskState("perf/big", hubURL: hub)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(s.sizeBytes, Int64(40 * 4096))
        XCTAssertLessThan(elapsed, 0.05, "diskState single-model walk should be a few ms, not \(elapsed)s")
    }
}
