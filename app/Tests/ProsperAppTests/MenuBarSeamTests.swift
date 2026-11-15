import AppKit
import XCTest
@testable import ProsperApp

/// #980 (QA #57, QA #43): the caller `MenuBarSpacing.owningApps` through its three seams. Fakes only: no display
/// list, no menu bar read and no running-app lookup reaches the system. Fake pids sit above the highest pid
/// macOS hands out (99 999), so none can be this process.
final class MenuBarSeamTests: XCTestCase {
    /// A running app with a made-up bundle id (never a real process).
    private final class FakeApp: NSRunningApplication {
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
}
