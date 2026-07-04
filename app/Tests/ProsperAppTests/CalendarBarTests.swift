import XCTest

@testable import ProsperApp

/// Pure math + persistence layer behind the menu-bar calendar: grid alignment,
/// week numbering, the highlight bitmask, icon date formats, and the JSON style
/// blob round-trip. Everything here is deterministic (fixed Gregorian calendar,
/// fixed dates) so the tests never depend on the machine's locale or today.
final class CalendarBarTests: XCTestCase {

    /// Fixed Gregorian calendar in UTC so date math never shifts with the host.
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    // MARK: - Grid start

    func testGridStartMondayFirst() {
        // July 2026 starts on Wednesday (weekday 4). Monday-first grid must
        // back up to Monday June 29.
        let start = CalendarGridMath.gridStart(
            anchor: date(2026, 7, 15), firstWeekday: 2, calendar: cal)
        XCTAssertEqual(start, date(2026, 6, 29))
    }

    func testGridStartSundayFirst() {
        // Sunday-first grid for July 2026 backs up to Sunday June 28.
        let start = CalendarGridMath.gridStart(
            anchor: date(2026, 7, 15), firstWeekday: 1, calendar: cal)
        XCTAssertEqual(start, date(2026, 6, 28))
    }

    func testGridStartWhenMonthStartsOnFirstWeekday() {
        // June 2026 starts on Monday; a Monday-first grid starts on June 1 itself.
        let start = CalendarGridMath.gridStart(
            anchor: date(2026, 6, 10), firstWeekday: 2, calendar: cal)
        XCTAssertEqual(start, date(2026, 6, 1))
    }

    // MARK: - Month grid

    func testMonthGridShape() {
        for rows in [6, 8, 10] {
            let grid = CalendarGridMath.monthGrid(
                anchor: date(2026, 7, 1), rows: rows, firstWeekday: 2, calendar: cal)
            XCTAssertEqual(grid.count, rows)
            XCTAssertTrue(grid.allSatisfy { $0.count == 7 })
        }
    }

    func testMonthGridAdjacentMonthFlags() {
        let grid = CalendarGridMath.monthGrid(
            anchor: date(2026, 7, 1), rows: 6, firstWeekday: 2, calendar: cal)
        // First row starts June 29–30 (out of month), then July 1.
        XCTAssertFalse(grid[0][0].inCurrentMonth)
        XCTAssertFalse(grid[0][1].inCurrentMonth)
        XCTAssertTrue(grid[0][2].inCurrentMonth)
        XCTAssertEqual(grid[0][2].date, date(2026, 7, 1))
        // Consecutive days across the whole grid.
        let all = grid.flatMap { $0 }
        for i in 1..<all.count {
            XCTAssertEqual(all[i].date,
                           cal.date(byAdding: .day, value: 1, to: all[i - 1].date))
        }
    }

    // MARK: - ISO week numbers

    func testISOWeekNumbers() {
        // Jan 1 2026 is a Thursday: ISO week 1.
        XCTAssertEqual(CalendarGridMath.isoWeekNumber(for: date(2026, 1, 1), calendar: cal), 1)
        // Dec 28 always falls in the last ISO week of its year: 2026 has 53 weeks.
        XCTAssertEqual(CalendarGridMath.isoWeekNumber(for: date(2026, 12, 28), calendar: cal), 53)
        // Jan 1 2027 is a Friday, still ISO week 53 of 2026.
        XCTAssertEqual(CalendarGridMath.isoWeekNumber(for: date(2027, 1, 1), calendar: cal), 53)
    }

    // MARK: - Column weekday mapping

    func testWeekdayForColumn() {
        // Monday-first: col 0 = Monday(2) … col 6 = Sunday(1).
        XCTAssertEqual(CalendarGridMath.weekday(forColumn: 0, firstWeekday: 2), 2)
        XCTAssertEqual(CalendarGridMath.weekday(forColumn: 5, firstWeekday: 2), 7)
        XCTAssertEqual(CalendarGridMath.weekday(forColumn: 6, firstWeekday: 2), 1)
        // Sunday-first: identity.
        XCTAssertEqual(CalendarGridMath.weekday(forColumn: 0, firstWeekday: 1), 1)
        XCTAssertEqual(CalendarGridMath.weekday(forColumn: 6, firstWeekday: 1), 7)
        // Saturday-first wraps: col 0 = Saturday(7), col 1 = Sunday(1).
        XCTAssertEqual(CalendarGridMath.weekday(forColumn: 0, firstWeekday: 7), 7)
        XCTAssertEqual(CalendarGridMath.weekday(forColumn: 1, firstWeekday: 7), 1)
    }

    // MARK: - Highlight runs

    func testHighlightedColumnRuns() {
        var style = CalendarBarStyle.default
        // Default highlights Sat+Sun. Monday-first puts them in cols 5–6: one run.
        var runs = CalendarGridMath.highlightedColumnRuns(
            firstWeekday: 2, mask: style.highlightedWeekdays)
        XCTAssertEqual(runs, [5...6])
        // Sunday-first splits the weekend: Sunday col 0 and Saturday col 6.
        runs = CalendarGridMath.highlightedColumnRuns(
            firstWeekday: 1, mask: style.highlightedWeekdays)
        XCTAssertEqual(runs, [0...0, 6...6])
        // No highlights: no runs.
        style.highlightedWeekdays = 0
        XCTAssertEqual(CalendarGridMath.highlightedColumnRuns(
            firstWeekday: 2, mask: 0), [])
        // All highlighted: single full-width run.
        XCTAssertEqual(CalendarGridMath.highlightedColumnRuns(
            firstWeekday: 2, mask: 0b1111111), [0...6])
    }

    func testHighlightMaskHelpers() {
        var style = CalendarBarStyle.default
        XCTAssertTrue(style.isHighlighted(weekday: 1))   // Sunday
        XCTAssertTrue(style.isHighlighted(weekday: 7))   // Saturday
        XCTAssertFalse(style.isHighlighted(weekday: 4))  // Wednesday
        style.setHighlighted(weekday: 4, true)
        XCTAssertTrue(style.isHighlighted(weekday: 4))
        style.setHighlighted(weekday: 1, false)
        XCTAssertFalse(style.isHighlighted(weekday: 1))
    }

    // MARK: - Icon date formats

    func testIconDateFormatContainsRequestedFields() {
        let locale = Locale(identifier: "en_US")
        let dayOnly = CalendarGridMath.iconDateFormat(
            showMonth: false, showDayOfWeek: false, locale: locale)
        XCTAssertTrue(dayOnly.contains("d"))
        XCTAssertFalse(dayOnly.contains("MMM"))
        let full = CalendarGridMath.iconDateFormat(
            showMonth: true, showDayOfWeek: true, locale: locale)
        XCTAssertTrue(full.contains("d"))
        XCTAssertTrue(full.contains("MMM"))
        XCTAssertTrue(full.contains("EEE"))
    }

    func testPatternHasTimeFields() {
        XCTAssertTrue(CalendarIconWidget.patternHasTimeFields("d MMM HH:mm"))
        XCTAssertTrue(CalendarIconWidget.patternHasTimeFields("h:mm a"))
        XCTAssertFalse(CalendarIconWidget.patternHasTimeFields("EEE, d MMM"))
        // Time letters inside a quoted literal are text, not fields.
        XCTAssertFalse(CalendarIconWidget.patternHasTimeFields("EEE 'at home'"))
        XCTAssertTrue(CalendarIconWidget.patternHasTimeFields("'at' HH:mm"))
    }

    // MARK: - Style persistence

    func testStyleRoundTrip() throws {
        var style = CalendarBarStyle.default
        style.iconMode = .pattern
        style.datetimePattern = "EEE d MMM HH:mm"
        style.firstWeekday = 2
        style.gridRows = 8
        style.selectedCalendarIDs = ["work", "home"]
        let data = try JSONEncoder().encode(style)
        let back = try JSONDecoder().decode(CalendarBarStyle.self, from: data)
        XCTAssertEqual(back, style)
    }

    func testStyleDecodeFailureFallsBackToDefault() {
        let key = "calendarBarStyle"
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(Data("not json".utf8), forKey: key)
        XCTAssertEqual(CalendarBarStyleStore.load(), .default)
    }

    func testCalendarSelectionSemantics() {
        var style = CalendarBarStyle.default
        // nil = all calendars visible.
        XCTAssertNil(style.selectedCalendarIDs)
        XCTAssertTrue(style.isCalendarSelected("anything"))
        style.selectedCalendarIDs = ["a"]
        XCTAssertTrue(style.isCalendarSelected("a"))
        XCTAssertFalse(style.isCalendarSelected("b"))
    }

    func testAgendaOptions() {
        let options = CalendarGridMath.agendaOptions
        XCTAssertEqual(options.first?.days, 0)
        XCTAssertTrue(options.contains { $0.days == 7 })
        XCTAssertTrue(options.contains { $0.days == 31 })
        // Days strictly increasing, labels unique.
        let days = options.map(\.days)
        XCTAssertEqual(days, days.sorted())
        XCTAssertEqual(Set(options.map(\.label)).count, options.count)
    }

    func testResolvedFirstWeekday() {
        var style = CalendarBarStyle.default
        style.firstWeekday = 3
        XCTAssertEqual(style.resolvedFirstWeekday, 3)
        style.firstWeekday = 0
        // 0 = system; must resolve to a valid weekday whatever the host locale.
        XCTAssertTrue((1...7).contains(style.resolvedFirstWeekday))
    }

    func testLinkifiedNotes() {
        let attr = CalendarDetailText.linkified(
            "Join https://zoom.us/j/123?pwd=x now or via https://meet.google.com/abc")
        let links = attr.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString),
                       ["https://zoom.us/j/123?pwd=x", "https://meet.google.com/abc"])
        // Text content unchanged by linkification.
        XCTAssertEqual(String(attr.characters),
                       "Join https://zoom.us/j/123?pwd=x now or via https://meet.google.com/abc")
        XCTAssertTrue(CalendarDetailText.linkified("no links here").runs.compactMap(\.link).isEmpty)
    }
}
