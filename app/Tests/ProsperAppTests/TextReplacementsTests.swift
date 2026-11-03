import LuaRuntime
import XCTest
@testable import ProsperApp

/// #732: the macOS Text Replacements as a read-only snippet source. The dictionary always comes
/// through the `TextReplacements.read` seam or as a value: no test calls the real NSSpellChecker.
@MainActor
final class TextReplacementsTests: XCTestCase {
    private var savedRead: (@MainActor () -> [String: String])!

    override func setUp() async throws {
        savedRead = TextReplacements.read
        Preferences.defaults.removeObject(forKey: "snippetsTextReplacements")
    }

    override func tearDown() async throws {
        TextReplacements.read = { [:] }
        TextReplacements.refresh()   // empty the cache for the next test
        TextReplacements.read = savedRead
        Preferences.defaults.removeObject(forKey: "snippetsTextReplacements")
    }

    private static let reps = ["omw": "On my way {date}{cursor} {argument name=\"who\"}", "sig": "Best, V"]

    private func plan(_ buffer: String, _ keywords: [(trigger: String, id: String)],
                      _ lookup: (String) -> SnippetHit?, wordBoundary: Bool = false) -> SnippetExpansionDecision {
        SnippetExpander.plan(buffer: buffer, keywords: keywords, lookup: lookup,
                             context: PlaceholderContext(), wordBoundaryMode: wordBoundary)
    }

    // MARK: - Literal insert (the double-fire analysis' unit check)

    func testReplacementInsertsLiterallyWithThePlainSnippetShape() {
        let keywords = PhoneSnippetStore.triggers(mac: [], macKeywords: [], sets: [], replacements: Self.reps)
        let lookup: (String) -> SnippetHit? = { PhoneSnippetStore.lookup($0, mac: { _ in nil }, replacements: Self.reps) }
        let phrase = Self.reps["omw"]!
        for wordBoundary in [false, true] {
            XCTAssertEqual(plan("x omw ", keywords, lookup, wordBoundary: wordBoundary),
                           .insertPlain(name: phrase, backspaces: 3, insertText: phrase + " ", leftArrows: 0),
                           "{date}, {cursor} and a required {argument} stay as typed; no left arrows; the delimiter "
                           + "is re-typed (wordBoundary \(wordBoundary))")
        }
        // Same backspace and insert shape as a plain Mac snippet with that keyword and plain text,
        // which fires the way a replacement always does: at a word boundary.
        let mac = SnippetHit(name: "Sig", keyword: "sig", text: "Best, V")
        let macPlan = plan("x sig ", [("sig", "Sig")], { $0 == "Sig" ? mac : nil }, wordBoundary: true)
        let repPlan = plan("x sig ", keywords, lookup)
        guard case let .insertPlain(_, mb, mt, ml) = macPlan, case let .insertPlain(_, rb, rt, rl) = repPlan
        else { return XCTFail("both fire: \(macPlan) \(repPlan)") }
        XCTAssertEqual([mb, ml], [rb, rl])
        XCTAssertEqual(mt, rt)
    }

    // MARK: - Clash order: Mac, then phones, then Text Replacements

    func testMacThenPhoneThenReplacement() {
        let s = PhoneSnippetStore(url: tempDir().appendingPathComponent(PhoneSnippetStore.fileName))
        let put = #"{"device_id":"dev","hash":"h","snippets":[{"name":"B","text":"phone bb","keyword":"bb"},{"name":"A","text":"phone addr","keyword":"addr"}]}"#
        XCTAssertEqual(s.put(Data(put.utf8)), .ok(count: 2, hash: "h"))
        let mac = [SnippetHit(name: "Addr", keyword: "addr", text: "mac addr"),
                   SnippetHit(name: "Off", keyword: "off", text: "mac off", autoExpand: false),
                   SnippetHit(name: "Pref", keyword: "pp", text: "mac pp", collection: "C")]
        let reps = ["addr": "rep addr", "bb": "rep bb", "off": "rep off", ";;pp": "rep pp",
                    "omw": "On my way", "o m w": "spaced"]
        let keywords = SnippetStore.effectiveKeywords(mac, collections: ["C": (prefix: ";;", suffix: "")],
                                                      phone: s.sets(), replacements: reps)
        XCTAssertEqual(keywords.map(\.trigger), ["addr", ";;pp", "bb", "omw"],
                       "Mac and phone keywords block the replacements; a spaced shortcut is no trigger")
        XCTAssertEqual(keywords.last?.id, TextReplacements.id("omw"))
        let lookup: (String) -> SnippetHit? = { id in
            PhoneSnippetStore.lookup(id, phone: s, mac: { n in mac.first { $0.name == n } }, replacements: reps)
        }
        func text(_ buffer: String) -> String? {
            guard case let .insertPlain(_, _, t, _) = plan(buffer, keywords, lookup) else { return nil }
            return t
        }
        XCTAssertEqual(text("x addr"), "mac addr")
        XCTAssertEqual(text("x bb"), "phone bb")
        XCTAssertEqual(text("x ;;pp"), "mac pp")
        XCTAssertEqual(text("x omw "), "On my way ")
        XCTAssertNil(text("x off"), "a Mac keyword that does not auto-expand still blocks the replacement")
    }

    // MARK: - Word boundary (macOS's rule) for replacements in every mode

    func testReplacementsFireOnlyAtAWordBoundary() {
        let reps = ["em": "E. M.", "ty": "Thank you"]
        let keywords = PhoneSnippetStore.triggers(mac: [(";;a", "A")], macKeywords: [";;a"], sets: [], replacements: reps)
        let match = { (b: String) in SnippetMatcher.match(buffer: b, keywords: keywords, wordBoundaryMode: false) }
        for buffer in ["them", "them ", "pretty", "pretty ", "x em", "emx "] {
            XCTAssertNil(match(buffer), "\(buffer) must not fire")
        }
        XCTAssertEqual(match("x em "), SnippetMatchResult(id: TextReplacements.id("em"), keywordLength: 2, consumedDelimiter: true))
        XCTAssertEqual(match("em\t"), SnippetMatchResult(id: TextReplacements.id("em"), keywordLength: 2, consumedDelimiter: true),
                       "at the start, any whitespace delimiter")
        XCTAssertEqual(match("(ty "), SnippetMatchResult(id: TextReplacements.id("ty"), keywordLength: 2, consumedDelimiter: true),
                       "punctuation is a boundary")
        XCTAssertEqual(match("x;;a"), SnippetMatchResult(id: "A", keywordLength: 3, consumedDelimiter: false),
                       "a Mac keyword still fires at once, no delimiter")
        let lookup: (String) -> SnippetHit? = { PhoneSnippetStore.lookup($0, mac: { _ in nil }, replacements: reps) }
        XCTAssertEqual(plan("x em ", keywords, lookup),
                       .insertPlain(name: "E. M.", backspaces: 2, insertText: "E. M. ", leftArrows: 0),
                       "backspaces the shortcut (the delimiter was swallowed) and types phrase + delimiter")
        // Word-boundary mode is unchanged: everything waits for the delimiter.
        let wb = { (b: String) in SnippetMatcher.match(buffer: b, keywords: keywords, wordBoundaryMode: true) }
        XCTAssertNil(wb("x;;a"))
        XCTAssertEqual(wb("x ;;a "), SnippetMatchResult(id: "A", keywordLength: 3, consumedDelimiter: true))
        XCTAssertNil(wb("them "))
        XCTAssertEqual(wb("x em "), match("x em "))
    }

    // MARK: - Namespacing: Mac-only paths never see a replacement

    func testReplacementNeverShadowsOrResolvesToAMacSnippet() {
        let mac = SnippetHit(name: "On my way", keyword: "mo", text: "mac omw")
        let macLookup: (String) -> SnippetHit? = { $0 == mac.name ? mac : nil }
        let reps = ["omw": "On my way"]
        XCTAssertEqual(PhoneSnippetStore.lookup("On my way", mac: macLookup, replacements: reps)?.text, "mac omw",
                       "a bare name is the Mac's")
        XCTAssertNil(PhoneSnippetStore.lookup("omw", mac: { _ in nil }, replacements: reps),
                     "a bare shortcut never reaches the replacements")
        let hit = PhoneSnippetStore.lookup(TextReplacements.id("omw"), mac: { _ in mac }, replacements: reps)
        XCTAssertEqual(hit, SnippetHit(name: "On my way", keyword: "omw", text: "On my way",
                                       collection: "Text Replacements", literal: true))
        XCTAssertNil(PhoneSnippetStore.lookup(TextReplacements.id("nope"), mac: { _ in mac }, replacements: reps),
                     "an unknown replacement id never falls back to a Mac snippet")
        XCTAssertNotEqual(TextReplacements.id("omw"), PhoneSnippetStore.id(device: "", name: "omw"))
    }

    func testNeverInTheMacStoreOrItsExport() {
        TextReplacements.read = { ["zq732": "Phrase 732 only"] }
        TextReplacements.refresh()
        XCTAssertEqual(TextReplacements.items(), ["zq732": "Phrase 732 only"])
        XCTAssertFalse(SnippetStore.all().contains { $0.text.contains("Phrase 732") || $0.keyword == "zq732" })
        XCTAssertNil(SnippetStore.byName("Phrase 732 only"))
        XCTAssertFalse(SnippetStore.exportJSON().contains("Phrase 732"))
    }

    // MARK: - Toggle and refresh

    func testToggleDefaultsOnAndOffRemovesTheSource() {
        TextReplacements.read = { ["zq732": "Phrase"] }
        TextReplacements.refresh()
        XCTAssertTrue(Preferences.snippetsTextReplacements, "on by default")
        let id = TextReplacements.id("zq732")
        func triggers() -> [String] {
            SnippetStore.effectiveKeywords([], collections: [:], phone: [], replacements: TextReplacements.items())
                .map(\.trigger)
        }
        XCTAssertEqual(triggers(), ["zq732"])
        XCTAssertEqual(PhoneSnippetStore.lookup(id, mac: { _ in nil })?.text, "Phrase")
        XCTAssertEqual(json(LiveExtensionHostServices.shared.snippetsTextReplacements()).first?["text"] as? String, "Phrase")

        let token = SnippetStore.changeToken
        LiveExtensionHostServices.shared.snippetSetConfig(json: #"{"textReplacements":false}"#)
        XCTAssertFalse(Preferences.snippetsTextReplacements)
        XCTAssertNotEqual(SnippetStore.changeToken, token, "the expander rebuilds without them")
        XCTAssertEqual(json("[" + LiveExtensionHostServices.shared.snippetConfig() + "]").first?["textReplacements"] as? Bool, false)
        XCTAssertEqual(triggers(), [])
        XCTAssertNil(PhoneSnippetStore.lookup(id, mac: { _ in nil }))
        XCTAssertEqual(LiveExtensionHostServices.shared.snippetsTextReplacements(), "[]", "palette search too")

        var reads = 0
        TextReplacements.read = { reads += 1; return ["zq732": "Phrase"] }
        TextReplacements.refresh()
        XCTAssertEqual(reads, 0, "off: no read at all")
        Preferences.snippetsTextReplacements = true
        TextReplacements.refresh()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(triggers(), ["zq732"])
    }

    func testRefreshBumpsTheTokenOnlyOnAChange() {
        var dict = ["zq732": "One"]
        TextReplacements.read = { dict }
        TextReplacements.refresh()
        var token = SnippetStore.changeToken
        TextReplacements.refresh()
        XCTAssertEqual(SnippetStore.changeToken, token, "unchanged: the expander keeps its cache")
        dict["zq732"] = "Two"
        TextReplacements.refresh()
        XCTAssertNotEqual(SnippetStore.changeToken, token, "changed: the expander rebuilds")
        XCTAssertEqual(TextReplacements.items(), ["zq732": "Two"])
        token = SnippetStore.changeToken
        dict = [:]
        TextReplacements.refresh()
        XCTAssertNotEqual(SnippetStore.changeToken, token)
        XCTAssertEqual(TextReplacements.items(), [:])
    }

    // MARK: - Lua bridge

    private final class Services: ExtensionHostServices, @unchecked Sendable {
        func clipboardRead() -> String? { nil }
        func clipboardWrite(_ text: String) {}
        func clipboardHistory(limit: Int) -> [String] { [] }
        func llmComplete(_ prompt: String) async -> String { "" }
        func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
        func llmChat(_ prompt: String) async -> String { "" }
        func shellRun(_ command: String) async -> String { "" }
        func httpRequest(method: String, url: String, headers: [String: String],
                         body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
        func currentEpochSeconds() -> Double { 0 }
        func focusedWindowFrame() -> WindowFrame? { nil }
        func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
        func prefGet(extensionID: String, key: String) -> String? { nil }
        func prefSet(extensionID: String, key: String, value: String) {}
        func notify(title: String, body: String) {}
        func listDirectories(_ path: String) -> [String] { [] }
        func snippetsTextReplacements() -> String { #"[{"id":"r","name":"On my way","keyword":"omw","text":"On my way"}]"# }
    }

    func testLuaBridgeListsReplacementsAndHidesTheRawGlobal() throws {
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: "com.test", services: Services()).install(into: lua)
        try lua.run("""
        function probe()
            local r = host.snippets.replacements()
            return tostring(__h_snippets_replacements) .. ',' .. #r .. ',' .. r[1].keyword .. ',' .. r[1].text
        end
        """)
        XCTAssertEqual(try lua.callGlobal("probe"), "nil,1,omw,On my way")
    }

    private func json(_ s: String) -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [[String: Any]] ?? []
    }
}
