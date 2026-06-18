import XCTest
@testable import ProsperApp

/// Unit coverage for `FileSearchEngine`'s pure helpers — name tiers, ranking with
/// frecency, the Spotlight `NSPredicate` builder + scopes, query decoding, and `~`
/// abbreviation. The live `NSMetadataQuery` gather (`FileSpotlight`) is exercised by
/// QA / e2e (it needs a live Spotlight index); everything deterministic is here.
final class FileSearchEngineTests: XCTestCase {

    private func hit(_ name: String, _ path: String, isDir: Bool = false,
                     modified: TimeInterval = 0) -> FileSearchEngine.FileHit {
        FileSearchEngine.FileHit(name: name, path: path, display: path, isDir: isDir,
                                 kind: "File", size: 0, modified: modified)
    }

    private func cand(_ name: String, _ path: String, modified: TimeInterval = 0)
        -> FileSearchEngine.Candidate {
        FileSearchEngine.Candidate(hit: hit(name, path, modified: modified))
    }

    // MARK: tier

    func testTierOrdersExactPrefixWordSubstringFloor() {
        XCTAssertEqual(FileSearchEngine.tier(name: "report", query: "report"), 4)
        XCTAssertEqual(FileSearchEngine.tier(name: "report-2024.pdf", query: "report"), 3)
        XCTAssertEqual(FileSearchEngine.tier(name: "q3-report.pdf", query: "report"), 2)  // word-prefix
        XCTAssertEqual(FileSearchEngine.tier(name: "myreport.pdf", query: "report"), 1)   // substring
        XCTAssertEqual(FileSearchEngine.tier(name: "summary.pdf", query: "report"), 0)    // floor
    }

    func testTierBlankQueryIsUniform() {
        // A filter-only search (no name) gives every candidate the same tier.
        XCTAssertEqual(FileSearchEngine.tier(name: "anything", query: ""), 0)
    }

    // MARK: rank

    func testRankPrefersTierThenFrecencyThenLengthThenRecency() {
        let cands = [
            cand("summary.pdf", "/a/summary.pdf", modified: 100),     // floor tier
            cand("report-archive.pdf", "/a/report-archive.pdf"),      // prefix, no frecency
            cand("report.pdf", "/a/report.pdf"),                      // prefix, frecent
        ]
        let boosts = ["/a/report.pdf": 5.0]
        let ranked = FileSearchEngine.rank(cands, query: "report", boosts: boosts)
        // "report.pdf" (prefix + frecency) first, then "report-archive.pdf" (prefix),
        // then "summary.pdf" (floor).
        XCTAssertEqual(ranked.map(\.name), ["report.pdf", "report-archive.pdf", "summary.pdf"])
    }

    func testRankFrecencyOnlyReordersWithinTier() {
        // Frecency must not pull a substring match above an exact/prefix one.
        let cands = [
            cand("notes-old.txt", "/a/notes-old.txt"),  // prefix, no boost
            cand("my-notes.txt", "/a/my-notes.txt"),    // substring, huge boost
        ]
        let ranked = FileSearchEngine.rank(cands, query: "notes",
                                           boosts: ["/a/my-notes.txt": 999])
        XCTAssertEqual(ranked.first?.name, "notes-old.txt")
    }

    func testRankTrimsToLimit() {
        let cands = (0..<30).map { cand("file\($0).txt", "/a/file\($0).txt") }
        XCTAssertEqual(FileSearchEngine.rank(cands, query: "file", boosts: [:], limit: 5).count, 5)
    }

    // MARK: buildPredicate (NSMetadataQuery NSPredicate; format asserted by substring)

    func testPredicateNameOnlyAndsWordsOverDisplayName() {
        var q = FileSearchEngine.FileQuery(); q.name = "report 2024"
        let f = FileSearchEngine.buildPredicate(q)!.predicateFormat
        XCTAssertTrue(f.contains("kMDItemDisplayName"))
        XCTAssertTrue(f.contains("LIKE[cd]"))
        XCTAssertTrue(f.contains("report"))
        XCTAssertTrue(f.contains("2024"))
        XCTAssertTrue(f.contains("AND"))                 // words AND-ed
        XCTAssertFalse(f.contains("kMDItemTextContent"))  // no content search
    }

    func testPredicateContentBroadensToTextContent() {
        var q = FileSearchEngine.FileQuery(); q.name = "todo"; q.content = true
        let f = FileSearchEngine.buildPredicate(q)!.predicateFormat
        XCTAssertTrue(f.contains("kMDItemDisplayName"))
        XCTAssertTrue(f.contains("kMDItemTextContent"))
        XCTAssertTrue(f.contains("OR"))  // name OR content per word
    }

    func testPredicateKnownKindMapsToContentTypeTree() {
        var q = FileSearchEngine.FileQuery(); q.name = "x"; q.kinds = ["image", "pdf"]
        let f = FileSearchEngine.buildPredicate(q)!.predicateFormat
        XCTAssertTrue(f.contains("kMDItemContentTypeTree"))
        XCTAssertTrue(f.contains("public.image"))
        XCTAssertTrue(f.contains("com.adobe.pdf"))
        XCTAssertTrue(f.contains("AND"))  // name AND kinds
        XCTAssertTrue(f.contains("OR"))   // kinds OR-ed
    }

    func testPredicateExtAndUnknownKindBecomeExtensionMatch() {
        var q = FileSearchEngine.FileQuery()
        q.exts = ["png"]; q.kinds = ["sketch"]  // "sketch" is not a known kind
        let f = FileSearchEngine.buildPredicate(q)!.predicateFormat
        XCTAssertTrue(f.contains("kMDItemFSName"))
        XCTAssertTrue(f.contains("png"))
        XCTAssertTrue(f.contains("sketch"))
        XCTAssertFalse(f.contains("kMDItemContentTypeTree"))  // unknown kind → ext, not a tree
    }

    func testPredicateNilWhenNothingToSearch() {
        XCTAssertNil(FileSearchEngine.buildPredicate(FileSearchEngine.FileQuery()))
    }

    func testSearchScopesDefaultsToHomeAndHonorsIn() {
        XCTAssertEqual(FileSearchEngine.searchScopes(FileSearchEngine.FileQuery()),
                       [FileSearchEngine.defaultScope])
        var q = FileSearchEngine.FileQuery()
        q.scope = "/Users/me/Documents"
        XCTAssertEqual(FileSearchEngine.searchScopes(q), ["/Users/me/Documents"])
    }

    // MARK: FileQuery.decode

    func testQueryDecodeReadsAllFields() {
        let json = """
        { "name": "  budget ", "kind": "pdf", "ext": ["png","jpg"], "in": "~/Documents",
          "content": true, "limit": 5 }
        """
        let q = FileSearchEngine.FileQuery.decode(json: json)
        XCTAssertEqual(q.name, "budget")
        XCTAssertEqual(q.kinds, ["pdf"])
        XCTAssertEqual(q.exts, ["png", "jpg"])
        XCTAssertEqual(q.scope, (("~/Documents") as NSString).expandingTildeInPath)
        XCTAssertTrue(q.content)
        XCTAssertEqual(q.limit, 5)
    }

    func testQueryDecodeDefaultsAndStringOrArrayKind() {
        let q = FileSearchEngine.FileQuery.decode(json: "{}")
        XCTAssertEqual(q.name, "")
        XCTAssertEqual(q.scope, FileSearchEngine.defaultScope)  // home by default
        XCTAssertFalse(q.content)
        // A bare string kind decodes the same as a single-element array.
        let q2 = FileSearchEngine.FileQuery.decode(json: "{\"kind\":\"Image\"}")
        XCTAssertEqual(q2.kinds, ["image"])  // lowercased
    }

    func testQueryDecodeClampsLimit() {
        let q = FileSearchEngine.FileQuery.decode(json: "{\"name\":\"x\",\"limit\":9999}")
        XCTAssertEqual(q.limit, FileSearchEngine.maxResults)
    }

    // MARK: abbreviate

    func testAbbreviateHomeToTilde() {
        XCTAssertEqual(FileSearchEngine.abbreviate("/Users/me/Docs/x.txt", home: "/Users/me"),
                       "~/Docs/x.txt")
        XCTAssertEqual(FileSearchEngine.abbreviate("/Users/me", home: "/Users/me"), "~")
        XCTAssertEqual(FileSearchEngine.abbreviate("/Applications/Safari.app", home: "/Users/me"),
                       "/Applications/Safari.app")
        XCTAssertEqual(FileSearchEngine.abbreviate("/Users/meadow/x", home: "/Users/me"),
                       "/Users/meadow/x")
    }
}
