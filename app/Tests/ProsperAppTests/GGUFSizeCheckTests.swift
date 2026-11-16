import XCTest
@testable import ProsperApp

/// #1300: the exists-only GGUF checks left by #1040 now use the exact-size rule, and Resume
/// re-checks the size right before it deletes. Every file is a small fake in tempDir(), every
/// registry entry a fake, every fetch an injected recorder or a file:// URL that cannot download:
/// no network, no real model dir, no model load.
@MainActor
final class GGUFSizeCheckTests: XCTestCase {
    private var dir: URL!
    private let registered = "unsloth/Qwen3.5-4B-GGUF"   // an id the registry knows; only its id is used

    override func setUpWithError() throws {
        dir = tempDir("gguf1300")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ name: String, bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    private func model(bytes: Int64) -> LlamaInlineEngine.CatalogModel {
        .init(id: "fake", label: "Fake", detail: "d", fileName: "fake.gguf",
              downloadURL: URL(string: "file:///nonexistent/fake.gguf")!, bytes: bytes)
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    // MARK: site 1, inline autocomplete

    func testInlineIsDownloadedOnlyAtTheCatalogSize() throws {
        let m = model(bytes: 40)
        XCTAssertFalse(LlamaInlineEngine.isDownloaded(m, at: try file("short", bytes: 10)))
        XCTAssertTrue(LlamaInlineEngine.isDownloaded(m, at: try file("exact", bytes: 40)))
        XCTAssertFalse(LlamaInlineEngine.isDownloaded(m, at: try file("long", bytes: 50)))
        XCTAssertFalse(LlamaInlineEngine.isDownloaded(m, at: dir.appendingPathComponent("missing")))
    }

    /// Sparse temp file of `bytes` (no data written; the real catalog sizes are GB).
    private func sparse(_ name: String, bytes: Int64) throws -> URL {
        let url = dir.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(bytes))
        try h.close()
        return url
    }

    func testInlineAcceptsTheLegacyMainSizesAndRejectsOneByteOff() throws {
        let legacy: [String: Int64] = ["e2b-q4": 3_349_514_112, "e2b-q8": 4_967_494_592,
                                       "e4b-q4": 5_154_939_136, "e4b-q8": 8_031_240_160]
        XCTAssertEqual(LlamaInlineEngine.catalog.count, legacy.count)
        for m in LlamaInlineEngine.catalog {
            let size = try XCTUnwrap(legacy[m.id])
            XCTAssertTrue(LlamaInlineEngine.isDownloaded(m, at: try sparse("\(m.id)-legacy", bytes: size)), m.id)
            XCTAssertTrue(LlamaInlineEngine.isDownloaded(m, at: try sparse("\(m.id)-pinned", bytes: m.bytes)), m.id)
            XCTAssertFalse(LlamaInlineEngine.isDownloaded(m, at: try sparse("\(m.id)-minus", bytes: size - 1)), m.id)
            XCTAssertFalse(LlamaInlineEngine.isDownloaded(m, at: try sparse("\(m.id)-plus", bytes: size + 1)), m.id)
            XCTAssertTrue(LlamaInlineEngine.modelFileIsReady(m, path: try sparse("\(m.id)-legacy2", bytes: size), envOverride: false), m.id)
        }
    }

    func testInlineReadyCheckKeepsExistsOnlyOnlyForTheBenchOverride() throws {
        let m = model(bytes: 40)
        let short = try file("short", bytes: 10)
        XCTAssertFalse(LlamaInlineEngine.modelFileIsReady(m, path: short, envOverride: false))
        XCTAssertTrue(LlamaInlineEngine.modelFileIsReady(m, path: short, envOverride: true))
        XCTAssertTrue(LlamaInlineEngine.modelFileIsReady(m, path: try file("exact", bytes: 40), envOverride: false))
    }

    func testInlineDownloadOfATruncatedFileIsNotAnsweredDownloaded() async throws {
        let m = model(bytes: 40)
        let short = try file("short", bytes: 10)
        let log = Log()
        do {
            try await LlamaInlineEngine.downloadModel(m, to: short) { _, s in log.add(s) }
            XCTFail("a truncated file was treated as present")
        } catch {}
        XCTAssertFalse(log.all.contains("Downloaded."))
        let exact = try file("exact", bytes: 40)
        try await LlamaInlineEngine.downloadModel(m, to: exact) { _, s in log.add(s) }
        XCTAssertEqual(log.all.last, "Downloaded.")
    }

    // MARK: site 2, GGUFDownload.fetch

    func testFetchAnswersDownloadedOnlyAtTheExpectedSize() async throws {
        let url = URL(string: "file:///nonexistent/x.gguf")!
        let log = Log()
        let short = try file("short", bytes: 10)
        do {
            try await GGUFDownload.fetch(url: url, dest: short, expectedBytes: 40) { _, s in log.add(s) }
            XCTFail("a truncated file was treated as present")
        } catch {}
        XCTAssertFalse(log.all.contains("Downloaded."))
        let exact = try file("exact", bytes: 40)
        try await GGUFDownload.fetch(url: url, dest: exact, expectedBytes: 40) { _, s in log.add(s) }
        XCTAssertEqual(log.all.last, "Downloaded.")
    }

    // MARK: site 3, agent engine

    func testAgentEnsureModelFetchesATruncatedFileAndNeverLoadsAWrongSizeOne() async throws {
        let spec = AgentGGUF(fileName: "fake.gguf", downloadURL: URL(string: "file:///nonexistent/f.gguf")!, bytes: 40)
        let short = try file("short", bytes: 10)
        let fetched = Log()
        // The fake fetch leaves the file as it was (a failed replace): the engine must refuse it.
        let fake: GGUFDownload.Fetch = { _, _, _, _ in fetched.add("fetch") }
        do {
            try await LlamaAgentEngine().ensureModel(spec, dest: short, fetch: fake) { _, _ in }
            XCTFail("a wrong-size file was handed to the loader")
        } catch let e as LlamaAgentEngine.EngineError {
            guard case .modelMissing = e else { return XCTFail("\(e)") }
        }
        XCTAssertEqual(fetched.all, ["fetch"])
    }

    // MARK: R1040-n1, Resume

    private func lookup(_ url: URL, bytes: Int64) -> ModelFiles.GGUFLookup {
        { [rid = registered] id in id == rid ? (url: url, bytes: bytes) : nil }
    }

    func testResumeKeepsAFileThatIsAtTheRegisteredSizeByTheTimeTheTaskRuns() async throws {
        let good = try file("good", bytes: 40)
        let before = try Data(contentsOf: good)
        let fetched = Log()
        let m = ModelDownloadManager()
        // isDownloaded says "not downloaded", as a later-loosened guard or a race would.
        m.start(registered, gguf: lookup(good, bytes: 40), isDownloaded: { _ in false },
                fetch: { _, _, _, _ in fetched.add("fetch") })
        await m.waitForTask()
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.path))
        XCTAssertTrue(try Data(contentsOf: good) == before)
        XCTAssertEqual(fetched.all, [])
        XCTAssertTrue(m.activeModelId == nil)
    }

    func testResumeStillClearsAWrongSizeFileAndFetches() async throws {
        let bad = try file("bad", bytes: 10)
        let fetched = Log()
        let m = ModelDownloadManager()
        m.start(registered, gguf: lookup(bad, bytes: 40), isDownloaded: { _ in false },
                fetch: { _, dest, _, _ in
                    // The leftover is gone before the fetch is asked to run.
                    fetched.add(FileManager.default.fileExists(atPath: dest.path) ? "leftover" : "clean")
                })
        await m.waitForTask()
        XCTAssertEqual(fetched.all, ["clean"])
    }
}
