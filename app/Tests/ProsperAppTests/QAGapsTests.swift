import XCTest
@testable import ProsperApp
@testable import StatsCore

/// #1002: QA #64 (ContextPane TCC refresh), QA #71 (stats order dedupe),
/// QA #80 (runner ↑/↓), QA #206 (media key codes).
final class QAGapsTests: XCTestCase {

    // MARK: - QA #64: only the newest TCC refresh publishes

    @MainActor
    private final class Applied { var rows: [String] = [] }

    @MainActor
    func testContextTCCOlderRefreshLandingLastIsDropped() async {
        let saved = ContextTCC.probe
        ContextTCC.probe = { (screen: false, ax: false) }
        _ = ContextTCC.last.value   // seed through the fake, never a real preflight

        let hold = DispatchSemaphore(value: 0)
        let applied = Applied()
        ContextTCC.probe = { hold.wait(); return (screen: false, ax: false) }
        let older = ContextTCC.refresh { s, a in applied.rows.append("older \(s) \(a)") }
        ContextTCC.probe = { (screen: true, ax: true) }
        let newer = ContextTCC.refresh { s, a in applied.rows.append("newer \(s) \(a)") }
        await newer.value
        XCTAssertEqual(applied.rows, ["newer true true"])

        hold.signal()   // the older probe returns only now, after the newer one published
        await older.value
        ContextTCC.probe = saved
        XCTAssertEqual(applied.rows, ["newer true true"], "a stale refresh must not overwrite the newer grant state")
        XCTAssertTrue(ContextTCC.last.value.screen)
        XCTAssertTrue(ContextTCC.last.value.ax)
    }

    // MARK: - QA #71: a duplicate in the saved order keeps its first slot only

    private func loadedOrder(_ order: [String]) throws -> [String] {
        var style = StatsWidgetStyle.default
        style.order = order
        let d = scratchDefaults("qagaps-stats-order")
        d.set(try JSONEncoder().encode(style), forKey: "systemStatsWidgetStyle")
        return SystemStatsStore.load(from: d).order
    }

    func testStatsOrderWithoutDuplicatesIsUnchanged() throws {
        XCTAssertEqual(try loadedOrder(["gpu", "cpu", "memory", "disk", "network", "sensors", "power", "battery"]),
                       ["gpu", "cpu", "memory", "disk", "network", "sensors", "power", "battery"])
    }

    func testStatsOrderOneDuplicateKeepsTheFirst() throws {
        XCTAssertEqual(try loadedOrder(["cpu", "memory", "cpu", "gpu"]),
                       ["cpu", "memory", "gpu", "disk", "network", "sensors", "power", "battery"])
    }

    func testStatsOrderAllDuplicates() throws {
        XCTAssertEqual(try loadedOrder(["battery", "battery", "battery"]),
                       ["battery", "cpu", "memory", "disk", "gpu", "network", "sensors", "power"])
        XCTAssertEqual(try loadedOrder(["power", "cpu", "memory", "disk", "gpu", "network", "sensors", "battery",
                                        "power", "cpu", "memory", "disk", "gpu", "network", "sensors", "battery"]),
                       ["power", "cpu", "memory", "disk", "gpu", "network", "sensors", "battery"])
    }

    func testStatsOrderUnknownIdNextToADuplicate() throws {
        XCTAssertEqual(try loadedOrder(["bogus", "disk", "bogus", "disk", "cpu"]),
                       ["disk", "cpu", "memory", "gpu", "network", "sensors", "power", "battery"])
    }

    /// What the menu bar walks: CPU and RAM on (the defaults), CPU saved twice.
    func testStatsDuplicateNeverReachesEnabledModules() throws {
        var style = StatsWidgetStyle.default
        style.order = ["cpu", "memory", "cpu"]
        let d = scratchDefaults("qagaps-stats-enabled")
        d.set(try JSONEncoder().encode(style), forKey: "systemStatsWidgetStyle")
        XCTAssertEqual(SystemStatsStore.load(from: d).enabledModules, [.cpu, .memory])
    }

    // MARK: - QA #80: ↑/↓ step signs, and the row count is read inside the hop

    @MainActor
    private func drainMain() {
        let e = expectation(description: "main queue turn")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 5)
    }

    @MainActor
    func testRunnerSelectPrevStepsBackAndSelectNextForward() {
        let model = RunnerModel()
        model.selectedIndex = 2
        model.selectPrev { 5 }
        drainMain()
        XCTAssertEqual(model.selectedIndex, 1)
        model.selectNext { 5 }
        model.selectNext { 5 }
        drainMain()
        XCTAssertEqual(model.selectedIndex, 3)
        model.selectedIndex = 0
        model.selectPrev { 5 }
        drainMain()
        XCTAssertEqual(model.selectedIndex, 4)
    }

    @MainActor
    func testRunnerRowCountIsReadInsideTheHop() {
        let model = RunnerModel()
        model.selectedIndex = 3
        var rows = 4
        model.selectNext { rows }
        rows = 5   // results grew before the hop ran
        drainMain()
        XCTAssertEqual(model.selectedIndex, 4, "(3 + 1) % 5; a count read before the hop wraps to 0")
    }

    // MARK: - QA #206: twelve media keys, twelve distinct codes

    func testMediaKeyTableHasTwelveDistinctCodes() {
        XCTAssertEqual(MediaKey.nameToCode, [
            "SOUND_UP": 0, "SOUND_DOWN": 1, "BRIGHTNESS_UP": 2, "BRIGHTNESS_DOWN": 3,
            "MUTE": 7, "PLAY": 16, "NEXT": 17, "PREVIOUS": 18, "FAST": 19, "REWIND": 20,
            "ILLUMINATION_UP": 21, "ILLUMINATION_DOWN": 22,
        ])
        let codes = Set(MediaKey.nameToCode.values)
        XCTAssertEqual(codes, [0, 1, 2, 3, 7, 16, 17, 18, 19, 20, 21, 22])
        XCTAssertEqual(codes.count, 12)
        // codeToName is built with uniqueKeysWithValues: a shared code would trap there.
        guard codes.count == MediaKey.nameToCode.count else { return }
        XCTAssertEqual(MediaKey.codeToName, [
            0: "SOUND_UP", 1: "SOUND_DOWN", 2: "BRIGHTNESS_UP", 3: "BRIGHTNESS_DOWN",
            7: "MUTE", 16: "PLAY", 17: "NEXT", 18: "PREVIOUS", 19: "FAST", 20: "REWIND",
            21: "ILLUMINATION_UP", 22: "ILLUMINATION_DOWN",
        ])
        XCTAssertEqual(MediaKey.code(forName: "play"), 16)
        XCTAssertEqual(MediaKey.name(forCode: 22), "ILLUMINATION_DOWN")
        XCTAssertTrue(MediaKey.code(forName: "EJECT") == nil)
        XCTAssertTrue(MediaKey.name(forCode: 4) == nil)
    }
}
