import XCTest
@testable import ProsperApp

/// Coverage for `FileActions`' pure routing/classification logic. The actual OS
/// operations (NSWorkspace open/reveal, pasteboard, trash, qlmanage) are thin
/// `@MainActor` wrappers verified by QA / e2e; here we lock the dispatch rules
/// the runner and host depend on.
final class FileActionsTests: XCTestCase {

    func testBuiltInIdsRecognized() {
        for id in [FileActions.ID.open, FileActions.ID.reveal, FileActions.ID.quickLook,
                   FileActions.ID.copyPath, FileActions.ID.copyFile, FileActions.ID.openWith,
                   FileActions.ID.enclosingFolder, FileActions.ID.trash] {
            XCTAssertTrue(FileActions.isBuiltIn(id), "\(id) should be built-in")
        }
        XCTAssertTrue(FileActions.isBuiltIn(FileActions.ID.view), "#1106 Open in Prosper")
        XCTAssertEqual(FileActions.ID.view, "file.view")
        XCTAssertFalse(FileActions.isBuiltIn("custom.action"))
        XCTAssertFalse(FileActions.isBuiltIn(""))
    }

    /// Regression (#057): a custom row action id used to be handed to
    /// `FileActions.perform`, which drops anything outside the reserved set — the
    /// action silently did nothing. It must resolve to the locked mode's command id.
    func testCustomActionIdRoutesToOwningExtension() {
        let mode = RunnerMode.ext(id: "brew.run", title: "Brew", icon: "shippingbox")
        XCTAssertEqual(FileActions.extensionTarget(actionID: "upgrade", mode: mode), "brew.run")
        // Reserved ids stay native even inside an extension mode.
        XCTAssertNil(FileActions.extensionTarget(actionID: FileActions.ID.open, mode: mode))
        XCTAssertNil(FileActions.extensionTarget(actionID: FileActions.ID.quickLook, mode: mode))
        // No owning extension (universal launcher) or a blank id → nothing to dispatch.
        XCTAssertNil(FileActions.extensionTarget(actionID: "upgrade", mode: .universal))
        XCTAssertNil(FileActions.extensionTarget(
            actionID: "upgrade",
            mode: .ext(id: "", title: "", icon: "")))
    }

    func testQuickLookKeepsRunnerOpenOthersDismiss() {
        XCTAssertFalse(FileActions.dismissesRunner(FileActions.ID.quickLook))
        XCTAssertTrue(FileActions.dismissesRunner(FileActions.ID.open))
        XCTAssertTrue(FileActions.dismissesRunner(FileActions.ID.reveal))
        XCTAssertTrue(FileActions.dismissesRunner(FileActions.ID.trash))
    }

    func testEngagementIdsAreTheUsageActions() {
        // Open / reveal / quick look / open-with / enclosing folder count toward
        // frecency; copy and trash do not.
        XCTAssertTrue(FileActions.engagementIDs.contains(FileActions.ID.open))
        XCTAssertTrue(FileActions.engagementIDs.contains(FileActions.ID.reveal))
        XCTAssertTrue(FileActions.engagementIDs.contains(FileActions.ID.quickLook))
        XCTAssertTrue(FileActions.engagementIDs.contains(FileActions.ID.view))
        XCTAssertFalse(FileActions.engagementIDs.contains(FileActions.ID.copyPath))
        XCTAssertFalse(FileActions.engagementIDs.contains(FileActions.ID.copyFile))
        XCTAssertFalse(FileActions.engagementIDs.contains(FileActions.ID.trash))
    }

    @MainActor
    func testPerformRejectsUnknownIdAndEmptyPath() {
        XCTAssertFalse(FileActions.perform("not.a.file.action", path: "/tmp/x"))
        XCTAssertFalse(FileActions.perform(FileActions.ID.open, path: ""))
    }
}

/// #1106 (design #1105 D4): the shipped `files` extension offers "Open in Prosper" (file.view) only
/// on Markdown and plain-text rows, after Reveal, and the native action opens only a text document.
@MainActor
final class FileActionsViewRowTests: XCTestCase {

    /// Host services whose Spotlight search returns `rows`; nothing else does anything.
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

    private func extensionsDir() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
    }

    func testViewIsOfferedOnlyOnDocumentRows() async throws {
        let paths: [(String, Bool)] = [
            ("/Users/example/notes.md", false), ("/Users/example/README.MD", false), ("/Users/example/todo.txt", false),
            ("/Users/example/a.b.markdown", false), ("/Users/example/page.html", false), ("/Users/example/photo.png", false),
            ("/Users/example/report.pdf", false), ("/Users/example/Makefile", false), ("/Users/example/.md", false),
            ("/Users/example/docs.md", true),
        ]
        let svc = RowServices()
        let rows = paths.map { ["name": ($0.0 as NSString).lastPathComponent, "path": $0.0, "display": $0.0,
                                "isDir": $0.1, "kind": "Document"] as [String: Any] }
        svc.rows = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: rows), encoding: .utf8))
        let registry = ExtensionRegistry(systemDir: extensionsDir(), userDir: tempDir("tv-files-ext"),
                                         defaults: scratchDefaults("tv-files"), services: svc)
        registry.discover()
        XCTAssertNotNil(registry.command(id: "files.run"), "the shipped files extension")
        let raw = await registry.invokeAsync(commandID: "files.run", query: "f notes")
        let out = try XCTUnwrap(raw)
        guard case .list(let list) = try ExtensionViewNode.decode(json: out) else { return XCTFail("expected a list") }
        XCTAssertEqual(list.items.count, paths.count)
        let viewable = Set(list.items.filter { $0.allActions.contains { $0.id == FileActions.ID.view } }.compactMap(\.launch))
        XCTAssertEqual(viewable, ["/Users/example/notes.md", "/Users/example/README.MD", "/Users/example/todo.txt",
                                  "/Users/example/a.b.markdown"])
        let first = try XCTUnwrap(list.items.first)
        XCTAssertEqual(first.allActions.prefix(3).map(\.id), [FileActions.ID.open, FileActions.ID.reveal, FileActions.ID.view],
                       "Open stays primary and Reveal secondary")
        XCTAssertEqual(first.allActions.first { $0.id == FileActions.ID.view }?.title, "Open in Prosper")
    }

    /// D14: the Text Viewer ships as a system extension, enabled by default, with its info row.
    func testTextViewerExtensionShipsEnabledWithItsInfoRow() throws {
        let registry = ExtensionRegistry(systemDir: extensionsDir(), userDir: tempDir("tv-ext"),
                                         defaults: scratchDefaults("tv-ext"), services: RowServices())
        registry.discover()
        let record = try XCTUnwrap(registry.record(id: "com.prosper.textviewer"))
        XCTAssertTrue(record.isLive, "enabled by default: it acts only on a file the user opens")
        XCTAssertEqual(record.manifest.extension.system, true)
        let section = try XCTUnwrap(record.manifest.contributes?.allSettingsSections.first)
        XCTAssertEqual(section.title, "Text Viewer")
        XCTAssertEqual(section.controls?.map(\.kind), [.info])
        XCTAssertEqual(section.controls?.first?.title, "Open Markdown and text files from Finder's Open With menu")
    }

    /// Every extension the Lua row treats as viewable is a document to the native router.
    func testLuaViewableExtensionsAreDocuments() {
        for ext in ["md", "markdown", "mdown", "mkd", "txt", "text", "MD"] {
            XCTAssertTrue(TextViewerRouting.isDocument(URL(fileURLWithPath: "/Users/example/a.\(ext)")), ext)
        }
    }

    /// host.files.act can name any path: file.view opens only a text document, through the intake.
    func testViewActionOpensOnlyDocuments() throws {
        let dir = tempDir("tv-files-act")
        let md = dir.appendingPathComponent("a.md"), png = dir.appendingPathComponent("b.png")
        try Data("# a\n".utf8).write(to: md)
        try Data([0x89, 0x50]).write(to: png)
        let intake = TextViewerIntake.shared
        let saved = (intake.isEnabled, intake.notifyOff, intake.show)
        defer { (intake.isEnabled, intake.notifyOff, intake.show) = saved }
        var shown: [URL] = []
        intake.isEnabled = { true }
        intake.notifyOff = {}
        intake.show = { shown.append($0) }
        intake.ready()
        XCTAssertTrue(FileActions.perform(FileActions.ID.view, path: md.path))
        XCTAssertTrue(FileActions.perform(FileActions.ID.view, path: png.path))
        XCTAssertEqual(shown.map(\.lastPathComponent), ["a.md"])
    }
}

/// Records every action it's asked to perform, so the dispatcher's effects can be
/// asserted without touching the real OS (mocked UI interaction).
final class MockFileActionPerformer: FileActionPerforming, @unchecked Sendable {
    var calls: [(id: String, path: String)] = []
    /// Whether `perform` reports the action as handled (a recognized built-in).
    var handled = true
    @MainActor func perform(_ id: String, path: String) -> Bool {
        calls.append((id, path)); return handled
    }
}

/// The dispatcher couples an action to its side effects (perform + frecency bump);
/// tested here with a mock performer and an isolated frecency store.
@MainActor
final class FileActionDispatcherTests: XCTestCase {

    private func isolatedFrecency() -> FrecencyStore {
        let d = scratchDefaults("dispatch-frecency")
        return FrecencyStore(defaults: d, storageKey: "k")
    }

    func testEngagementActionPerformsAndRecordsFrecency() {
        let mock = MockFileActionPerformer()
        let frecency = isolatedFrecency()
        let dispatcher = FileActionDispatcher(performer: mock, frecency: frecency)
        let now: TimeInterval = 1_700_000_000

        dispatcher.run(id: FileActions.ID.open, path: "/a/x.txt", now: now)

        XCTAssertEqual(mock.calls.map(\.id), [FileActions.ID.open])
        XCTAssertEqual(mock.calls.first?.path, "/a/x.txt")
        XCTAssertGreaterThan(frecency.boost(path: "/a/x.txt", now: now), 0)  // engagement recorded
    }

    func testNonEngagementActionPerformsButSkipsFrecency() {
        let mock = MockFileActionPerformer()
        let frecency = isolatedFrecency()
        let dispatcher = FileActionDispatcher(performer: mock, frecency: frecency)
        let now: TimeInterval = 1_700_000_000

        dispatcher.run(id: FileActions.ID.copyPath, path: "/a/x.txt", now: now)
        dispatcher.run(id: FileActions.ID.trash, path: "/a/y.txt", now: now)

        XCTAssertEqual(mock.calls.map(\.id), [FileActions.ID.copyPath, FileActions.ID.trash])
        XCTAssertEqual(frecency.boost(path: "/a/x.txt", now: now), 0)  // copy isn't an engagement
        XCTAssertEqual(frecency.boost(path: "/a/y.txt", now: now), 0)  // nor is trash
    }

    func testUnhandledActionDoesNotRecordFrecency() {
        let mock = MockFileActionPerformer(); mock.handled = false
        let frecency = isolatedFrecency()
        let dispatcher = FileActionDispatcher(performer: mock, frecency: frecency)
        let now: TimeInterval = 1_700_000_000

        let handled = dispatcher.run(id: FileActions.ID.open, path: "/a/x.txt", now: now)

        XCTAssertFalse(handled)
        XCTAssertEqual(frecency.boost(path: "/a/x.txt", now: now), 0)  // not handled → no bump
    }
}
