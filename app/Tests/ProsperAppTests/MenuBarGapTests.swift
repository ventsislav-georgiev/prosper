import XCTest
@testable import ProsperApp

/// #980 (QA #7): the dismisser's owner-pid decision, fed literal window-list entries. No row reads the
/// live window list: `info` is a local closure, run synchronously on the test's thread by the call.
final class MenuBarGapTests: XCTestCase {
    private let pidKey = kCGWindowOwnerPID as String
    private let boundsKey = kCGWindowBounds as String
    private let layerKey = kCGWindowLayer as String

    /// The decision with `entries` as the read's answer; `reads` counts the read and `asked` keeps the id.
    private func owner(_ n: Int, _ entries: [[String: Any]]?) -> (pid: pid_t?, reads: Int, asked: CGWindowID?) {
        var reads = 0, asked: CGWindowID?
        let pid = PopoverOutsideClickDismisser.ownerPID(windowNumber: n) { id in
            reads += 1; asked = id
            return entries
        }
        return (pid, reads, asked)
    }

    /// The window at the point is the system's pick; its entry is the first. A later entry never wins.
    func testTheFirstEntrysOwnerWins() {
        let r = owner(9, [[pidKey: 4242, layerKey: 0], [pidKey: 77, layerKey: 25]])
        XCTAssertEqual(r.pid, 4242)
        XCTAssertEqual(r.reads, 1)
        XCTAssertEqual(r.asked, 9, "the read asks for the window at the point")
    }

    /// A point in no window (number 0, or a negative one): nil, and the list is never read.
    func testAPointInNoWindowGivesNilWithoutARead() {
        for n in [0, -1, Int.min] {
            let r = owner(n, [[pidKey: 4242]])
            XCTAssertTrue(r.pid == nil, "window \(n)")
            XCTAssertEqual(r.reads, 0, "window \(n) must not be read")
        }
    }

    /// A window number past CGWindowID is outside data: nil, no read, no trap.
    func testAWindowNumberPastCGWindowIDGivesNil() {
        let r = owner(Int(UInt32.max) + 1, [[pidKey: 4242]])
        XCTAssertTrue(r.pid == nil)
        XCTAssertEqual(r.reads, 0)
        XCTAssertEqual(owner(Int(UInt32.max), [[pidKey: 5]]).pid, 5, "the largest CGWindowID is read")
    }

    /// No list, an empty list, or a first entry without a pid: nil (the caller falls back to the frame rule).
    func testAMissingListOrPidGivesNil() {
        XCTAssertTrue(owner(3, nil).pid == nil)
        XCTAssertTrue(owner(3, []).pid == nil)
        XCTAssertTrue(owner(3, [[:]]).pid == nil)
        XCTAssertTrue(owner(3, [[boundsKey: ["X": 0, "Y": 0, "Width": 10, "Height": 10]], [pidKey: 8]]).pid == nil,
                      "the first entry decides even when it has no pid")
    }

    /// Wrong-typed, non-integral, non-finite or out-of-range pids are skipped, never trapped on.
    func testAWrongTypedOrOutOfRangePidGivesNil() {
        let bad: [Any] = ["4242", 3.5, Double.nan, Double.infinity, NSNumber(value: 3.5), NSNumber(value: Double.nan),
                          Int(Int32.max) + 1, Int(Int32.min) - 1, NSNumber(value: Int64(1) << 40), [4242]]
        for v in bad {
            XCTAssertTrue(owner(3, [[pidKey: v]]).pid == nil, "pid \(v)")
        }
        XCTAssertEqual(owner(3, [[pidKey: NSNumber(value: Int32.max)]]).pid, Int32.max)
        XCTAssertEqual(owner(3, [[pidKey: NSNumber(value: 4242)]]).pid, 4242, "the live list's CFNumber")
    }

    /// No bounds or layer rule today: an entry with an empty, non-finite or wrong-typed bound, or a high
    /// layer, still gives its pid (the window number already chose it). Pid 0 and a negative pid pass through
    /// as before; `shouldDismiss` then treats them as another app's.
    func testBoundsAndLayerAreNotRead() {
        let odd: [Any] = [["X": Double.nan, "Y": 0, "Width": 0, "Height": 0], "wide", [:] as [String: Any]]
        for b in odd {
            XCTAssertEqual(owner(3, [[pidKey: 7, boundsKey: b, layerKey: 25]]).pid, 7, "bounds \(b)")
        }
        XCTAssertEqual(owner(3, [[pidKey: 7, layerKey: "x"]]).pid, 7)
        XCTAssertEqual(owner(3, [[pidKey: 0]]).pid, 0)
        XCTAssertEqual(owner(3, [[pidKey: -1]]).pid, -1)
    }
}

/// #980 (rider from entry 979): no test reaches the live menu bar. Walks app/Tests for the system bar's
/// name and for the entry points of the controllers that put an item there, against a literal allow list
/// (each line exactly as many times as listed); and pins that list of controllers to the product sites in
/// app/Sources, so a new site turns this red until it is listed. The searched names are split here so this
/// file never matches itself.
final class MenuBarLiveBarGuardTests: XCTestCase {
    private static let sys = "NSStatus" + "Bar.system"
    private let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// "File.swift: trimmed line" for every line of a .swift file under `dir` that `hit` accepts.
    private func lines(under dir: String, where hit: (Substring) -> Bool) throws -> [String] {
        let root = app.appendingPathComponent(dir)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var out: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            where hit(line) {
                out.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return out.sorted()
    }

    func testNoTestReachesTheLiveMenuBar() throws {
        let sys = Self.sys, cal = "CalendarBar" + "Controller", mgr = "MenuBar" + "Manager"
        let hits = try lines(under: "Tests") { line in
            line.contains(sys)
                || line.contains(/(StatsController|CalendarBarController|MixerPanelController|MenuBarManager)\s*\.\s*shared\b/)
                || line.contains(/\bMenuBarManager\s*\(/)
        }
        // Today's lines: assertions that an item is NOT on the system bar, its thickness (no item), a doc
        // comment, the calendar's hotkey seams (never reload()), and one bare manager never reconciled.
        let allowed = [
            "ExtensionMenuBarThreadingTests.swift: XCTAssertFalse(item.statusBar === \(sys), \"extension item landed on the system bar\")",
            "ExtensionMenuBarStayTests.swift: /// the private bar installed, so a late job can never reach \(sys).",
            "ThemeTests.swift: // Confirmed headlessly safe: `\(sys).thickness` does not",
            "ThemeTests.swift: let thickness = \(sys).thickness",
            "MenuBarTests.swift: XCTAssertFalse(controller.statusItem.statusBar === \(sys), \"item landed on the system bar\")",
            "MenuBarTests.swift: let m = \(mgr)()",
            "WindowShortcutToggleMoreTests.swift: let cal = \(cal).shared",
            "WindowShortcutToggleMoreTests.swift: let cal = \(cal).shared",
            "MenuBarGapTests.swift: let system = \(sys)",
        ]
        XCTAssertEqual(hits, allowed.sorted(), "a test line names the system bar or a controller that creates an item there")
    }

    /// The controllers the row above guards are exactly the product sites that create a status item: each makes it
    /// on the accessor's bar (R980-a). And the only line under Sources that names the system bar, comments aside,
    /// is the accessor's own, beside the two thickness reads (they make no item).
    func testTheGuardedControllersAreTheProductSites() throws {
        let sys = Self.sys, acc = "ProsperStatusItems" + ".bar"
        let sites = try lines(under: "Sources") { $0.contains(acc + ".statusItem(") }
        let listed = [
            "StatsController.swift: let item = \(acc).statusItem(withLength: NSStatusItem.variableLength)",
            "CalendarBarController.swift: let item = \(acc).statusItem(withLength: NSStatusItem.variableLength)",
            "MixerPanelController.swift: let item = \(acc).statusItem(withLength: Self.itemWidth)",
            "MenuBarManager.swift: let item = \(acc).statusItem(withLength: Lengths.standard)",
            "MenuBarManager.swift: let item = \(acc).statusItem(withLength: Lengths.standard)",
        ]
        XCTAssertEqual(sites, listed.sorted(), "a new status-item site: list it and guard its controller in the row above")
        let named = try lines(under: "Sources") { line in
            line.contains(sys) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }
        let only = [
            "MenuBarBridging.swift: guard NSClassFromString(\"XCTestCase\") != nil else { return \(sys) }",
            "MenuBarController.swift: let h = Preferences.menuBarIconSize.pointSize(thickness: \(sys).thickness)",
            "StatsWidgetView.swift: private var thickness: CGFloat { \(sys).thickness }",
        ]
        XCTAssertEqual(named, only.sorted(), "a line names the system bar outside the accessor: use \(acc)")
    }

    /// R980-a at run time: under XCTest the accessor is one private bar (the same object every call, so an item is
    /// removed from the bar that made it), never the system bar; and a MenuBarController built with its DEFAULT bar
    /// has its item there. The system bar is only compared by identity. The two defaults are pinned by text first,
    /// and the controller is built only when both checks hold, so a broken default or accessor never makes a live item.
    @MainActor
    func testUnderXCTestTheAccessorIsOnePrivateBar() throws {
        let system = NSStatusBar.system
        let bar = ProsperStatusItems.bar
        XCTAssertTrue(ProsperStatusItems.bar === bar, "a new bar per call: an item would be removed from another bar")
        let defaults = try lines(under: "Sources") { $0.contains(": NSStatusBar = ") }
        let wanted = [
            "ExtensionMenuBar.swift: var statusBar: NSStatusBar = ProsperStatusItems.bar",
            "MenuBarBridging.swift: static let bar: NSStatusBar = {",
            "MenuBarController.swift: statusBar: NSStatusBar = ProsperStatusItems.bar",
        ]
        XCTAssertEqual(defaults, wanted, "a status-bar default does not go through the accessor")
        guard !(bar === system) else { return XCTFail("the accessor is the system bar under XCTest") }
        guard defaults == wanted else { return }
        let controller = MenuBarController(
            onOpenRunner: {}, onOpenClipboard: {}, onOpenSettings: {},
            onCheckForUpdates: {}, onRerunSetup: {}, onRestart: {}, onQuit: {})
        defer { bar.removeStatusItem(controller.statusItem) }
        XCTAssertTrue(controller.statusItem.statusBar === bar, "the default bar is not the accessor's")
        XCTAssertFalse(controller.statusItem.statusBar === system, "the default put the item on the system bar")
    }

    /// R980-b: the rows of WindowShortcutToggleMoreTests that hold the real calendar controller call only its hotkey
    /// seams (none reaches syncItem(), the one function that makes its item), and never reload(). A `cal` bound by
    /// "let cal = fakeCalendar()" is the test's own CalendarFake: its lines are skipped until the next real binding.
    func testCalendarRowsCallOnlyTheHotkeySeams() throws {
        let url = app.appendingPathComponent("Tests/ProsperAppTests/WindowShortcutToggleMoreTests.swift")
        let real = "let cal = CalendarBar" + "Controller.shared", fake = "let cal = fakeCalendar()"
        var isReal = false, bindings = 0, used = Set<String>()
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertFalse(line.contains(/\bcal\s*[?!]?\s*\.\s*reload\b/), "reload() after cal: \(line)")
            if line.contains(real) { isReal = true; bindings += 1; continue }
            if line.contains(fake) { isReal = false; continue }
            guard isReal else { continue }
            for m in line.matches(of: /\bcal\s*[?!]?\s*\.\s*(\w+)/) { used.insert(String(m.output.1)) }
        }
        XCTAssertEqual(bindings, 2, "the rows that bind the real calendar controller")
        XCTAssertEqual(used, ["popupWindow", "shortcutEffect", "toggleFromShortcut"], "a new member on the real controller")
    }
}
