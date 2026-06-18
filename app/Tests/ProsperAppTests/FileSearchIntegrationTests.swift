import XCTest
@testable import ProsperApp

/// An in-memory `FileIndex` — the mocked file system for file-search integration
/// tests. It applies exactly the engine's filter semantics (`FileSearchEngine.matches`)
/// plus the `in:` scope (path prefix), so a search runs end to end (query → filter →
/// rank) with no live Spotlight index. Internal (not private) so the host-level Lua
/// tests in `ExtensionHostAPITests` can reuse it.
final class MockFileIndex: FileIndex, @unchecked Sendable {
    let files: [FileSearchEngine.IndexedFile]
    init(_ files: [FileSearchEngine.IndexedFile]) { self.files = files }

    func gather(_ q: FileSearchEngine.FileQuery, limit: Int) async -> [FileSearchEngine.Candidate] {
        let home = NSHomeDirectory()
        return files
            .filter { $0.path == q.scope || $0.path.hasPrefix(q.scope + "/") }  // in: scope
            .filter { FileSearchEngine.matches($0, q) }
            .prefix(limit)
            .map { $0.candidate(home: home) }
    }
}

/// Search + filtration integration tests across file formats, over `MockFileIndex`.
/// Drives the real `FileSearchEngine.search` pipeline (guard → index → rank), so
/// filter semantics, format handling, scopes, and frecency ranking are all covered
/// without a live Spotlight index.
final class FileSearchIntegrationTests: XCTestCase {

    private let now: TimeInterval = 1_700_000_000
    private static let home = NSHomeDirectory()

    /// A fresh, empty frecency store (no cross-test leakage).
    private func emptyFrecency() -> FrecencyStore {
        let suite = "filesearch-frecency-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return FrecencyStore(defaults: d, storageKey: "k")
    }

    private func file(_ rel: String, tree: [String], kind: String,
                      content: String = "", isDir: Bool = false,
                      modified: TimeInterval = 0) -> FileSearchEngine.IndexedFile {
        FileSearchEngine.IndexedFile(
            path: "\(Self.home)/\(rel)", contentTypeTree: tree, textContent: content,
            isDir: isDir, kind: kind, size: 0, modified: modified)
    }

    /// A mixed-format corpus exercised by the format/filter tests.
    private func corpus() -> [FileSearchEngine.IndexedFile] {
        [
            file("Documents/Q3 Report.pdf", tree: ["com.adobe.pdf", "public.data"],
                 kind: "PDF document", modified: 300),
            file("Documents/Q3 chart.png", tree: ["public.png", "public.image"],
                 kind: "PNG image", modified: 250),
            file("Pictures/holiday.jpg", tree: ["public.jpeg", "public.image"],
                 kind: "JPEG image", modified: 200),
            file("Projects", tree: ["public.folder"], kind: "Folder", isDir: true, modified: 150),
            file("notes/todo.md", tree: ["net.daringfireball.markdown", "public.text"],
                 kind: "Markdown text", content: "buy milk and finalize the Q3 budget", modified: 275),
            file("Movies/clip.mov", tree: ["com.apple.quicktime-movie", "public.movie"],
                 kind: "QuickTime movie", modified: 100),
            file("Archives/backup.zip", tree: ["public.zip-archive", "public.archive"],
                 kind: "ZIP archive", modified: 75),
        ]
    }

    private func search(_ q: FileSearchEngine.FileQuery,
                        in files: [FileSearchEngine.IndexedFile],
                        frecency: FrecencyStore? = nil) async -> [FileSearchEngine.FileHit] {
        await FileSearchEngine.search(q, index: MockFileIndex(files),
                                      frecency: frecency ?? emptyFrecency(), now: now)
    }

    // MARK: name search across formats

    func testNameSearchMatchesEveryFormatWithThatName() async {
        var q = FileSearchEngine.FileQuery(); q.name = "Q3"
        let hits = await search(q, in: corpus())
        // Both "Q3 …" files match by name (pdf + png) at the same prefix tier; the
        // shorter name wins the tiebreak (before recency), so the png leads the pdf.
        XCTAssertEqual(hits.map(\.name), ["Q3 chart.png", "Q3 Report.pdf"])
    }

    func testTooShortBareNameReturnsNothing() async {
        var q = FileSearchEngine.FileQuery(); q.name = "Q"  // 1 char, no filter
        let hits = await search(q, in: corpus())
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: kind filters

    func testKindPDFOnly() async {
        var q = FileSearchEngine.FileQuery(); q.name = "Q3"; q.kinds = ["pdf"]
        let hits = await search(q, in: corpus())
        XCTAssertEqual(hits.map(\.name), ["Q3 Report.pdf"])
    }

    func testKindImageMatchesPngAndJpeg() async {
        var q = FileSearchEngine.FileQuery(); q.kinds = ["image"]  // filter-only
        let names = await search(q, in: corpus()).map(\.name)
        XCTAssertEqual(Set(names), ["Q3 chart.png", "holiday.jpg"])  // both public.image
        XCTAssertFalse(names.contains("Q3 Report.pdf"))
    }

    func testKindFolderOnly() async {
        var q = FileSearchEngine.FileQuery(); q.kinds = ["folder"]  // filter-only
        let hits = await search(q, in: corpus())
        XCTAssertEqual(hits.map(\.name), ["Projects"])
        XCTAssertTrue(hits.first?.isDir == true)
    }

    func testKindVideoOnly() async {
        var q = FileSearchEngine.FileQuery(); q.kinds = ["video"]
        let names = await search(q, in: corpus()).map(\.name)
        XCTAssertEqual(names, ["clip.mov"])
    }

    // MARK: ext filters

    func testExtPngOnly() async {
        var q = FileSearchEngine.FileQuery(); q.exts = ["png"]
        let names = await search(q, in: corpus()).map(\.name)
        XCTAssertEqual(names, ["Q3 chart.png"])
    }

    func testExtAcceptsLeadingDotAndIsCaseInsensitive() async {
        var q = FileSearchEngine.FileQuery(); q.exts = [".PDF".lowercased()]  // decode lowercases
        let names = await search(q, in: corpus()).map(\.name)
        XCTAssertEqual(names, ["Q3 Report.pdf"])
    }

    func testUnknownKindFallsBackToExtension() async {
        // "mov" is not a known kind → treated as an extension filter.
        var q = FileSearchEngine.FileQuery(); q.kinds = ["mov"]
        let names = await search(q, in: corpus()).map(\.name)
        XCTAssertEqual(names, ["clip.mov"])
    }

    func testKindAndExtMustBothMatch() async {
        // kind:image AND ext:jpg → only the jpeg, not the png.
        var q = FileSearchEngine.FileQuery(); q.kinds = ["image"]; q.exts = ["jpg"]
        let names = await search(q, in: corpus()).map(\.name)
        XCTAssertEqual(names, ["holiday.jpg"])
    }

    // MARK: content search

    func testContentSearchFindsByBodyText() async {
        var q = FileSearchEngine.FileQuery(); q.name = "milk"; q.content = true
        let names = await search(q, in: corpus()).map(\.name)
        XCTAssertEqual(names, ["todo.md"])
    }

    func testNameSearchDoesNotMatchBodyTextWithoutContentFlag() async {
        var q = FileSearchEngine.FileQuery(); q.name = "milk"  // content = false
        let hits = await search(q, in: corpus())
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: in: scope

    func testScopeRestrictsToSubtree() async {
        var q = FileSearchEngine.FileQuery()
        q.name = "Q3"
        q.scope = "\(Self.home)/Documents"
        let names = await search(q, in: corpus()).map(\.name)
        XCTAssertEqual(Set(names), ["Q3 Report.pdf", "Q3 chart.png"])  // both under Documents

        var elsewhere = q; elsewhere.scope = "\(Self.home)/Pictures"
        let elsewhereHits = await search(elsewhere, in: corpus())
        XCTAssertTrue(elsewhereHits.isEmpty)  // no Q3 under Pictures
    }

    // MARK: ranking + frecency

    func testRecencyOrdersSameTierMatches() async {
        let files = [
            file("a/report.pdf", tree: ["com.adobe.pdf"], kind: "PDF", modified: 100),
            file("b/report.pdf", tree: ["com.adobe.pdf"], kind: "PDF", modified: 200),
        ]
        var q = FileSearchEngine.FileQuery(); q.name = "report"
        let hits = await search(q, in: files)
        XCTAssertEqual(hits.map(\.path), ["\(Self.home)/b/report.pdf", "\(Self.home)/a/report.pdf"])
    }

    func testFrecencyLiftsMatchAboveMoreRecentOne() async {
        let files = [
            file("a/report.pdf", tree: ["com.adobe.pdf"], kind: "PDF", modified: 100),  // older
            file("b/report.pdf", tree: ["com.adobe.pdf"], kind: "PDF", modified: 200),  // newer
        ]
        let frecency = emptyFrecency()
        frecency.record(path: "\(Self.home)/a/report.pdf", now: now)  // engage the older one

        var q = FileSearchEngine.FileQuery(); q.name = "report"
        let hits = await search(q, in: files, frecency: frecency)
        // Same name tier, so frecency wins over recency: the engaged file leads.
        XCTAssertEqual(hits.first?.path, "\(Self.home)/a/report.pdf")
    }

    func testExactNameBeatsPrefixWhichBeatsSubstring() async {
        let files = [
            file("x/report.pdf", tree: ["com.adobe.pdf"], kind: "PDF"),         // prefix of "report"? exact stem
            file("x/report-archive.pdf", tree: ["com.adobe.pdf"], kind: "PDF"), // prefix
            file("x/my-report.pdf", tree: ["com.adobe.pdf"], kind: "PDF"),      // substring
        ]
        var q = FileSearchEngine.FileQuery(); q.name = "report"
        let names = await search(q, in: files).map(\.name)
        // "report.pdf" (tier: prefix, shortest) leads; "my-report.pdf" (substring) trails.
        XCTAssertEqual(names.first, "report.pdf")
        XCTAssertEqual(names.last, "my-report.pdf")
    }

    func testLimitIsRespected() async {
        let files = (0..<40).map { file("bulk/report\($0).pdf", tree: ["com.adobe.pdf"], kind: "PDF") }
        var q = FileSearchEngine.FileQuery(); q.name = "report"; q.limit = 5
        let hits = await search(q, in: files)
        XCTAssertEqual(hits.count, 5)
    }

    // MARK: JSON shape

    func testSearchJSONEncodesHitFields() async {
        var q = FileSearchEngine.FileQuery(); q.name = "Q3"; q.kinds = ["pdf"]
        let json = await FileSearchEngine.searchJSON(q, index: MockFileIndex(corpus()),
                                                     frecency: emptyFrecency(), now: now)
        let arr = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        XCTAssertEqual(arr.count, 1)
        let row = arr[0]
        XCTAssertEqual(row["name"] as? String, "Q3 Report.pdf")
        XCTAssertEqual(row["display"] as? String, "~/Documents/Q3 Report.pdf")
        XCTAssertEqual(row["kind"] as? String, "PDF document")
        XCTAssertEqual(row["isDir"] as? Bool, false)
    }
}
