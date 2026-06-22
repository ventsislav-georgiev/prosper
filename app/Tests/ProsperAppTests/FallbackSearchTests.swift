import XCTest
@testable import ProsperApp

@MainActor
final class FallbackSearchTests: XCTestCase {

    /// A store backed by an isolated, empty UserDefaults suite so tests never touch
    /// the real `fallback.*` keys.
    private func makeStore(append: Bool = true,
                           providers: [FallbackProvider]? = nil) -> FallbackSearchStore {
        let suite = UserDefaults(suiteName: "fallback-tests-\(UUID().uuidString)")!
        let store = FallbackSearchStore(defaults: suite)
        store.appendMode = append
        if let providers { store.providers = providers }
        return store
    }

    private func provider(_ id: String, enabled: Bool = true) -> FallbackProvider {
        FallbackProvider(id: id, name: id.capitalized,
                         urlTemplate: "https://x/search?q={query}", enabled: enabled,
                         titleTemplate: nil)
    }

    // MARK: expand()

    func testExpandPercentEncodesQuery() {
        let store = makeStore()
        let out = store.expand(template: "https://g/search?q={query}", query: "swift lang #1")
        XCTAssertEqual(out, "https://g/search?q=swift%20lang%20%231")
    }

    func testExpandEncodesQueryReservedChars() {
        let store = makeStore()
        // `&=+?/#` must be percent-encoded — otherwise they inject spurious params
        // or (for `+`) decode to a space at the engine, giving the wrong search.
        let out = store.expand(template: "https://g/s?q={query}", query: "x=1&y=2 c++")
        XCTAssertEqual(out, "https://g/s?q=x%3D1%26y%3D2%20c%2B%2B")
    }

    func testExpandPlusVariantUsesPluses() {
        let store = makeStore()
        let out = store.expand(template: "https://g/s?q={query+}", query: "two words")
        XCTAssertEqual(out, "https://g/s?q=two+words")
    }

    func testExpandLeavesTemplateWithoutPlaceholderUntouched() {
        let store = makeStore()
        XCTAssertEqual(store.expand(template: "https://g/", query: "anything"), "https://g/")
    }

    func testFirstRunSeedsFourDefaults() {
        let store = makeStore(append: true, providers: nil)
        let ids = store.providers.map { $0.id }
        XCTAssertEqual(ids, ["google", "perplexity", "wikipedia", "amazon"])
    }

    func testTitleDefaultAndOverride() {
        let store = makeStore()
        let p = provider("google")
        XCTAssertEqual(store.title(for: p, query: "swift"), "Search Google for \u{2018}swift\u{2019}")
        var custom = p
        custom.titleTemplate = "Go to {name}: {query}"
        XCTAssertEqual(store.title(for: custom, query: "x"), "Go to Google: x")
    }

    // MARK: fallbackRows decision helper

    func testNonUniversalModeGetsNoFallbacks() {
        let store = makeStore(providers: [provider("google")])
        let base: [ResultRow] = []
        let out = fallbackRows(base: base, outcome: .noResults(query: "q"), query: "q",
                               mode: .ext(id: "x", title: "X", icon: "i", arg: nil), store: store)
        XCTAssertTrue(out.isEmpty)
    }

    func testEmptyQueryGetsNoFallbacks() {
        let store = makeStore(providers: [provider("google")])
        let out = fallbackRows(base: [], outcome: .noResults(query: ""), query: "",
                               mode: .universal, store: store)
        XCTAssertTrue(out.isEmpty)
    }

    func testScalarOutcomesAreAMatchNoFallbacks() {
        let store = makeStore(providers: [provider("google")])
        let calc = fallbackRows(base: [.init(id: 0, icon: "f", primary: "4", secondary: "2+2",
                                             category: "Calculator", copyValue: "4", isMeta: false)],
                                outcome: .calc(expression: "2+2", value: "4"), query: "2+2",
                                mode: .universal, store: store)
        XCTAssertEqual(calc.count, 1)
        XCTAssertEqual(calc.first?.category, "Calculator")
    }

    func testNoResultsReplacedByFallbacks() {
        let store = makeStore(providers: [provider("google"), provider("bing")])
        let placeholder: [ResultRow] = [.init(id: 0, icon: "magnifyingglass", primary: "No results",
                                              secondary: "", category: "", copyValue: "", isMeta: false)]
        let out = fallbackRows(base: placeholder, outcome: .noResults(query: "zzz"), query: "zzz",
                               mode: .universal, store: store)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.map { $0.category }, ["Web Search", "Web Search"])
        XCTAssertEqual(out.first?.openTarget, "https://x/search?q=zzz")
    }

    func testAppendModeTacksFallbacksAfterRealResults() {
        let store = makeStore(append: true, providers: [provider("google")])
        let real: [ResultRow] = [.init(id: 0, icon: "app.dashed", primary: "Safari", secondary: "",
                                       category: "Application", copyValue: "Safari", isMeta: false)]
        let out = fallbackRows(base: real, outcome: .apps([]), query: "saf",
                               mode: .universal, store: store)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.first?.category, "Application")
        XCTAssertEqual(out.last?.category, "Web Search")
    }

    func testEmptyOnlyModeSkipsFallbacksWhenRealResultsExist() {
        let store = makeStore(append: false, providers: [provider("google")])
        let real: [ResultRow] = [.init(id: 0, icon: "app.dashed", primary: "Safari", secondary: "",
                                       category: "Application", copyValue: "Safari", isMeta: false)]
        let out = fallbackRows(base: real, outcome: .apps([]), query: "saf",
                               mode: .universal, store: store)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.category, "Application")
    }

    func testNonFreeTextOutcomesGetNoFallbacks() {
        // Allow-list is .search/.apps/.noResults only. Shell output, the emoji picker,
        // and extension-owned UI must NOT get a "Search Google for …" row appended.
        let store = makeStore(append: true, providers: [provider("google")])
        let real: [ResultRow] = [.init(id: 0, icon: "x", primary: "p", secondary: "",
                                       category: "C", copyValue: "v", isMeta: false)]
        for outcome in [RunnerOutcome.shell(command: "ls", output: "a\nb"),
                        .emoji(name: "fire", emoji: "🔥"),
                        .ext(kind: "k", value: "v", detail: "d")] {
            let out = fallbackRows(base: real, outcome: outcome, query: "x",
                                   mode: .universal, store: store)
            XCTAssertEqual(out.count, 1, "\(outcome) should pass base through unchanged")
            XCTAssertFalse(out.contains { $0.category == "Web Search" },
                           "\(outcome) must not get a Web Search fallback")
        }
    }

    func testSearchOutcomeGetsFallbacks() {
        let store = makeStore(append: true, providers: [provider("google")])
        let real: [ResultRow] = [.init(id: 0, icon: "x", primary: "hit", secondary: "",
                                       category: "Search", copyValue: "v", isMeta: false)]
        let out = fallbackRows(base: real, outcome: .search([]), query: "x",
                               mode: .universal, store: store)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.last?.category, "Web Search")
    }

    // MARK: sanitized() write choke point

    func testSanitizedDropsGarbageAndDedupes() {
        let good = provider("google")
        let dupGoogle = FallbackProvider(id: "google", name: "Google 2",
                                         urlTemplate: "https://y/?q={query}", enabled: true,
                                         titleTemplate: nil)
        let noID = FallbackProvider(id: "", name: "X",
                                    urlTemplate: "https://x/?q={query}", enabled: true, titleTemplate: nil)
        let noName = FallbackProvider(id: "x", name: "",
                                      urlTemplate: "https://x/?q={query}", enabled: true, titleTemplate: nil)
        let noPlaceholder = FallbackProvider(id: "bad", name: "Bad",
                                             urlTemplate: "https://x/", enabled: true, titleTemplate: nil)
        let plusOK = FallbackProvider(id: "plus", name: "Plus",
                                      urlTemplate: "https://x/?q={query+}", enabled: true, titleTemplate: nil)
        let out = FallbackSearchStore.sanitized([good, dupGoogle, noID, noName, noPlaceholder, plusOK])
        XCTAssertEqual(out.map { $0.id }, ["google", "plus"], "first-id wins, garbage + no-placeholder dropped")
    }

    func testSanitizedRejectsNonHttpSchemes() {
        // host.fallback.save trust boundary: a non-http(s) template must never reach
        // the NSWorkspace open sink as a one-key launcher.
        let danger = [
            FallbackProvider(id: "js", name: "JS", urlTemplate: "javascript:alert({query})",
                             enabled: true, titleTemplate: nil),
            FallbackProvider(id: "file", name: "File", urlTemplate: "file:///etc/{query}",
                             enabled: true, titleTemplate: nil),
            FallbackProvider(id: "deep", name: "Deep", urlTemplate: "myapp://x/{query}",
                             enabled: true, titleTemplate: nil),
            provider("ok"),  // https — survives
        ]
        XCTAssertEqual(FallbackSearchStore.sanitized(danger).map { $0.id }, ["ok"])
    }

    func testSanitizedClampsToMaxProviders() {
        let many = (0 ..< (FallbackSearchStore.maxProviders + 25)).map { provider("p\($0)") }
        XCTAssertEqual(FallbackSearchStore.sanitized(many).count, FallbackSearchStore.maxProviders)
    }

    func testSaveGoesThroughSanitizer() {
        // host.fallback.save is a Lua → native trust boundary; the store must clean it.
        let store = makeStore(providers: [])
        store.providers = [provider("a"), provider("a"),
                           FallbackProvider(id: "b", name: "B", urlTemplate: "https://b/",
                                            enabled: true, titleTemplate: nil)]
        XCTAssertEqual(store.providers.map { $0.id }, ["a"], "dup dropped, no-placeholder 'b' dropped")
    }

    func testSetProvidersJSONEmptyObjectClears() {
        // Delete-last from Lua: an empty table encodes as `{}` (object), not `[]`.
        let store = makeStore(providers: [provider("google")])
        store.setProvidersJSON("{}")
        XCTAssertTrue(store.providers.isEmpty, "empty object must clear, not no-op")
    }

    func testSetProvidersJSONEmptyArrayClears() {
        let store = makeStore(providers: [provider("google")])
        store.setProvidersJSON("[]")
        XCTAssertTrue(store.providers.isEmpty)
    }

    func testSetProvidersJSONMalformedKeepsCurrent() {
        let store = makeStore(providers: [provider("google")])
        store.setProvidersJSON("not json at all")
        XCTAssertEqual(store.providers.map { $0.id }, ["google"], "malformed input keeps current")
    }

    func testDisabledProvidersAreSkipped() {
        let store = makeStore(providers: [provider("google", enabled: false), provider("bing")])
        let out = fallbackRows(base: [], outcome: .noResults(query: "q"), query: "q",
                               mode: .universal, store: store)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.primary, "Search Bing for \u{2018}q\u{2019}")
    }

    // MARK: hot-path budgets
    //
    // `fallbackRows` runs inside the SwiftUI `rows` getter (every keystroke + every
    // arrow-key selection change, read several times per body pass). Warm runs land
    // ~10–15µs (4 providers × expand + title + 12 ResultRow allocations); the ceiling
    // is set with ~3× headroom so CI noise can't flake a µs-level bound. The number is
    // printed for tracking — these assert the order of magnitude, not a tight bound.

    func testFallbackRowsHotPathBudget() {
        // 4 enabled providers (the shipped default count) + a realistic 8-hit base,
        // append mode — the worst case the getter sees on a normal keystroke.
        let store = makeStore(providers: FallbackSearchStore.seeded)
        let base: [ResultRow] = (0 ..< 8).map {
            .init(id: $0, icon: "app.dashed", primary: "Result \($0)", secondary: "",
                  category: "Application", copyValue: "r\($0)", isMeta: false)
        }
        let n = 100_000
        // Warm the cached provider read + percent-encoder fast path before timing.
        _ = fallbackRows(base: base, outcome: .apps([]), query: "warm up",
                         mode: .universal, store: store)
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0 ..< n {
            _ = fallbackRows(base: base, outcome: .apps([]), query: "query \(i % 97)",
                             mode: .universal, store: store)
        }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n)
        print("fallbackRows: \(String(format: "%.0f", perCall)) ns/call")
        XCTAssertLessThan(perCall, 45_000, "fallbackRows exceeded the 45µs hot-path budget")
    }

    func testExpandHotPathBudget() {
        let store = makeStore()
        let n = 200_000
        _ = store.expand(template: "https://www.google.com/search?q={query}", query: "warm")
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0 ..< n {
            _ = store.expand(template: "https://www.google.com/search?q={query}",
                             query: "swift concurrency \(i % 89)")
        }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n)
        print("expand: \(String(format: "%.0f", perCall)) ns/call")
        // Per-provider sub-cost: must stay well under the row budget / provider count.
        XCTAssertLessThan(perCall, 5_000, "expand exceeded the 5µs per-provider budget")
    }
}
