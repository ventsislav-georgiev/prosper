// Customization model for the menu-bar Calendar (Itsycal-style).
//
// One JSON blob in UserDefaults drives everything: how the menu-bar icon
// renders (day badge / outline / glyph / custom datetime pattern), and how the
// popup calendar looks (text scale, first weekday, highlighted columns, event
// dots, week numbers, agenda span, per-calendar selection). Defaults mirror the
// reference screenshots so a fresh enable looks right with zero configuration.

import SwiftUI

/// The four Itsycal menu-bar icon variants.
enum CalendarIconMode: String, Codable, CaseIterable, Sendable {
    case solid      // day number knocked out of a filled rounded rect
    case outline    // day number inside a stroked rounded rect
    case glyph      // static calendar glyph, no day number
    case pattern    // free-form datetime pattern text (TR35)

    var label: String {
        switch self {
        case .solid: "Filled"; case .outline: "Outline"
        case .glyph: "Icon"; case .pattern: "Custom"
        }
    }
}

/// Menu-bar icon text weight. Regular by default — the bold look is opt-in.
enum CalendarIconTextWeight: String, Codable, CaseIterable, Sendable {
    case regular, medium, semibold, bold
    var label: String {
        switch self {
        case .regular: "Regular"; case .medium: "Medium"
        case .semibold: "Semibold"; case .bold: "Bold"
        }
    }
    var weight: Font.Weight {
        switch self {
        case .regular: .regular; case .medium: .medium
        case .semibold: .semibold; case .bold: .bold
        }
    }
}

/// Menu-bar icon font design (system font families only — arbitrary font
/// pickers are overkill for a 16pt menu-bar badge).
enum CalendarIconFontDesign: String, Codable, CaseIterable, Sendable {
    case standard, rounded, monospaced, serif
    var label: String {
        switch self {
        case .standard: "Default"; case .rounded: "Rounded"
        case .monospaced: "Monospaced"; case .serif: "Serif"
        }
    }
    var design: Font.Design {
        switch self {
        case .standard: .default; case .rounded: .rounded
        case .monospaced: .monospaced; case .serif: .serif
        }
    }
}

/// Popup text scale steps (segmented presets, not a slider — a slider's .id()
/// rebuild tears the drag gesture elsewhere in the app, same convention here).
enum CalendarTextScale: String, Codable, CaseIterable, Sendable {
    case small, medium, large
    var label: String { switch self { case .small: "Small"; case .medium: "Default"; case .large: "Large" } }
    var factor: CGFloat { switch self { case .small: 0.85; case .medium: 1.0; case .large: 1.18 } }
}

struct CalendarBarStyle: Codable, Equatable, Sendable {
    // Menu bar
    var iconMode: CalendarIconMode
    var showMonthInIcon: Bool
    var showDayOfWeekInIcon: Bool
    var datetimePattern: String     // used by .pattern; empty falls back to .solid
    var hideIcon: Bool
    // Optional (added after first beta): missing keys in an existing saved blob
    // must keep decoding — a non-optional field would fail decode and silently
    // reset every setting to .default. nil means the default.
    var iconTextWeight: CalendarIconTextWeight?   // nil = .regular
    var iconFontDesign: CalendarIconFontDesign?   // nil = .standard

    // Popup calendar
    var textScale: CalendarTextScale
    var firstWeekday: Int           // 0 = follow system; else 1=Sun … 7=Sat
    var highlightedWeekdays: Int    // bitmask, bit (weekday-1); default Sat+Sun
    var showEventDots: Bool
    var useColoredDots: Bool
    var showEventLocation: Bool
    var showDaysWithNoEvents: Bool
    var showWeekNumbers: Bool
    var agendaDays: Int             // 0 = no event list; 1…7, 14, 31
    var gridRows: Int               // 6…10, drag-resizable

    // Which calendars show. nil = all event calendars (fresh default);
    // once the user touches the checklist it becomes an explicit identifier list.
    var selectedCalendarIDs: [String]?

    /// Resolved menu-bar icon font attributes (nil fields mean the default).
    var resolvedIconWeight: Font.Weight { (iconTextWeight ?? .regular).weight }
    var resolvedIconDesign: Font.Design { (iconFontDesign ?? .standard).design }

    /// Resolved first weekday (1=Sun…7=Sat), honouring "follow system".
    var resolvedFirstWeekday: Int {
        firstWeekday >= 1 && firstWeekday <= 7 ? firstWeekday : Calendar.current.firstWeekday
    }

    func isHighlighted(weekday: Int) -> Bool { highlightedWeekdays & (1 << (weekday - 1)) != 0 }

    mutating func setHighlighted(weekday: Int, _ on: Bool) {
        if on { highlightedWeekdays |= (1 << (weekday - 1)) }
        else { highlightedWeekdays &= ~(1 << (weekday - 1)) }
    }

    func isCalendarSelected(_ id: String) -> Bool { selectedCalendarIDs?.contains(id) ?? true }

    static let `default` = CalendarBarStyle(
        iconMode: .outline,
        showMonthInIcon: true,
        showDayOfWeekInIcon: true,
        datetimePattern: "",
        hideIcon: false,
        iconTextWeight: nil,
        iconFontDesign: nil,
        textScale: .medium,
        firstWeekday: 0,
        // Sat (bit 6) + Sun (bit 0) — the Itsycal weekend default.
        highlightedWeekdays: (1 << 6) | (1 << 0),
        showEventDots: true,
        useColoredDots: true,
        showEventLocation: true,
        showDaysWithNoEvents: true,
        showWeekNumbers: true,
        agendaDays: 1,
        gridRows: 6,
        selectedCalendarIDs: nil)
}

/// JSON persistence — one UserDefaults key holds the whole blob; a decode
/// failure (schema drift) falls back to the default rather than throwing, so a
/// bad blob can never wedge the feature. Same shape as SystemStatsStore.
enum CalendarBarStyleStore {
    static let key = "calendarBarStyle"
    private static var defaults: UserDefaults { .standard }

    static func load() -> CalendarBarStyle {
        guard let data = defaults.data(forKey: key),
              let style = try? JSONDecoder().decode(CalendarBarStyle.self, from: data)
        else { return .default }
        return style
    }

    static func save(_ style: CalendarBarStyle) {
        guard let data = try? JSONEncoder().encode(style) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Grid math (pure, tested)

/// One day cell of the month grid.
struct CalendarGridDay: Equatable, Sendable {
    let date: Date
    let day: Int                // day-of-month number to draw
    let inCurrentMonth: Bool    // adjacent-month days render dimmed
    let weekday: Int            // 1=Sun…7=Sat
}

/// Pure calendar-grid computation, no EventKit — unit-testable.
enum CalendarGridMath {

    /// First visible date of a month grid: the `firstWeekday`-aligned week start
    /// on or before the 1st of `anchor`'s month.
    static func gridStart(anchor: Date, firstWeekday: Int, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: anchor)
        let firstOfMonth = calendar.date(from: comps)!
        let weekday = calendar.component(.weekday, from: firstOfMonth)
        // Days back from the 1st to the week start (0…6).
        let back = (weekday - firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -back, to: firstOfMonth)!
    }

    /// The full grid: `rows` weeks × 7 days starting at `gridStart`.
    static func monthGrid(anchor: Date, rows: Int, firstWeekday: Int,
                          calendar: Calendar) -> [[CalendarGridDay]] {
        let start = gridStart(anchor: anchor, firstWeekday: firstWeekday, calendar: calendar)
        let month = calendar.component(.month, from: anchor)
        var grid: [[CalendarGridDay]] = []
        for row in 0..<rows {
            var week: [CalendarGridDay] = []
            for col in 0..<7 {
                let date = calendar.date(byAdding: .day, value: row * 7 + col, to: start)!
                week.append(CalendarGridDay(
                    date: date,
                    day: calendar.component(.day, from: date),
                    inCurrentMonth: calendar.component(.month, from: date) == month,
                    weekday: calendar.component(.weekday, from: date)))
            }
            grid.append(week)
        }
        return grid
    }

    /// ISO-8601 week number for the week containing `date` (ISO weeks are
    /// Monday-anchored regardless of the grid's first weekday).
    static func isoWeekNumber(for date: Date, calendar: Calendar) -> Int {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        return iso.component(.weekOfYear, from: date)
    }

    /// Weekday (1=Sun…7=Sat) shown in grid column `col` for a given week start.
    static func weekday(forColumn col: Int, firstWeekday: Int) -> Int {
        (firstWeekday - 1 + col) % 7 + 1
    }

    /// Contiguous runs of highlighted columns (for the one-rounded-rect-per-run
    /// weekend background, Itsycal-style). Returns closed column ranges.
    static func highlightedColumnRuns(firstWeekday: Int, mask: Int) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var runStart: Int?
        for col in 0..<7 {
            let wd = weekday(forColumn: col, firstWeekday: firstWeekday)
            let on = mask & (1 << (wd - 1)) != 0
            if on { runStart = runStart ?? col }
            else if let s = runStart { runs.append(s...(col - 1)); runStart = nil }
        }
        if let s = runStart { runs.append(s...6) }
        return runs
    }

    /// Menu-bar icon text template for the solid/outline modes: day number,
    /// optionally with month and/or day-of-week, localized via TR35 template
    /// expansion. Forces a Gregorian-calendar locale — ISO-8601 locale calendars
    /// drop the `EEE` field from templates (the Itsycal Sequoia workaround).
    static func iconDateFormat(showMonth: Bool, showDayOfWeek: Bool, locale: Locale) -> String {
        var template = "d"
        if showMonth { template += "MMM" }
        if showDayOfWeek { template += "EEE" }
        var localeID = locale.identifier
        if let at = localeID.firstIndex(of: "@") { localeID = String(localeID[..<at]) }
        let gregorian = Locale(identifier: localeID + "@calendar=gregorian")
        return DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: gregorian)
            ?? "d"
    }

    /// Agenda span picker options: (days, label). 0 = no list.
    static let agendaOptions: [(days: Int, label: String)] = [
        (0, "No events"), (1, "1 day"), (2, "2 days"), (3, "3 days"), (4, "4 days"),
        (5, "5 days"), (6, "6 days"), (7, "7 days"), (14, "14 days"), (31, "31 days"),
    ]
}
