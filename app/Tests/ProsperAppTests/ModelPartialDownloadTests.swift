import Combine
import XCTest
@testable import ProsperApp

/// #1040: a partly downloaded model reports its bytes and can be deleted; a GGUF whose size
/// differs from the registry's is not downloaded. Every hub is a temp dir, every GGUF a small
/// fake file with a fake registry entry: no network, no real model dir, no load.
final class ModelPartialDownloadTests: XCTestCase {
    private var hub: URL!

    override func setUpWithError() throws {
        hub = tempDir("partial1040")
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: hub)
    }

    private func dir(_ id: String) -> URL { ModelFiles.modelDir(id, hubURL: hub) }

    /// `models--<id>/blobs/<name>` regular files of the given sizes (+ optional snapshot symlinks).
    private func write(_ id: String, blobs: [(name: String, link: String?, bytes: Int)], marker: String?) throws {
        let fm = FileManager.default
        let root = dir(id)
        let snap = root.appendingPathComponent("snapshots/main")
        try fm.createDirectory(at: root.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        for b in blobs {
            let blob = root.appendingPathComponent("blobs/" + b.name)
            try Data(count: b.bytes).write(to: blob)
            if let link = b.link { try fm.createSymbolicLink(at: snap.appendingPathComponent(link), withDestinationURL: blob) }
        }
        if let marker { XCTAssertTrue(fm.createFile(atPath: root.appendingPathComponent(marker).path, contents: nil)) }
    }

    // MARK: partly downloaded (HF snapshot)

    func testInterruptedDownloadWithBytesOnDiskIsPartlyDownloaded() throws {
        try write("a/m", blobs: [("sha-1.incomplete", nil, 300), ("sha-c", "config.json", 20)],
                  marker: ".prosper-download-incomplete")
        XCTAssertEqual(ModelFiles.partialBytes("a/m", hubURL: hub), 320)
        let s = ModelFiles.diskState("a/m", hubURL: hub)
        XCTAssertFalse(s.downloaded)
        XCTAssertTrue(s.sizeBytes == nil)
        XCTAssertEqual(s.partialBytes, 320)
        XCTAssertFalse(ModelFiles.isModelDownloaded("a/m", hubURL: hub))
    }

    // The marker wins over complete weights: still not ready, and its bytes are reported.
    func testInterruptedWithEveryWeightPresentIsPartlyDownloadedNotReady() throws {
        try write("a/full", blobs: [("sha-w", "model.safetensors", 1000)], marker: ".prosper-download-incomplete")
        XCTAssertEqual(ModelFiles.partialBytes("a/full", hubURL: hub), 1000)
        XCTAssertFalse(ModelFiles.diskState("a/full", hubURL: hub).downloaded)
    }

    func testMarkerlessDirWithoutWeightsIsPartlyDownloaded() throws {
        try write("a/cfg", blobs: [("sha-c", "config.json", 50)], marker: nil)
        XCTAssertEqual(ModelFiles.partialBytes("a/cfg", hubURL: hub), 50)
    }

    func testNothingOnDiskOrDownloadedOrEmptyMarkerIsNotPartial() throws {
        XCTAssertTrue(ModelFiles.partialBytes("a/none", hubURL: hub) == nil)
        XCTAssertTrue(ModelFiles.partialBytes("", hubURL: hub) == nil)
        try write("a/done", blobs: [("sha-w", "model.safetensors", 1000)], marker: ".prosper-download-complete")
        XCTAssertTrue(ModelFiles.partialBytes("a/done", hubURL: hub) == nil)
        XCTAssertEqual(ModelFiles.diskState("a/done", hubURL: hub),
                       ModelFiles.DiskState(downloaded: true, sizeBytes: 1000))
        try write("a/empty", blobs: [], marker: ".prosper-download-incomplete")
        XCTAssertTrue(ModelFiles.partialBytes("a/empty", hubURL: hub) == nil)
    }

    // MARK: Delete

    @MainActor
    func testDeleteOfAPartlyDownloadedModelRemovesOnlyThatModelDir() async throws {
        try write("a/m", blobs: [("sha-1.incomplete", nil, 300)], marker: ".prosper-download-incomplete")
        try write("b/other", blobs: [("sha-2.incomplete", nil, 70)], marker: ".prosper-download-incomplete")
        let manager = ModelDownloadManager.shared
        let start = manager.revision
        let deleted = expectation(description: "delete bumps revision")
        deleted.assertForOverFulfill = false
        let sub = manager.$revision.sink { if $0 > start { deleted.fulfill() } }
        manager.delete("a/m", hubURL: hub)
        await fulfillment(of: [deleted], timeout: 10)
        sub.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir("a/m").path))
        XCTAssertTrue(ModelFiles.partialBytes("a/m", hubURL: hub) == nil)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: hub.path), ["models--b--other"])
        XCTAssertEqual(ModelFiles.partialBytes("b/other", hubURL: hub), 70)
    }

    // MARK: GGUF size check (fake file, fake registry entry)

    private func ggufLookup(_ file: URL, bytes: Int64) -> ModelFiles.GGUFLookup {
        { id in id == "fake/Example-GGUF" ? (url: file, bytes: bytes) : nil }
    }

    func testTruncatedGGUFIsNotDownloadedAndIsPartial() throws {
        let file = hub.appendingPathComponent("Example-Q4.gguf")
        try Data(count: 40).write(to: file)
        let lookup = ggufLookup(file, bytes: 100)
        XCTAssertFalse(ModelFiles.weightsOnDisk("fake/Example-GGUF", hubURL: hub, gguf: lookup))
        XCTAssertFalse(ModelFiles.isModelDownloaded("fake/Example-GGUF", hubURL: hub, gguf: lookup))
        let s = ModelFiles.diskState("fake/Example-GGUF", hubURL: hub, gguf: lookup)
        XCTAssertFalse(s.downloaded)
        XCTAssertTrue(s.sizeBytes == nil)
        XCTAssertEqual(s.partialBytes, 40)
        XCTAssertEqual(ModelFiles.partialBytes("fake/Example-GGUF", hubURL: hub, gguf: lookup), 40)
    }

    func testGGUFAtTheRegistrySizeIsDownloaded() throws {
        let file = hub.appendingPathComponent("Example-Q4.gguf")
        try Data(count: 100).write(to: file)
        let lookup = ggufLookup(file, bytes: 100)
        XCTAssertTrue(ModelFiles.weightsOnDisk("fake/Example-GGUF", hubURL: hub, gguf: lookup))
        XCTAssertTrue(ModelFiles.isModelDownloaded("fake/Example-GGUF", hubURL: hub, gguf: lookup))
        XCTAssertEqual(ModelFiles.diskState("fake/Example-GGUF", hubURL: hub, gguf: lookup),
                       ModelFiles.DiskState(downloaded: true, sizeBytes: 100))
    }

    func testGGUFLongerThanTheRegistrySizeIsNotDownloaded() throws {
        let file = hub.appendingPathComponent("Example-Q4.gguf")
        try Data(count: 101).write(to: file)
        XCTAssertFalse(ModelFiles.isModelDownloaded("fake/Example-GGUF", hubURL: hub, gguf: ggufLookup(file, bytes: 100)))
    }

    func testMissingAndEmptyGGUFAreNotPartial() throws {
        let file = hub.appendingPathComponent("Example-Q4.gguf")
        let lookup = ggufLookup(file, bytes: 100)
        XCTAssertFalse(ModelFiles.isModelDownloaded("fake/Example-GGUF", hubURL: hub, gguf: lookup))
        XCTAssertTrue(ModelFiles.partialBytes("fake/Example-GGUF", hubURL: hub, gguf: lookup) == nil)
        try Data().write(to: file)
        XCTAssertFalse(ModelFiles.isModelDownloaded("fake/Example-GGUF", hubURL: hub, gguf: lookup))
        XCTAssertTrue(ModelFiles.partialBytes("fake/Example-GGUF", hubURL: hub, gguf: lookup) == nil)
    }

    // MARK: the row's text and buttons (pure)

    @MainActor
    func testRowSubtitleTextLiterals() {
        let partial = ModelFiles.DiskState(downloaded: false, sizeBytes: nil, partialBytes: 3_000_000)
        XCTAssertEqual(AIModelsPane.subtitleText(state: partial, catalogSubtitle: "Fast", ramNote: "", downloadStatus: nil),
                       "Partly downloaded \u{B7} 3 MB on disk")
        XCTAssertEqual(AIModelsPane.subtitleText(state: partial, catalogSubtitle: nil, ramNote: " \u{B7} needs 64 GB RAM",
                                                 downloadStatus: nil),
                       "Partly downloaded \u{B7} 3 MB on disk \u{B7} needs 64 GB RAM")
        let done = ModelFiles.DiskState(downloaded: true, sizeBytes: 3_000_000)
        XCTAssertEqual(AIModelsPane.subtitleText(state: done, catalogSubtitle: "Fast", ramNote: "", downloadStatus: nil),
                       "Downloaded \u{B7} 3 MB on disk")
        let none = ModelFiles.DiskState(downloaded: false, sizeBytes: nil)
        XCTAssertEqual(AIModelsPane.subtitleText(state: none, catalogSubtitle: nil, ramNote: "", downloadStatus: nil),
                       "Not downloaded")
        XCTAssertEqual(AIModelsPane.subtitleText(state: none, catalogSubtitle: "Fast", ramNote: "", downloadStatus: nil), "Fast")
        XCTAssertEqual(AIModelsPane.subtitleText(state: partial, catalogSubtitle: nil, ramNote: "", downloadStatus: "Downloading 1 MB"),
                       "Downloading 1 MB")
    }

    @MainActor
    func testDownloadReadsAsResumeAndDeleteIsOfferedWhenPartial() {
        let partial = ModelFiles.DiskState(downloaded: false, sizeBytes: nil, partialBytes: 5)
        let none = ModelFiles.DiskState(downloaded: false, sizeBytes: nil)
        let done = ModelFiles.DiskState(downloaded: true, sizeBytes: 5)
        XCTAssertEqual(AIModelsPane.downloadButtonTitle(partial), "Resume")
        XCTAssertEqual(AIModelsPane.downloadButtonTitle(none), "Download")
        XCTAssertTrue(AIModelsPane.offersDelete(partial))
        XCTAssertTrue(AIModelsPane.offersDelete(done))
        XCTAssertFalse(AIModelsPane.offersDelete(none))
    }
}
