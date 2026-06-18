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
    func prefGet(extensionID: String, key: String) -> String? { prefs[key] }
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
