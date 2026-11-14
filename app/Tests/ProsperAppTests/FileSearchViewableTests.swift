import XCTest
@testable import ProsperApp

/// #1148: a file-search hit carries `viewable` — the Text Viewer's own rule (TextViewerRouting.isDocument)
/// over the name, with Spotlight's type tree for an extensionless name — and the shipped `files` extension
/// offers "Open in Prosper" exactly on viewable hits. Values only: no Spotlight, no window, nothing opened.
/// Type trees are literals (a type differs between macOS versions), never asked of the system.
@MainActor
final class FileSearchViewableTests: XCTestCase {

    private static let home = "/Users/example"
    private static let plainText = ["public.plain-text", "public.text", "public.data", "public.item", "public.content"]

    private func file(_ name: String, _ tree: [String], isDir: Bool = false) -> FileSearchEngine.IndexedFile {
        FileSearchEngine.IndexedFile(path: "\(Self.home)/\(name)", contentTypeTree: tree, isDir: isDir)
    }

    private func viewableNames(_ files: [FileSearchEngine.IndexedFile]) -> Set<String> {
        Set(files.map { $0.candidate(home: Self.home).hit }.filter(\.viewable).map(\.name))
    }

    /// The literal corpus: what the viewer shows next to what it does not.
    private func corpus() -> [FileSearchEngine.IndexedFile] {
        [
            file("server.log", ["com.apple.log", "public.plain-text", "public.log", "public.text", "public.data"]),
            file("main.swift", ["public.swift-source", "public.source-code", "public.plain-text", "public.text"]),
            file("script.py", ["public.python-script", "public.shell-script", "public.script", "public.source-code"]),
            file("notes.md", ["net.daringfireball.markdown", "public.plain-text", "public.text"]),
            file("todo.txt", Self.plainText),
            file("README", Self.plainText),                                    // extensionless, typed plain text
            file("photo.png", ["public.png", "public.image", "public.data", "public.item"]),
            file("report.pdf", ["com.adobe.pdf", "public.composite-content", "public.data", "public.item"]),
            file("page.html", ["public.html", "public.text", "public.data", "public.item"]),
            file("Projects", ["public.folder", "public.directory", "public.item"], isDir: true),
            file("docs.md", ["public.folder", "public.directory", "public.item"], isDir: true),  // a folder named .md
            file("Notes.app", ["com.apple.application-bundle", "com.apple.application", "com.apple.bundle",
                               "public.package", "public.directory", "public.item"]),
            file("tool", ["public.unix-executable", "public.data", "public.executable", "public.item"]),  // binary
            file("data.zzq", ["dyn.ah62d4rv4ge80e5pe", "public.data", "public.item"]),             // unknown extension
        ]
    }

    func testViewableIsPinnedForALiteralListOfNamesAndTypes() {
        XCTAssertEqual(viewableNames(corpus()),
                       ["server.log", "main.swift", "script.py", "notes.md", "todo.txt", "README"])
    }

    /// Spotlight can return an item without a type tree: a name with an extension still decides by it, an
    /// extensionless name is not viewable (nothing else is read).
    func testEmptyTypeTreeDecidesByTheNameAlone() {
        let files = ["server.log", "notes.md", "README", "photo.png", "tool"].map { file($0, []) }
        XCTAssertEqual(viewableNames(files), ["server.log", "notes.md"])
    }

    /// R2-1: an extensionless name decides on the whole tree, in any order: plain text anywhere is
    /// viewable, an HTML type anywhere is not, identifiers no type knows count as nothing.
    func testExtensionlessTreeIsReadInAnyOrder() {
        let files = [
            file("README", Array(Self.plainText.reversed())),
            file("NOTES", ["public.item", "public.data", "public.plain-text"]),
            file("index", ["public.plain-text", "public.text", "public.html", "public.data"]),
            file("blob", ["com.example.unknown-a", "com.example.unknown-b"]),
        ]
        XCTAssertEqual(viewableNames(files), ["README", "NOTES"])
    }

    func testSearchJSONCarriesTheFlag() async throws {
        var q = FileSearchEngine.FileQuery(); q.name = "server"; q.scope = Self.home
        let index = MockFileIndex([file("server.log", []), file("server.png", ["public.png", "public.image"])])
        let json = await FileSearchEngine.searchJSON(q, index: index,
                                                     frecency: FrecencyStore(defaults: scratchDefaults("viewable-json"), storageKey: "k"),
                                                     now: 1_700_000_000)
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        var flags: [String: Bool] = [:]
        for row in rows { if let n = row["name"] as? String { flags[n] = row["viewable"] as? Bool } }
        XCTAssertEqual(flags, ["server.log": true, "server.png": false])
    }

    // MARK: - The shipped files extension reads the flag

    private final class RowServices: ExtensionHostServices, @unchecked Sendable {
        var rows = "[]"
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
        func filesSearch(_ optsJSON: String) async -> String { rows }
    }

    /// Runs the shipped files.run over `rows` (hit JSON objects) and returns the launch paths of the rows
    /// that offer file.view, plus the action ids of each row.
    private func viewRows(_ rows: [[String: Any]]) async throws -> (view: Set<String>, actions: [[String]]) {
        let svc = RowServices()
        svc.rows = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: rows), encoding: .utf8))
        let extensions = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        let registry = ExtensionRegistry(systemDir: extensions, userDir: tempDir("viewable-files-ext"),
                                         defaults: scratchDefaults("viewable-files"), services: svc)
        registry.discover()
        let raw = await registry.invokeAsync(commandID: "files.run", query: "f any")
        let out = try XCTUnwrap(raw)
        guard case .list(let list) = try ExtensionViewNode.decode(json: out) else {
            XCTFail("expected a list"); return ([], [])
        }
        XCTAssertEqual(list.items.count, rows.count)
        let view = Set(list.items.filter { $0.allActions.contains { $0.id == FileActions.ID.view } }.compactMap(\.launch))
        return (view, list.items.map { $0.allActions.map(\.id) })
    }

    /// End to end over the engine's own hits: Open in Prosper exactly on the viewable ones, after Reveal.
    func testFilesExtensionOffersOpenInProsperExactlyOnViewableHits() async throws {
        let rows = corpus().map { $0.candidate(home: Self.home).hit.jsonObject }
        let r = try await viewRows(rows)
        XCTAssertEqual(r.view, Set(["server.log", "main.swift", "script.py", "notes.md", "todo.txt", "README"]
            .map { "\(Self.home)/\($0)" }))
        XCTAssertEqual(r.actions.first?.prefix(3).map { $0 }, [FileActions.ID.open, FileActions.ID.reveal, FileActions.ID.view])
    }

    /// An older or third-party host builds a hit without the field: no Open in Prosper, as for a
    /// non-viewable row, whatever the name says. A non-boolean value is not true either.
    func testHitWithoutTheFieldGetsNoOpenInProsper() async throws {
        let rows: [[String: Any]] = [
            ["name": "notes.md", "path": "/Users/example/notes.md", "isDir": false, "kind": "Markdown"],
            ["name": "todo.txt", "path": "/Users/example/todo.txt", "isDir": false, "kind": "Plain Text",
             "viewable": "true"],
            ["name": "server.log", "path": "/Users/example/server.log", "isDir": false, "kind": "Log",
             "viewable": true],
        ]
        let r = try await viewRows(rows)
        XCTAssertEqual(r.view, ["/Users/example/server.log"])
    }

    // MARK: - The viewer's own gate still decides

    /// file.view from a viewable hit goes through TextViewerIntake.receive, whose isEnabled gate
    /// (TextViewerRouting.swift, the Text Viewer extension live) decides: off posts the notice and
    /// shows nothing, on shows the file. Intake seams only: no window.
    func testViewerGateStillDecidesForAViewableHit() throws {
        let path = tempDir("viewable-gate").appendingPathComponent("server.log")
        try Data("line\n".utf8).write(to: path)
        let hit = FileSearchEngine.IndexedFile(path: path.path).candidate(home: Self.home).hit
        XCTAssertTrue(hit.viewable)
        let intake = TextViewerIntake.shared
        let saved = (intake.isEnabled, intake.notifyOff, intake.show)
        defer { (intake.isEnabled, intake.notifyOff, intake.show) = saved }
        var shown: [String] = [], notices = 0
        intake.isEnabled = { false }
        intake.notifyOff = { notices += 1 }
        intake.show = { shown.append($0.lastPathComponent) }
        intake.ready()
        FileActions.perform(FileActions.ID.view, path: hit.path)
        XCTAssertEqual(notices, 1, "extension off: the notice")
        XCTAssertEqual(shown, [], "extension off: nothing shown")
        intake.isEnabled = { true }
        FileActions.perform(FileActions.ID.view, path: hit.path)
        XCTAssertEqual(shown, ["server.log"])
    }
}
