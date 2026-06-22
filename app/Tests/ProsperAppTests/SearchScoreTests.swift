import XCTest
@testable import ProsperApp

/// Unit tests for the unified launcher scorer. The key regression these lock
/// down: a real substring/prefix hit in any source must outrank a fuzzy
/// subsequence hit, so the launcher returns the SAME thing for "pods" and
/// "pods)" (the old exclusive source chain let a stray fuzzy app match shadow
/// an exact bookmark for one but not the other).
final class SearchScoreTests: XCTestCase {

    /// Helper mirroring the call sites: lowercases + tokenizes the query.
    private func score(_ query: String, _ matchText: String, tieLen: Int? = nil,
                       isAlias: Bool = false) -> Int? {
        let q = query.lowercased()
        let tokens = q.split(separator: " ").map(String.init)
        return SearchScore.score(q: q, tokens: tokens, matchText: matchText.lowercased(),
                                 tieLen: tieLen ?? matchText.count, isAlias: isAlias)
    }

    func testSubstringBeatsFuzzy() {
        let bookmark = score("pods", "GCC - Production (Kubernetes Pods) https://x", tieLen: 33)
        let fuzzyApp = score("pods", "Photo Booth Display Settings") // p-o-...-d-s subsequence
        XCTAssertNotNil(bookmark)
        XCTAssertNotNil(fuzzyApp)
        XCTAssertGreaterThan(bookmark!, fuzzyApp!, "real substring must outrank fuzzy")
    }

    func testTrailingParenMatchesSameAsBareToken() {
        // Both queries reduce to the token "pods" against the haystack → identical tier.
        let hay = "gcc - production (kubernetes pods)"
        XCTAssertEqual(score("pods", hay), score("pods)", hay))
    }

    func testTierOrder() {
        XCTAssertEqual(score("safari", "Safari"), 900 - 6)          // exact
        XCTAssertGreaterThan(score("saf", "Safari")!, score("ari", "Safari")!) // prefix > contains
        XCTAssertNil(score("zzz", "Safari"))                        // no match
    }

    func testMultiTokenAndSemantics() {
        let hay = "prod kubernetes console — https://k8s"
        XCTAssertNotNil(score("kubernetes prod", hay))   // both tokens present, scattered
        XCTAssertNil(score("kubernetes azure", hay))     // one token absent → no match
    }

    func testAliasTops() {
        XCTAssertEqual(score("settings", "System Settings", isAlias: true), 1000)
    }

    func testFuzzyTierIsLowest() {
        // "amr" is a subsequence of "activity monitor" but neither substring nor
        // word-prefix → fuzzy tier (200-…), strictly below any contains hit.
        let fuzzy = score("amr", "Activity Monitor")
        let contains = score("monitor", "Activity Monitor")
        XCTAssertNotNil(fuzzy)
        XCTAssertNotNil(contains)
        XCTAssertLessThan(fuzzy!, contains!)
        XCTAssertLessThan(fuzzy!, 300) // 200 - len, never reaches the 500 floor
    }

    func testLongTitleSubstringBeatsShortScattered() {
        // Regression: a real substring hit on a long (150-char) title must still
        // outrank a weaker scattered/short hit. Unclamped `base - tieLen` made
        // 600-150=450 lose to 500-10=490 (cross-tier leak).
        let longTitle = String(repeating: "x", count: 145) + " pods"
        let substring = score("pods", longTitle, tieLen: longTitle.count)   // contains tier
        let scattered = score("pods dash", "pods — dashboard", tieLen: 15)   // scattered tier (500)
        XCTAssertNotNil(substring)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(substring!, scattered!, "long substring hit must beat short scattered hit")
    }

    func testTieBreakStillFavorsShorterWithinTier() {
        // Clamp must not flatten the within-tier ordering for normal lengths.
        XCTAssertGreaterThan(score("git", "GitHub")!, score("git", "GitHub Desktop")!)
    }

    func testTieBreakAndKindOrder() {
        // Equal score → app sorts before quicklink before bookmark.
        let app = SearchHit(kind: .app, title: "X", subtitle: "", score: 600)
        let link = SearchHit(kind: .quicklink, title: "X", subtitle: "", score: 600)
        let bm = SearchHit(kind: .bookmark, title: "X", subtitle: "", score: 600)
        let sorted = [bm, link, app].sorted(by: SearchScore.before)
        XCTAssertEqual(sorted.map(\.kind), [.app, .quicklink, .bookmark])
    }

    // MARK: - Hot-path performance gate
    //
    // The unified launcher search runs (after a 0.25s debounce) on a query change.
    // Its dominant cost is scoring every candidate. Requirement: scoring a LARGE
    // realistic set — 800 apps + 4000 bookmark haystacks — must stay far under the
    // debounce and be imperceptible. Ceiling is generous (debug builds are ~10×
    // slower than release + CI is noisy); the test prints the real figure so a
    // regression that blows past it is caught. Typical real machines: <1ms.
    func testScoringLargeSetIsFast() {
        let apps = (0..<800).map { "Application Number \($0) Pro" }
        let bookmarks = (0..<4000).map {
            "ticket \($0) — production kubernetes pods dashboard https://example.com/path/\($0) work"
        }
        let q = "pods"
        let tokens = [q]

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            var hits = 0
            for a in apps {
                if SearchScore.score(q: q, tokens: tokens, matchText: a, tieLen: a.count) != nil { hits += 1 }
            }
            for b in bookmarks {
                if SearchScore.score(q: q, tokens: tokens, matchText: b, tieLen: 30) != nil { hits += 1 }
            }
            XCTAssertEqual(hits, 4000) // every bookmark matches "pods", no app does
        }
        let ms = Double(elapsed.components.attoseconds) / 1e15
        print("⏱  scored 4800 candidates in \(String(format: "%.3f", ms)) ms")
        XCTAssertLessThan(ms, 50, "scoring 4800 candidates should be well under the debounce")
    }
}
