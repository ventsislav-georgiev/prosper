import AppKit
import XCTest
@testable import ProsperApp

/// #980 (QA #57, QA #43): the caller `MenuBarSpacing.owningApps` through its three seams. Fakes only: no display
/// list, no menu bar read and no running-app lookup reaches the system. Fake pids sit above the highest pid
/// macOS hands out (99 999), so none can be this process.
final class MenuBarSeamTests: XCTestCase {
    /// A running app with a made-up bundle id (never a real process).
    private final class FakeApp: NSRunningApplication, @unchecked Sendable {
        private let bid: String?
        init(_ bid: String?) { self.bid = bid; super.init() }
        override var bundleIdentifier: String? { bid }
    }

    @MainActor private final class Record {
        var reads = 0
        var placed: [CGDirectDisplayID] = []
        var asked: [pid_t] = []
    }

    @MainActor
    private func install(_ rec: Record, displays: [CGDirectDisplayID], owners: [CGDirectDisplayID: [pid_t]],
                         apps: [pid_t: String?]) {
        MenuBarSpacing.activeDisplays = { displays }
        MenuBarSpacing.readOwners = {
            rec.reads += 1
            return { display in rec.placed.append(display); return owners[display] ?? [] }
        }
        MenuBarSpacing.runningApp = { pid in
            rec.asked.append(pid)
            guard let bid = apps[pid] else { return nil }
            return FakeApp(bid)
        }
    }

    /// Two displays, the first's owners first: pid 0 and our own pid are never looked up, an owner seen on both
    /// displays is looked up once, a pid with no app is dropped, the three system-managed owners are skipped and
    /// an app without a bundle id is kept.
    @MainActor
    func testOwningAppsWalksBothDisplaysInOrderAndDropsZeroOwnPidAndTheSkipList() {
        let saved = (MenuBarSpacing.activeDisplays, MenuBarSpacing.readOwners, MenuBarSpacing.runningApp)
        defer {
            MenuBarSpacing.activeDisplays = saved.0
            MenuBarSpacing.readOwners = saved.1
            MenuBarSpacing.runningApp = saved.2
        }
        let me = getpid(), rec = Record()
        install(rec, displays: [7, 9],
                owners: [7: [900_001, 0, me, 900_002, 900_005], 9: [900_003, 900_001, 900_006, 900_004, 900_007]],
                apps: [900_001: "com.example.alpha", 900_002: "com.apple.controlcenter", 900_003: nil,
                       900_005: "com.apple.Spotlight", 900_006: "com.apple.MenuBarAgent", 900_007: "com.example.beta",
                       me: "com.example.self", 0: "com.example.zero"])
        let apps = MenuBarSpacing.owningApps()
        XCTAssertEqual(apps.map { $0.bundleIdentifier ?? "<none>" }, ["com.example.alpha", "<none>", "com.example.beta"])
        XCTAssertEqual(rec.asked, [900_001, 900_002, 900_005, 900_003, 900_006, 900_004, 900_007],
                       "union order, first sighting wins; pid 0 and our own pid never looked up")
        XCTAssertEqual(rec.placed, [7, 9], "every display, in the list's order")
        XCTAssertEqual(rec.reads, 1)
    }

    /// QA #43: one read of the bar per call, placed on each display (two displays, two calls: two reads, four
    /// placings), with the same result each time.
    @MainActor
    func testOwningAppsReadsTheBarOncePerCallForTwoDisplays() {
        let saved = (MenuBarSpacing.activeDisplays, MenuBarSpacing.readOwners, MenuBarSpacing.runningApp)
        defer {
            MenuBarSpacing.activeDisplays = saved.0
            MenuBarSpacing.readOwners = saved.1
            MenuBarSpacing.runningApp = saved.2
        }
        let rec = Record()
        install(rec, displays: [3, 5], owners: [3: [900_011], 5: [900_012, 900_011]],
                apps: [900_011: "com.example.one", 900_012: "com.example.two"])
        let first = MenuBarSpacing.owningApps().map { $0.bundleIdentifier ?? "<none>" }
        XCTAssertEqual(rec.reads, 1, "two displays, one read")
        XCTAssertEqual(rec.placed, [3, 5])
        let second = MenuBarSpacing.owningApps().map { $0.bundleIdentifier ?? "<none>" }
        XCTAssertEqual(first, ["com.example.one", "com.example.two"])
        XCTAssertEqual(second, first)
        XCTAssertEqual(rec.reads, 2, "one read per call")
        XCTAssertEqual(rec.placed, [3, 5, 3, 5])
    }

    // MARK: - #980 M3 and QA #49: the manager's activation debounce, room reader and length sink

    /// The one place a test builds the manager: bare, never set up, so no status item exists (the sink's item
    /// argument is nil) and nothing touches the system bar.
    @MainActor
    private func bareManager() -> MenuBarManager {
        let m = MenuBarManager()
        return m
    }

    /// A scheduler that only records: it never reaches a queue and never waits.
    @MainActor private final class FakeScheduler {
        var items: [DispatchWorkItem] = []
        var ran = 0
    }

    /// M3: two activations, the fake holds two items and only the first is cancelled; performing the live ones
    /// runs exactly one block; a third activation adds an item and the total is two. "Ran" is the work item's own
    /// completion, seen through its notify block (a bare manager's block returns before any room read, so no
    /// Accessibility call happens).
    @MainActor
    func testActivationBurstCancelsThePreviousItemAndRunsOnlyTheLast() {
        let m = bareManager(), fake = FakeScheduler()
        m.scheduleActivation = { fake.items.append($0) }
        @MainActor func perform(live item: DispatchWorkItem) {
            guard !item.isCancelled else { return }
            let exp = XCTestExpectation(description: "item done")
            item.notify(queue: .main) { MainActor.assumeIsolated { fake.ran += 1 }; exp.fulfill() }
            item.perform()
            wait(for: [exp], timeout: 5)   // a failure bound only: the notify fires as soon as perform returns
        }
        m.scheduleActivationReapply()
        m.scheduleActivationReapply()
        XCTAssertEqual(fake.items.count, 2)
        XCTAssertEqual(fake.items.map(\.isCancelled), [true, false], "the pending item is cancelled by the next activation")
        fake.items.forEach { perform(live: $0) }
        XCTAssertEqual(fake.ran, 1, "a burst runs only the last item")
        m.scheduleActivationReapply()
        XCTAssertEqual(fake.items.count, 3)
        XCTAssertEqual(fake.items.last?.isCancelled, false)
        if let third = fake.items.last { perform(live: third) }
        XCTAssertEqual(fake.ran, 2)
    }

    /// QA #49 (hosted path; this Mac's OS decides it: MenuBarHost.isHosted is the OS major version >= 27, no seam
    /// needed, and the row skips on an older OS): the length the sink gets for a room the reader returns. The
    /// reader ignores its argument; the item is nil on a bare manager. 980 = max(0, 1000 - 20); a room that is
    /// not finite, zero or negative gives 0 (max keeps its first argument when the second is NaN or smaller).
    @MainActor
    func testHostedDividerLengthFollowsTheRoomReaderThroughTheSink() throws {
        try XCTSkipUnless(MenuBarHost.isHosted, "windowed bars take no room")
        let cases: [(room: CGFloat, length: CGFloat)] = [(1000, 980), (.nan, 0), (0, 0), (-5, 0)]
        for c in cases {
            let m = bareManager()
            var asked = 0, sunk: [(item: Bool, length: CGFloat)] = []
            m.readRoom = { _ in asked += 1; return c.room }
            m.setSeparatorLength = { item, length in sunk.append((item != nil, length)) }
            m.setRevealed(false)
            XCTAssertEqual(asked, 1, "room \(c.room): one read per apply")
            XCTAssertEqual(sunk.count, 1)
            XCTAssertEqual(sunk.last?.item, false, "bare manager: no status item")
            XCTAssertTrue(sunk.last?.length == c.length, "room \(c.room) gives \(c.length), got \(String(describing: sunk.last?.length))")
        }
    }
}
