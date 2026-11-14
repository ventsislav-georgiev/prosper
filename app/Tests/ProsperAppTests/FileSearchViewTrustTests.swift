import XCTest
@testable import ProsperApp

/// #1164: Open in Prosper on a hit the search marked viewable trusts the path (no second Launch Services
/// read, which can disagree with Spotlight on a name with no extension); the viewer's own refusal answers
/// for a non-text file. The viewer window is never built: the intake's `show` is a recorder.
@MainActor
final class FileSearchViewTrustTests: XCTestCase {

    /// An extensionless file of `bytes` in the row's own tempDir, and what the intake was asked to show.
    private func act(_ name: String, _ bytes: [UInt8], viewable: Bool) throws -> (url: URL, handled: Bool, shown: [String]) {
        let file = tempDir("fs-view-trust").appendingPathComponent(name)
        try Data(bytes).write(to: file)
        let intake = TextViewerIntake.shared
        let saved = (intake.isEnabled, intake.notifyOff, intake.show)
        defer { (intake.isEnabled, intake.notifyOff, intake.show) = saved }
        var shown: [String] = []
        intake.isEnabled = { true }
        intake.notifyOff = {}
        intake.show = { shown.append($0.lastPathComponent) }
        intake.ready()
        let handled = FileActions.perform(FileActions.ID.view, path: file.path, viewable: viewable)
        return (file, handled, shown)
    }

    private let binary: [UInt8] = [0x00, 0x01, 0x02]

    /// Content with a zero byte and no extension: the disk read says data, so unmarked it is not handled (as before).
    func testUnmarkedExtensionlessPathIsNotHandled() throws {
        let r = try act("blob", binary, viewable: false)
        XCTAssertFalse(r.handled)
        XCTAssertEqual(r.shown, [])
    }

    /// The same path marked viewable reaches the viewer's entry without the second look.
    func testMarkedExtensionlessPathReachesTheViewer() throws {
        let r = try act("blob", binary, viewable: true)
        XCTAssertTrue(r.handled)
        XCTAssertEqual(r.shown, ["blob"])
    }

    /// What the viewer answers for that file: its binary refusal with its message (the window shows
    /// `refusal.message`; the row reads the same load, no window).
    func testViewerRefusesTheMarkedBinaryFileWithItsMessage() throws {
        let r = try act("blob", binary, viewable: true)
        XCTAssertEqual(r.shown, ["blob"])
        guard case .failure(let refusal) = TextViewerDocument.load(r.url) else { return XCTFail("expected a refusal") }
        XCTAssertEqual(refusal, .binary)
        XCTAssertEqual(refusal.message, "This file looks binary (it holds a NUL byte).")
    }

    /// A marked path with an extension that is a document: handled and shown, as before.
    func testMarkedPathWithAnExtensionBehavesAsBefore() throws {
        let marked = try act("a.md", Array("# a\n".utf8), viewable: true)
        XCTAssertTrue(marked.handled)
        XCTAssertEqual(marked.shown, ["a.md"])
        let unmarked = try act("b.md", Array("# b\n".utf8), viewable: false)
        XCTAssertTrue(unmarked.handled)
        XCTAssertEqual(unmarked.shown, ["b.md"])
    }

    /// The dispatcher carries the mark: marked handled (and frecency recorded), unmarked not handled.
    func testDispatcherCarriesTheMark() throws {
        let file = tempDir("fs-view-trust-dispatch").appendingPathComponent("blob")
        try Data(binary).write(to: file)
        let intake = TextViewerIntake.shared
        let saved = (intake.isEnabled, intake.notifyOff, intake.show)
        defer { (intake.isEnabled, intake.notifyOff, intake.show) = saved }
        var shown: [String] = []
        intake.isEnabled = { true }
        intake.notifyOff = {}
        intake.show = { shown.append($0.lastPathComponent) }
        intake.ready()
        let frecency = FrecencyStore(defaults: scratchDefaults("view-trust"), storageKey: "k")
        let dispatcher = FileActionDispatcher(performer: LiveFileActionPerformer(), frecency: frecency)
        let now: TimeInterval = 1_700_000_000
        XCTAssertFalse(dispatcher.run(id: FileActions.ID.view, path: file.path, now: now))
        XCTAssertEqual(frecency.boost(path: file.path, now: now), 0)
        XCTAssertTrue(dispatcher.run(id: FileActions.ID.view, path: file.path, viewable: true, now: now))
        XCTAssertEqual(shown, ["blob"])
        XCTAssertGreaterThan(frecency.boost(path: file.path, now: now), 0)
    }
}

/// #1164 round 2: the runner's mark, and the trust given to a marked path with a non-text extension.
@MainActor
final class FileSearchViewTrustRunnerTests: XCTestCase {
    /// RunnerPanel.performFileAction is private with no seam: its call site uses this pure function.
    func testRunnerMarksOnlyFileView() {
        XCTAssertTrue(FileActions.runnerMark(FileActions.ID.view))
        for id in FileActions.ID.all.subtracting([FileActions.ID.view]) { XCTAssertFalse(FileActions.runnerMark(id), id) }
    }

    private func act(viewable: Bool) throws -> (handled: Bool, shown: [String]) {
        let file = tempDir("fs-view-trust-png").appendingPathComponent("x.png")
        try Data([0x00, 0x01, 0x02]).write(to: file)
        let intake = TextViewerIntake.shared
        let saved = (intake.isEnabled, intake.notifyOff, intake.show)
        defer { (intake.isEnabled, intake.notifyOff, intake.show) = saved }
        var shown: [String] = []
        intake.isEnabled = { true }
        intake.notifyOff = {}
        intake.show = { shown.append($0.lastPathComponent) }
        intake.ready()
        let handled = FileActions.perform(FileActions.ID.view, path: file.path, viewable: viewable)
        return (handled, shown)
    }

    /// Marked non-text extension: the viewer's entry is reached (its refusal answers).
    func testMarkedNonTextExtensionReachesTheViewer() throws {
        let r = try act(viewable: true)
        XCTAssertTrue(r.handled)
        XCTAssertEqual(r.shown, ["x.png"])
    }

    /// host.files.act passes no mark (LiveExtensionHostServices.filesAct uses run(id:path:)): not handled.
    func testUnmarkedNonTextPathIsStillNotHandled() throws {
        let r = try act(viewable: false)
        XCTAssertFalse(r.handled)
        XCTAssertEqual(r.shown, [])
    }
}
