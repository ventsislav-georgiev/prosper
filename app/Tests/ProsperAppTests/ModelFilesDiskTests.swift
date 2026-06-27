import XCTest
@testable import ProsperApp

/// `ModelFiles.diskState` against a synthesized HF cache tree (real `blobs/` + symlinked
/// `snapshots/`), plus a hot-path budget. The AI Models pane memoizes this, but it still
/// runs once per catalog model on appear / after a download — so it must be cheap and
/// must not double-count blobs via their snapshot symlinks.
final class ModelFilesDiskTests: XCTestCase {
    private var hub: URL!

    override func setUpWithError() throws {
        hub = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskstate-\(ProcessInfo.processInfo.globallyUniqueString)")
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
