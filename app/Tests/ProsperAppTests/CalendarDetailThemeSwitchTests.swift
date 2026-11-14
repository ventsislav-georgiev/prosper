import AppKit
import SwiftUI
import XCTest
@testable import ProsperApp

/// #928: a theme switch rebuilds every Themed subtree. The Calendar popup's open event detail is
/// held in CalendarBarStore (which outlives that rebuild), and the ModelSetup window's AppKit label
/// re-reads the primary text colour on every theme generation. Events are made-up values, no
/// EventKit fetch and no popover is shown; themes are switched on scratch ThemeStores over scratch
/// defaults, as ThemeVariantTests does, and the runtime globals are put back in a defer.
@MainActor
final class CalendarDetailThemeSwitchTests: XCTestCase {

    private func event(_ id: String, day: Date) -> CalendarEventInfo {
        CalendarEventInfo(id: id, title: "Example meeting", location: "", startDate: day,
                          endDate: day.addingTimeInterval(3600), isAllDay: false, isStartDay: true,
                          isEndDay: true, isTentative: false, color: RGBAColor(0.2, 0.4, 0.8),
                          calendarID: "cal-example", videoURL: nil, notes: "", attendees: [])
    }

    /// A scratch store that has applied the bundled High Contrast Dark theme.
    private func themeStore() -> ThemeStore {
        let s = ThemeStore(defaults: scratchDefaults("t928"), cacheDir: tempDir("tc928"))
        s.setAvailable([ThemeVariantTests.hcDark, ThemeVariantTests.hcLight])
        s.select(id: ThemeVariantTests.hcDarkID)
        return s
    }

    private func calendarStore() -> (CalendarBarStore, CalendarEventInfo) {
        let store = CalendarBarStore(style: .default)
        let ev = event("example-1", day: store.selectedDay)
        store.eventsByDay = [store.selectedDay: [ev]]
        store.detailEventID = ev.id
        return (store, ev)
    }

    func testOpenDetailSurvivesAThemeGenerationChange() {
        let saved = (ThemeRuntime.palette, ThemeRuntime.scale, NSApp?.appearance)
        defer { (ThemeRuntime.palette, ThemeRuntime.scale) = (saved.0, saved.1); NSApp?.appearance = saved.2 }
        let (store, ev) = calendarStore()
        let theme = themeStore()
        let g0 = theme.generation
        theme.select(id: ThemeVariantTests.hcLightID)
        XCTAssertEqual(theme.generation, g0 + 1, "the switch did not bump the generation Themed keys on")
        XCTAssertEqual(store.detailEventID, ev.id)
        XCTAssertEqual(store.detailEvent, ev)
    }

    func testOpenDetailIsClearedOnADayChangeOnly() {
        let (store, ev) = calendarStore()
        let day = store.selectedDay
        store.selectedDay = day   // same day: the detail stays
        XCTAssertEqual(store.detailEventID, ev.id)
        store.selectedDay = day.addingTimeInterval(86_400)
        XCTAssertTrue(store.detailEventID == nil)
        XCTAssertTrue(store.detailEvent == nil)
    }

    func testOpenDetailIsDroppedWhenItsEventIsGone() {
        let (store, ev) = calendarStore()
        let other = event("example-2", day: store.selectedDay)
        store.eventsByDay = [store.selectedDay: [ev, other]]   // a refetch that still has it
        XCTAssertEqual(store.detailEvent, ev)
        store.eventsByDay = [store.selectedDay: [other]]
        XCTAssertTrue(store.detailEventID == nil)
        // The same id coming back later does not reopen the detail.
        store.eventsByDay = [store.selectedDay: [ev, other]]
        XCTAssertTrue(store.detailEvent == nil)
    }

    func testModelSetupLabelFollowsTheThemesPrimaryText() {
        let saved = (ThemeRuntime.palette, ThemeRuntime.scale, NSApp?.appearance)
        defer { (ThemeRuntime.palette, ThemeRuntime.scale) = (saved.0, saved.1); NSApp?.appearance = saved.2 }
        let theme = themeStore()
        let label = NSTextField(labelWithString: "Preparing the language model")
        let observer = ModelSetup.followTheme(label, store: theme)
        defer { observer.cancel() }
        let darkText = Neon.textPrimary
        XCTAssertTrue(ThemeVariantTests.same(Color(nsColor: label.textColor ?? .clear), darkText))
        theme.select(id: ThemeVariantTests.hcLightID)
        XCTAssertFalse(ThemeVariantTests.same(Neon.textPrimary, darkText), "fixture: the two themes share a text colour")
        XCTAssertTrue(ThemeVariantTests.same(Color(nsColor: label.textColor ?? .clear), Neon.textPrimary),
                      "the label kept the old theme's colour")
    }
}
