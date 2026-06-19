import XCTest
import LuaRuntime
@testable import ProsperApp

/// Integration tests for the Browser Bookmarks system extension, driven through
/// `ExtensionRegistry` with a **mocked filesystem** (path → file contents and
/// path → directory listing) standing in for the real browser profile data, plus
/// a mocked Full Disk Access grant. The extension's host.shell reads (cat / plutil
/// / sqlite3) and host.fs listings resolve against these maps, so each test can
/// stage exactly one browser's data and assert what gets extracted.
///
/// UI interaction is mocked at the view-tree boundary: a search renders a
/// `host.ui.list`, which we decode into native `ListItem`s — the same rows the
/// runner shows — and assert the `url` each row would hand to the open path.
private final class BookmarkFakeServices: ExtensionHostServices, @unchecked Sendable {
    /// Absolute home dir the extension resolves via `printf %s "$HOME"`.
    var home = "/Users/test"
    /// Mocked filesystem: absolute path -> file contents (cat, and plutil's input).
    var files: [String: String] = [:]
    /// Mocked directory listings: absolute path -> immediate subdirectory names.
    var dirs: [String: [String]] = [:]
    /// Mocked sqlite output: places.sqlite path -> the `-json` rows string.
    var sqlite: [String: String] = [:]
    /// Granted privacy permissions (e.g. "full-disk-access").
    var granted: Set<String> = []
    /// host.prefs store (the import cache lives here).
    var prefs: [String: String] = [:]
    /// Number of reads of the big cache blob ("cache" key) — used to prove a
    /// keystroke search does NOT re-marshal the whole cache across the boundary.
    var cacheBlobReads = 0

    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func currentEpochSeconds() -> Double { 1_700_000_000 }
    func prefGet(extensionID: String, key: String) -> String? {
        if key == "cache" { cacheBlobReads += 1 }
        return prefs[key]
    }
    func prefSet(extensionID: String, key: String, value: String) { prefs[key] = value }
    func notify(title: String, body: String) {}
    func listDirectories(_ path: String) -> [String] { dirs[path] ?? [] }
    func permissionGranted(_ name: String) -> Bool { granted.contains(name) }

    func shellRun(_ command: String) async -> String { runShell(command) }

    /// Resolve a shelled command against the mocked filesystem.
    private func runShell(_ cmd: String) -> String {
        if cmd.contains("printf %s") { return home }
        if cmd.hasPrefix("cat ") {
            return Self.firstQuoted(cmd).flatMap { files[$0] } ?? ""
        }
        if cmd.hasPrefix("plutil") {
            // plutil -convert json -o - 'PATH' : the plist path is the only quoted token.
            return Self.firstQuoted(cmd).flatMap { files[$0] } ?? ""
        }
        if cmd.hasPrefix("sqlite3") {
            // sqlite3 -readonly -json 'file:ENC?immutable=1' 'SQL' : first quoted = URI.
            guard let uri = Self.firstQuoted(cmd) else { return "" }
            return sqlite[Self.decodeFileURI(uri)] ?? ""
        }
        return ""
    }

    /// First single-quoted token (the path `shq` produced).
    static func firstQuoted(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "'") else { return nil }
        let after = s.index(after: a)
        guard let b = s[after...].firstIndex(of: "'") else { return nil }
        return String(s[after..<b])
    }

    /// Reverse the `file:<percent-encoded-path>?immutable=1` URI back to a path.
    static func decodeFileURI(_ uri: String) -> String {
        var s = uri
        if s.hasPrefix("file:") { s.removeFirst("file:".count) }
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        return s.replacingOccurrences(of: "%20", with: " ")
                .replacingOccurrences(of: "%25", with: "%")
    }
}

final class BookmarksExtensionTests: XCTestCase {

    // MARK: - Paths (must mirror the absolute paths init.lua builds from $HOME)

    private static let home = "/Users/test"
    private static func support(_ rel: String) -> String { "\(home)/Library/Application Support/\(rel)" }
    private static let chromeSupport  = support("Google/Chrome")
    private static let braveSupport   = support("BraveSoftware/Brave-Browser")
    private static let edgeSupport    = support("Microsoft Edge")
    private static let vivaldiSupport = support("Vivaldi")
    private static let operaSupport   = support("com.operasoftware.Opera")
    private static let arcPath        = support("Arc/StorableSidebar.json")
    private static let firefoxProfiles = support("Firefox/Profiles")
    private static let zenProfiles     = support("zen/Profiles")
    private static let safariPlist    = "\(home)/Library/Safari/Bookmarks.plist"

    // MARK: - Fixtures

    /// A minimal Chromium `Bookmarks` JSON with one bookmark on the bar.
    private static func chromium(_ name: String, _ url: String, folder: String = "Bookmarks Bar") -> String {
        """
        {"roots":{
          "bookmark_bar":{"type":"folder","name":"\(folder)","children":[
            {"type":"url","name":"\(name)","url":"\(url)"}
          ]},
          "other":{"type":"folder","name":"Other","children":[]},
          "synced":{"type":"folder","name":"Mobile","children":[]}
        }}
        """
    }

    /// A richer Chromium tree: bar bookmark + nested folder + an "other" bookmark.
    private static let chromeNested = """
    {"roots":{
      "bookmark_bar":{"type":"folder","name":"Bookmarks Bar","children":[
        {"type":"url","name":"GitHub","url":"https://github.com/"},
        {"type":"folder","name":"Dev","children":[
          {"type":"url","name":"Swift","url":"https://swift.org/"}
        ]}
      ]},
      "other":{"type":"folder","name":"Other Bookmarks","children":[
        {"type":"url","name":"Example","url":"https://example.com/"}
      ]},
      "synced":{"type":"folder","name":"Mobile","children":[]}
    }}
    """

    private static let safariJSON = """
    {"Children":[
      {"WebBookmarkType":"WebBookmarkTypeList","Title":"BookmarksBar","Children":[
        {"WebBookmarkType":"WebBookmarkTypeLeaf","URLString":"https://apple.com/","URIDictionary":{"title":"Apple"}}
      ]}
    ]}
    """

    private static let firefoxJSON =
        #"[{"title":"Mozilla","url":"https://mozilla.org/"},{"title":"Rust","url":"https://rust-lang.org/"}]"#

    private static let arcJSON = """
    {"sidebar":{"containers":[
      {"global":true},
      {"items":[
        {"id":"c1","title":"Work","childrenIds":["t1","t2"]},
        {"id":"t1","data":{"tab":{"savedURL":"https://news.ycombinator.com/","savedTitle":"HN"}}},
        {"id":"t2","data":{"tab":{"savedURL":"https://lobste.rs/","savedTitle":"Lobsters"}}}
      ],
      "spaces":[
        {"title":"Personal","containerIDs":["pinned","c1"]}
      ]}
    ]}}
    """

    /// A fake populated with every supported source (Chrome+Arc+Firefox+Safari).
    private func makeCombinedFake() -> BookmarkFakeServices {
        let fake = BookmarkFakeServices()
        fake.dirs[Self.chromeSupport] = ["Default", "Profile 1"]
        fake.dirs[Self.firefoxProfiles] = ["p1.default"]
        fake.files["\(Self.chromeSupport)/Default/Bookmarks"] = Self.chromeNested
        fake.files[Self.arcPath] = Self.arcJSON
        fake.files[Self.safariPlist] = Self.safariJSON
        fake.sqlite["\(Self.firefoxProfiles)/p1.default/places.sqlite"] = Self.firefoxJSON
        return fake
    }

    // MARK: - Registry harness

    private func extensionsDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
    }

    @MainActor
    private func makeRegistry(_ fake: BookmarkFakeServices) throws -> ExtensionRegistry {
        let dir = extensionsDir()
        try XCTSkipIf(!FileManager.default.fileExists(atPath: dir.path), "extensions dir missing")
        let suite = "bm-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let registry = ExtensionRegistry(
            systemDir: dir,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true),
            defaults: defaults,
            services: fake
        )
        registry.discover()
        try XCTSkipIf(registry.command(id: "bookmarks.run") == nil, "bookmarks.run not discovered")
        return registry
    }

    /// Run a search and decode the rendered view into the rows the runner shows.
    /// `query` is the text after the `bm` verb ("" lists everything).
    @MainActor
    private func searchItems(_ registry: ExtensionRegistry, _ query: String) async throws -> [ListItem] {
        let rendered = await registry.invokeAsync(
            commandID: "bookmarks.run", query: "bm \(query)")
        let raw = try XCTUnwrap(rendered)
        guard case .list(let list) = try ExtensionViewNode.decode(json: raw) else {
            XCTFail("expected a list view, got: \(raw)")
            return []
        }
        return list.items
    }

    private func item(_ items: [ListItem], titled title: String) -> ListItem? {
        items.first { $0.title == title }
    }

    // MARK: - Per-browser extraction (mocked filesystem)

    @MainActor
    func testChromeExtractionWithNestedFolders() async throws {
        let fake = BookmarkFakeServices()
        fake.dirs[Self.chromeSupport] = ["Default"]
        fake.files["\(Self.chromeSupport)/Default/Bookmarks"] = Self.chromeNested
        let registry = try makeRegistry(fake)

        let items = try await searchItems(registry, "")
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(item(items, titled: "GitHub")?.url, "https://github.com/")
        // Nested folder path is preserved in the subtitle (browser · folder).
        XCTAssertEqual(item(items, titled: "Swift")?.url, "https://swift.org/")
        XCTAssertEqual(item(items, titled: "Swift")?.subtitle, "Chrome · Bookmarks Bar/Dev")
        XCTAssertEqual(item(items, titled: "Example")?.subtitle, "Chrome · Other Bookmarks")
    }

    @MainActor
    func testChromeEnumeratesMultipleProfiles() async throws {
        let fake = BookmarkFakeServices()
        fake.dirs[Self.chromeSupport] = ["Default", "Profile 1", "System Profile", "Guest Profile"]
        fake.files["\(Self.chromeSupport)/Default/Bookmarks"] = Self.chromium("Default BM", "https://d/")
        fake.files["\(Self.chromeSupport)/Profile 1/Bookmarks"] = Self.chromium("Work BM", "https://w/")
        let registry = try makeRegistry(fake)

        let items = try await searchItems(registry, "")
        // Default + Profile 1 contribute; System/Guest profiles are ignored.
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(item(items, titled: "Default BM")?.url, "https://d/")
        XCTAssertEqual(item(items, titled: "Work BM")?.url, "https://w/")
    }

    @MainActor
    func testBraveExtraction() async throws {
        let fake = BookmarkFakeServices()
        fake.dirs[Self.braveSupport] = ["Default"]
        fake.files["\(Self.braveSupport)/Default/Bookmarks"] = Self.chromium("Brave Search", "https://search.brave.com/")
        let registry = try makeRegistry(fake)

        let items = try await searchItems(registry, "")
        let hit = try XCTUnwrap(item(items, titled: "Brave Search"))
        XCTAssertEqual(hit.url, "https://search.brave.com/")
        XCTAssertEqual(hit.subtitle, "Brave · Bookmarks Bar")
    }

    @MainActor
    func testEdgeExtraction() async throws {
        let fake = BookmarkFakeServices()
        fake.dirs[Self.edgeSupport] = ["Default"]
        fake.files["\(Self.edgeSupport)/Default/Bookmarks"] = Self.chromium("Bing", "https://bing.com/")
        let registry = try makeRegistry(fake)

        let found = try await searchItems(registry, "")
        let hit = try XCTUnwrap(item(found, titled: "Bing"))
        XCTAssertEqual(hit.url, "https://bing.com/")
        XCTAssertEqual(hit.subtitle, "Edge · Bookmarks Bar")
    }

    @MainActor
    func testVivaldiExtraction() async throws {
        let fake = BookmarkFakeServices()
        fake.dirs[Self.vivaldiSupport] = ["Default"]
        fake.files["\(Self.vivaldiSupport)/Default/Bookmarks"] = Self.chromium("Vivaldi", "https://vivaldi.com/")
        let registry = try makeRegistry(fake)

        let found = try await searchItems(registry, "")
        let hit = try XCTUnwrap(item(found, titled: "Vivaldi"))
        XCTAssertEqual(hit.url, "https://vivaldi.com/")
        XCTAssertEqual(hit.subtitle, "Vivaldi · Bookmarks Bar")
    }

    @MainActor
    func testOperaExtractionSingleProfile() async throws {
        // Opera keeps a single profile: `Bookmarks` sits directly under support,
        // with no Default/Profile dirs to enumerate.
        let fake = BookmarkFakeServices()
        fake.files["\(Self.operaSupport)/Bookmarks"] = Self.chromium("Opera", "https://opera.com/")
        let registry = try makeRegistry(fake)

        let found = try await searchItems(registry, "")
        let hit = try XCTUnwrap(item(found, titled: "Opera"))
        XCTAssertEqual(hit.url, "https://opera.com/")
        XCTAssertEqual(hit.subtitle, "Opera · Bookmarks Bar")
    }

    @MainActor
    func testArcExtractionResolvesSpaceAndFolder() async throws {
        let fake = BookmarkFakeServices()
        fake.files[Self.arcPath] = Self.arcJSON
        let registry = try makeRegistry(fake)

        let items = try await searchItems(registry, "")
        XCTAssertEqual(items.count, 2)
        let hn = try XCTUnwrap(item(items, titled: "HN"))
        XCTAssertEqual(hn.url, "https://news.ycombinator.com/")
        // space ("Personal") + container ("Work") nest into the folder path.
        XCTAssertEqual(hn.subtitle, "Arc · Personal/Work")
        XCTAssertEqual(item(items, titled: "Lobsters")?.url, "https://lobste.rs/")
    }

    @MainActor
    func testFirefoxExtraction() async throws {
        let fake = BookmarkFakeServices()
        fake.dirs[Self.firefoxProfiles] = ["p1.default"]
        fake.sqlite["\(Self.firefoxProfiles)/p1.default/places.sqlite"] = Self.firefoxJSON
        let registry = try makeRegistry(fake)

        let items = try await searchItems(registry, "")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(item(items, titled: "Mozilla")?.url, "https://mozilla.org/")
        XCTAssertEqual(item(items, titled: "Rust")?.subtitle, "Firefox · p1.default")
    }

    /// The locked `bm ` mode must list all bookmarks on an empty query (then filter
    /// on type). The runner gates that on the command's `list_on_empty` manifest flag
    /// (RunnerPanel.extRunsEmpty), so assert the flag is declared + decoded.
    @MainActor
    func testCommandListsOnEmptyQuery() throws {
        let registry = try makeRegistry(BookmarkFakeServices())
        XCTAssertEqual(registry.command(id: "bookmarks.run")?.command.listsOnEmpty, true,
                       "bookmarks.run must set list_on_empty so `bm ` lists all on open")
    }

    /// Decode the inline launcher fallback (`bookmarks_inline`) into its rows.
    /// nil = the handler declined (returned "") — off, too-short, or no match.
    @MainActor
    private func inlineItems(_ registry: ExtensionRegistry, _ query: String) async -> [ListItem]? {
        guard let node = await registry.callExtensionViewAsync(
            extensionID: "com.prosper.bookmarks", function: "bookmarks_inline", args: [query]),
              case .list(let list) = node else { return nil }
        return list.items
    }

    /// Opt-in inline bookmarks for the universal launcher: declines (nil) until the
    /// `show_in_launcher` pref is on, then surfaces a capped (≤5) CONTAINS match.
    @MainActor
    func testInlineLauncherOptIn() async throws {
        let fake = BookmarkFakeServices()
        fake.dirs[Self.firefoxProfiles] = ["p1.default"]
        fake.sqlite["\(Self.firefoxProfiles)/p1.default/places.sqlite"] = Self.firefoxJSON
        let registry = try makeRegistry(fake)
        _ = try await searchItems(registry, "")   // first use → import populates the cache

        // Off by default → declines regardless of match.
        let off = await inlineItems(registry, "mozilla")
        XCTAssertNil(off, "inline must be off until show_in_launcher is enabled")

        fake.prefs["show_in_launcher"] = "true"
        // < 2 chars declines (don't flood the launcher on a single keystroke).
        let short = await inlineItems(registry, "m")
        XCTAssertNil(short)
        // No match declines (so the launcher falls through to noResults).
        let none = await inlineItems(registry, "zzzznope")
        XCTAssertNil(none)
        // A real match surfaces rows carrying the openable url.
        let hits = await inlineItems(registry, "mozilla")
        let hit = try XCTUnwrap(hits)
        XCTAssertEqual(item(hit, titled: "Mozilla")?.url, "https://mozilla.org/")
    }

    /// Inline results are capped (≤5) so they never flood the launcher.
    @MainActor
    func testInlineLauncherCapsRows() async throws {
        let fake = BookmarkFakeServices()
        fake.dirs[Self.chromeSupport] = ["Default"]
        fake.files["\(Self.chromeSupport)/Default/Bookmarks"] = Self.largeChromium(20)
        fake.prefs["show_in_launcher"] = "true"
        let registry = try makeRegistry(fake)
        _ = try await searchItems(registry, "")   // import → cache

        let matched = await inlineItems(registry, "site")   // matches all 20
        let rows = try XCTUnwrap(matched)
        XCTAssertEqual(rows.count, 5)
    }

    @MainActor
    func testZenExtraction() async throws {
        // Zen is Firefox-based: same places.sqlite schema. Profile dir name carries a
        // space ("...Default (alpha)"), exercising the file: URI %20 encoding.
        let fake = BookmarkFakeServices()
        fake.dirs[Self.zenProfiles] = ["h97fnrma.Default (alpha)"]
        fake.sqlite["\(Self.zenProfiles)/h97fnrma.Default (alpha)/places.sqlite"] =
            #"[{"title":"Zen Home","url":"https://zen-browser.app/"}]"#
        let registry = try makeRegistry(fake)

        let items = try await searchItems(registry, "")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item(items, titled: "Zen Home")?.url, "https://zen-browser.app/")
        XCTAssertEqual(item(items, titled: "Zen Home")?.subtitle, "Zen · h97fnrma.Default (alpha)")
    }

    @MainActor
    func testFirefoxEnumeratesMultipleProfiles() async throws {
        let fake = BookmarkFakeServices()
        fake.dirs[Self.firefoxProfiles] = ["a.default", "b.dev"]
        fake.sqlite["\(Self.firefoxProfiles)/a.default/places.sqlite"] =
            #"[{"title":"A","url":"https://a/"}]"#
        fake.sqlite["\(Self.firefoxProfiles)/b.dev/places.sqlite"] =
            #"[{"title":"B","url":"https://b/"}]"#
        let registry = try makeRegistry(fake)

        let items = try await searchItems(registry, "")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(item(items, titled: "A")?.url, "https://a/")
        XCTAssertEqual(item(items, titled: "B")?.url, "https://b/")
    }

    @MainActor
    func testSafariExtractionWithFullDiskAccess() async throws {
        let fake = BookmarkFakeServices()
        fake.granted = ["full-disk-access"]
        fake.files[Self.safariPlist] = Self.safariJSON
        let registry = try makeRegistry(fake)

        let found = try await searchItems(registry, "")
        let hit = try XCTUnwrap(item(found, titled: "Apple"))
        XCTAssertEqual(hit.url, "https://apple.com/")
        XCTAssertEqual(hit.subtitle, "Safari · BookmarksBar")
    }

    @MainActor
    func testSafariSkippedWithoutFullDiskAccess() async throws {
        let fake = BookmarkFakeServices()   // FDA off
        fake.files[Self.safariPlist] = Self.safariJSON
        let registry = try makeRegistry(fake)

        // Nothing else is staged, so the cache stays empty and the view shows the
        // empty-state row rather than the Safari bookmark.
        let items = try await searchItems(registry, "")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "No bookmarks imported")
        // The import summary names Safari as skipped, pointing the user at FDA.
        let summary = await registry.invokeAsync(commandID: "bookmarks.run", query: "bm import")
        XCTAssertEqual(summary, "No bookmarks found.  Skipped: Safari (needs Full Disk Access).")
    }

    // MARK: - Combined import + management verbs

    @MainActor
    func testImportWithoutFullDiskAccessSkipsSafari() async throws {
        let registry = try makeRegistry(makeCombinedFake())   // FDA off
        let summary = await registry.invokeAsync(commandID: "bookmarks.run", query: "bm import")
        XCTAssertEqual(summary,
            "Imported 7 bookmarks (Arc 2, Chrome 3, Firefox 2).  Skipped: Safari (needs Full Disk Access).")
    }

    @MainActor
    func testImportWithFullDiskAccessIncludesSafari() async throws {
        let fake = makeCombinedFake(); fake.granted = ["full-disk-access"]
        let registry = try makeRegistry(fake)
        let summary = await registry.invokeAsync(commandID: "bookmarks.run", query: "bm import")
        XCTAssertEqual(summary, "Imported 8 bookmarks (Arc 2, Chrome 3, Firefox 2, Safari 1).")
    }

    @MainActor
    func testBrowsersListsPerBrowserCounts() async throws {
        let fake = makeCombinedFake(); fake.granted = ["full-disk-access"]
        let registry = try makeRegistry(fake)
        _ = await registry.invokeAsync(commandID: "bookmarks.run", query: "bm import")
        let browsers = await registry.invokeAsync(commandID: "bookmarks.run", query: "bm browsers")
        XCTAssertEqual(browsers,
            "Arc — 2 bookmarks\nChrome — 3 bookmarks\nFirefox — 2 bookmarks\nSafari — 1 bookmarks")
    }

    // MARK: - Search + mocked UI selection

    @MainActor
    func testSearchFiltersByTermAcrossBrowsers() async throws {
        let fake = makeCombinedFake(); fake.granted = ["full-disk-access"]
        let registry = try makeRegistry(fake)
        _ = await registry.invokeAsync(commandID: "bookmarks.run", query: "bm import")

        let items = try await searchItems(registry, "swift")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Swift")
        // The non-matching bookmarks are filtered out.
        XCTAssertNil(item(items, titled: "GitHub"))
    }

    @MainActor
    func testSearchAutoImportsWhenCacheEmpty() async throws {
        let registry = try makeRegistry(makeCombinedFake())
        // No explicit import: a cold search auto-imports, then matches.
        let items = try await searchItems(registry, "github")
        XCTAssertEqual(item(items, titled: "GitHub")?.url, "https://github.com/")
    }

    @MainActor
    func testSearchNoMatchRendersEmptyState() async throws {
        let registry = try makeRegistry(makeCombinedFake())
        _ = await registry.invokeAsync(commandID: "bookmarks.run", query: "bm import")
        let items = try await searchItems(registry, "zzzznomatch")
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.first?.title.contains("No bookmarks match") ?? false)
        XCTAssertNil(items.first?.url)
    }

    @MainActor
    func testUISelectionYieldsOpenableURL() async throws {
        // Mocks the full UI loop: a keystroke renders rows (host.ui.list); the user
        // arrows to a result and presses Enter, which hands that row's `url` to the
        // runner's native open path (onOpenURL). We assert the URL the selected row
        // would open — the contract the runner consumes.
        let fake = makeCombinedFake(); fake.granted = ["full-disk-access"]
        let registry = try makeRegistry(fake)

        let items = try await searchItems(registry, "apple")
        let selected = try XCTUnwrap(items.first)
        XCTAssertEqual(selected.title, "Apple")
        XCTAssertEqual(selected.url, "https://apple.com/")   // what onOpenURL receives
    }

    // MARK: - Performance (hot path: per-keystroke search over a large library)

    /// Build one Chromium `Bookmarks` JSON with `n` distinct bookmarks on the bar.
    private static func largeChromium(_ n: Int) -> String {
        var kids = [String]()
        kids.reserveCapacity(n)
        for i in 0..<n {
            kids.append(#"{"type":"url","name":"Bookmark \#(i) site","url":"https://example\#(i).com/page"}"#)
        }
        return """
        {"roots":{
          "bookmark_bar":{"type":"folder","name":"Bookmarks Bar","children":[\(kids.joined(separator: ","))]},
          "other":{"type":"folder","name":"Other","children":[]},
          "synced":{"type":"folder","name":"Mobile","children":[]}
        }}
        """
    }

    /// HOT-PATH REQUIREMENT: per-keystroke search over a large (≈MAX_BOOKMARKS)
    /// library must stay interactive. The decode is memoized and the lowercased
    /// haystack is precomputed once at import, so a keystroke is a plain `find`
    /// scan over the cache — no per-row string rebuilds. Ceiling is generous
    /// (CI noise) but ~10× under the old per-keystroke cost; actual is printed.
    @MainActor
    func testSearchHotPathBudget() async throws {
        let n = 5000
        let fake = BookmarkFakeServices()
        fake.granted = ["full-disk-access"]   // no Safari data staged → import stays Chrome-only, no skip note
        fake.dirs[Self.chromeSupport] = ["Default"]
        fake.files["\(Self.chromeSupport)/Default/Bookmarks"] = Self.largeChromium(n)
        let registry = try makeRegistry(fake)

        // Import once, then warm the decode/haystack memo with a first search.
        let summary = await registry.invokeAsync(commandID: "bookmarks.run", query: "bm import")
        XCTAssertEqual(summary, "Imported \(n) bookmarks (Chrome \(n)).")
        _ = try await searchItems(registry, "warmup")

        // Worst case: a single term that matches nothing → every row's full
        // haystack is scanned to completion before failing.
        let iters = 30
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iters {
            let items = try await searchItems(registry, "zzqqnomatch")
            XCTAssertEqual(items.count, 1)   // empty-state row only
        }
        let perCallMs = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iters) / 1_000_000
        print("bookmarks search hot path: \(String(format: "%.2f", perCallMs)) ms/keystroke over \(n) bookmarks (full-scan miss)")

        XCTAssertLessThan(perCallMs, 25, "per-keystroke search over \(n) bookmarks exceeded the 25ms hot-path budget")
    }

    /// STABILITY: an oversized `max_results` pref (set raw in host.prefs, bypassing
    /// the settings control's max=500) must be clamped so a keystroke can't build an
    /// unbounded result list. 600 bookmarks + max_results=100000 → still ≤ 500 rows.
    @MainActor
    func testMaxResultsClampedToCap() async throws {
        let fake = BookmarkFakeServices()
        fake.granted = ["full-disk-access"]
        fake.prefs["max_results"] = "100000"   // pathological raw pref, past the UI ceiling
        fake.dirs[Self.chromeSupport] = ["Default"]
        fake.files["\(Self.chromeSupport)/Default/Bookmarks"] = Self.largeChromium(600)
        let registry = try makeRegistry(fake)
        _ = await registry.invokeAsync(commandID: "bookmarks.run", query: "bm import")

        let items = try await searchItems(registry, "")   // list-all; limit = clamped cap
        XCTAssertEqual(items.count, 500, "max_results not clamped to the 500 cap")
    }

    /// REAL-ENVIRONMENT REGRESSION (no mock). The mocked suite stages pre-converted
    /// JSON for `plutil`, which hid that a direct `plutil -convert json` ABORTS on a
    /// real Safari plist's <data> (Sync/CloudKit blobs) and <date> nodes — yielding 0
    /// bytes, so every Safari import silently returned nothing. This runs the
    /// extension's exact scrub pipeline through the real shell against a genuine
    /// BINARY plist holding both node types and asserts the leaf URL survives.
    func testSafariScrubPipelineHandlesDataAndDateNodes() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>WebBookmarkType</key><string>WebBookmarkTypeList</string>
          <key>Children</key><array><dict>
            <key>WebBookmarkType</key><string>WebBookmarkTypeLeaf</string>
            <key>URLString</key><string>https://apple.com/</string>
            <key>URIDictionary</key><dict><key>title</key><string>Apple</string></dict>
            <key>Sync</key><dict><key>Data</key><data>aGVsbG8=</data><key>ServerData</key><data>d29ybGQ=</data></dict>
            <key>LastModified</key><date>2024-01-01T00:00:00Z</date>
          </dict></array>
        </dict></plist>
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xmlURL = dir.appendingPathComponent("b.xml")
        let binURL = dir.appendingPathComponent("Bookmarks.plist")
        try xml.write(to: xmlURL, atomically: true, encoding: .utf8)
        _ = Self.run("/usr/bin/plutil", ["-convert", "binary1", "-o", binURL.path, xmlURL.path])

        let q = "'" + binURL.path + "'"
        // Control: the pre-fix naive conversion must fail on this plist.
        let naive = Self.run("/bin/zsh", ["-lc", "plutil -convert json -o - \(q) 2>&1"])
        XCTAssertFalse(naive.contains("apple.com"), "control invalid: naive convert unexpectedly succeeded")

        // The shipped pipeline (mirrors init.lua parse_safari).
        let cmd = "plutil -convert xml1 -o - \(q) 2>/dev/null"
            + " | /usr/bin/perl -0pe 's{<(data|date)>.*?</\\1>}{<string></string>}gs'"
            + " | plutil -convert json -o - - 2>/dev/null"
        let out = Self.run("/bin/zsh", ["-lc", cmd])
        XCTAssertTrue(out.contains("\"URLString\":\"https:\\/\\/apple.com\\/\"") || out.contains("https://apple.com/"),
                      "scrub pipeline did not recover the bookmark URL; got: \(out)")
    }

    /// Run a process to completion, returning combined stdout (test helper only).
    private static func run(_ launch: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "spawn error: \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// HOT-PATH REQUIREMENT: a keystroke must NOT re-marshal the whole cache blob
    /// across the Lua↔host boundary. The memo keys on the tiny version counter, so
    /// after the first (warming) read the big "cache" key is never fetched again
    /// until an import bumps the version.
    @MainActor
    func testSearchDoesNotRefetchCacheBlobPerKeystroke() async throws {
        let fake = makeCombinedFake(); fake.granted = ["full-disk-access"]
        let registry = try makeRegistry(fake)
        _ = await registry.invokeAsync(commandID: "bookmarks.run", query: "bm import")

        _ = try await searchItems(registry, "warm")   // first search decodes → reads the blob
        let baseline = fake.cacheBlobReads
        for _ in 0..<10 { _ = try await searchItems(registry, "git") }
        XCTAssertEqual(fake.cacheBlobReads, baseline,
            "keystroke searches re-read the full cache blob — the version-keyed memo is not short-circuiting")
    }

    /// A re-import within the same wall-clock second still refreshes the cache: the
    /// memo keys on a monotonic version, not the second-resolution stamp (the fake's
    /// clock is fixed, so both imports share a stamp).
    @MainActor
    func testReimportSameInstantRefreshesCache() async throws {
        let fake = BookmarkFakeServices()
        fake.dirs[Self.chromeSupport] = ["Default"]
        fake.files["\(Self.chromeSupport)/Default/Bookmarks"] = Self.chromium("First", "https://first/")
        let registry = try makeRegistry(fake)
        _ = await registry.invokeAsync(commandID: "bookmarks.run", query: "bm import")
        let firstTitle = try await searchItems(registry, "").first?.title
        XCTAssertEqual(firstTitle, "First")

        // Same fixed clock (currentEpochSeconds is constant) → identical stamp.
        fake.files["\(Self.chromeSupport)/Default/Bookmarks"] = Self.chromium("Second", "https://second/")
        _ = await registry.invokeAsync(commandID: "bookmarks.run", query: "bm import")
        let after = try await searchItems(registry, "")
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.title, "Second", "re-import did not invalidate the cache memo")
    }

    // MARK: - Manifest + host.perms

    @MainActor
    func testManifestDeclaresFullDiskAccess() throws {
        let registry = try makeRegistry(makeCombinedFake())
        let meta = registry.record(id: "com.prosper.bookmarks")?.manifest.extension
        XCTAssertEqual(meta?.declaredPermissions, ["full-disk-access"])
        XCTAssertEqual(meta?.requiresFullDiskAccess, true)
    }

    private func installedRuntime(granting perms: Set<String> = []) throws -> LuaRuntime {
        let lua = try LuaRuntime()
        let fake = BookmarkFakeServices(); fake.granted = perms
        try ExtensionHost(extensionID: "com.test", services: fake).install(into: lua)
        return lua
    }

    func testPermsHasBridgesGrantState() throws {
        let lua = try installedRuntime(granting: ["full-disk-access"])
        try lua.run("""
        function probe()
            return tostring(host.perms.has('full-disk-access')) .. ',' ..
                   tostring(host.perms.has('nope'))
        end
        """)
        XCTAssertEqual(try lua.callGlobal("probe"), "true,false")
    }

    func testPermsHasDefaultsFalseForMinimalHost() throws {
        let lua = try installedRuntime()
        try lua.run("function probe() return tostring(host.perms.has('full-disk-access')) end")
        XCTAssertEqual(try lua.callGlobal("probe"), "false")
    }

    // MARK: - Native host.json codec

    func testNativeJSONDecodeTypesAndNullDropping() throws {
        let lua = try installedRuntime()
        try lua.run("""
        function probe()
            local t = host.json.decode('{"i":7,"f":2.5,"b":[true,false,null,3],"s":"hi","z":null}')
            return tostring(t.i)..'|'..tostring(t.f)..'|'..tostring(#t.b)..'|'..
                   tostring(t.b[1])..'|'..tostring(t.b[3])..'|'..t.s..'|'..tostring(t.z)
        end
        """)
        XCTAssertEqual(try lua.callGlobal("probe"), "7|2.5|3|true|3|hi|nil")
    }

    func testNativeJSONDecodeFragmentsAndTopLevelArray() throws {
        let lua = try installedRuntime()
        try lua.run("""
        function probe()
            local n = host.json.decode('42')
            local a = host.json.decode('[10,20,30]')
            return tostring(n)..'|'..tostring(#a)..'|'..tostring(a[2])
        end
        """)
        XCTAssertEqual(try lua.callGlobal("probe"), "42|3|20")
    }

    func testNativeJSONDecodeKeepsLargeIntegerPrecision() throws {
        let lua = try installedRuntime()
        try lua.run("""
        function probe() local t = host.json.decode('{"d":13312345678901234}') return tostring(t.d) end
        """)
        XCTAssertEqual(try lua.callGlobal("probe"), "13312345678901234")
    }

    func testNativeJSONDecodeMalformedReturnsNil() throws {
        let lua = try installedRuntime()
        try lua.run("function probe() return tostring(host.json.decode('{nope')) end")
        XCTAssertEqual(try lua.callGlobal("probe"), "nil")
    }

    func testNativeJSONEncodeObjectRoundTrips() throws {
        let lua = try installedRuntime()
        try lua.run("""
        function probe()
            local s = host.json.encode({ a = 1, b = "x", c = true, d = { 1, 2, 3 }, e = 2.5 })
            local t = host.json.decode(s)
            return tostring(t.a)..'|'..t.b..'|'..tostring(t.c)..'|'..
                   tostring(#t.d)..'|'..tostring(t.d[2])..'|'..tostring(t.e)
        end
        """)
        XCTAssertEqual(try lua.callGlobal("probe"), "1|x|true|3|2|2.5")
    }

    func testNativeJSONEncodeSequenceIsArray() throws {
        let lua = try installedRuntime()
        try lua.run("""
        function probe()
            local s = host.json.encode({ 10, 20, 30 })
            local t = host.json.decode(s)
            return s:sub(1, 1)..'|'..tostring(#t)..'|'..tostring(t[3])
        end
        """)
        XCTAssertEqual(try lua.callGlobal("probe"), "[|3|30")
    }

    func testNativeRenderSerialisesViewTree() throws {
        let lua = try installedRuntime()
        try lua.run("""
        function probe()
            local node = host.ui.render(host.ui.list{
                title = "T", style = "rows",
                items = { { id = "0", title = "A", url = "https://a/" } } })
            -- Verify via round-trip decode rather than substring match: the native
            -- encoder (JSONSerialization) escapes forward slashes ("https:\\/\\/a\\/"),
            -- which is valid JSON and decodes back cleanly.
            local t = host.json.decode(node)
            return node:sub(1, 1)..'|'..tostring(t.type)..'|'..tostring(t.items[1].url)
        end
        """)
        XCTAssertEqual(try lua.callGlobal("probe"), "{|list|https://a/")
    }
}
