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
        XCTAssertFalse(FileActions.isBuiltIn("custom.action"))
        XCTAssertFalse(FileActions.isBuiltIn(""))
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
        let suite = "dispatch-frecency-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
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
