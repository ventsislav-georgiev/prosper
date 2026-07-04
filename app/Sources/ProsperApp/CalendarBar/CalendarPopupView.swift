// The Itsycal-style popup: month header with prev/today/next, weekday row,
// resizable month grid (event dots, today outline, weekend-column highlight,
// optional ISO week numbers), a toolbar row (+ / pin / Calendar.app / settings)
// and the agenda list below. Painted entirely in Neon tokens so it matches the
// rest of the app; the NSPopover supplies the window chrome.

import AppKit
import SwiftUI

struct CalendarPopupView: View {
    @ObservedObject var store: CalendarBarStore
    var onMonthChanged: () -> Void
    var onPinChanged: (Bool) -> Void
    var onOpenSettings: () -> Void
    var onClose: () -> Void
    var onRowsChanged: (Int) -> Void

    @State private var hoveredDay: Date?
    @State private var dragStartRows: Int?

    /// User text-scale on top of the global UI scale.
    private var f: CGFloat { store.style.textScale.factor }
    private var cellW: CGFloat { sz(36) * f }
    private var cellH: CGFloat { sz(34) * f }
    private var weekColW: CGFloat { store.style.showWeekNumbers ? sz(26) * f : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, sz(14)).padding(.top, sz(12)).padding(.bottom, sz(6))
            weekdayRow
                .padding(.horizontal, sz(14))
            grid
                .padding(.horizontal, sz(14)).padding(.top, sz(2))
            resizeHandle
                .padding(.vertical, sz(2))
            toolbar
                .padding(.horizontal, sz(14)).padding(.vertical, sz(6))
            if store.style.agendaDays > 0 {
                Divider().overlay(Neon.stroke)
                agenda
            }
        }
        .padding(.bottom, sz(10))
        .frame(width: weekColW + cellW * 7 + sz(28))
        .background(LinearGradient(colors: [Neon.bgTop, Neon.bgBottom],
                                   startPoint: .top, endPoint: .bottom))
    }

    // MARK: - Header

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = store.calendar
        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "MMMyyyy", options: 0, locale: .current)
        return formatter.string(from: store.monthAnchor)
    }

    private var header: some View {
        HStack {
            Text(monthTitle)
                .font(Neon.font(17 * f, weight: .semibold))
                .foregroundStyle(Neon.textPrimary)
            Spacer()
            navButton("chevron.left") { shiftMonth(-1) }
            navButton("circle.fill") { goToday() }
            navButton("chevron.right") { shiftMonth(1) }
        }
    }

    private func navButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "circle.fill" ? sz(7) : sz(11) * f, weight: .semibold))
                .foregroundStyle(Neon.textSecondary)
                .frame(width: sz(22), height: sz(20))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shiftMonth(_ delta: Int) {
        store.monthAnchor = store.calendar.date(
            byAdding: .month, value: delta, to: store.monthAnchor) ?? store.monthAnchor
        onMonthChanged()
    }

    private func goToday() {
        store.monthAnchor = store.today
        store.selectedDay = store.today
        onMonthChanged()
    }

    // MARK: - Weekday row

    private var weekdaySymbols: [String] {
        // Very-short symbols ("M", "T", …) rotated to the configured week start.
        let symbols = store.calendar.veryShortStandaloneWeekdaySymbols
        let first = store.style.resolvedFirstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            if store.style.showWeekNumbers { Color.clear.frame(width: weekColW, height: 1) }
            ForEach(0..<7, id: \.self) { col in
                let wd = CalendarGridMath.weekday(forColumn: col,
                                                  firstWeekday: store.style.resolvedFirstWeekday)
                Text(weekdaySymbols[col])
                    .font(Neon.font(12 * f, weight: .semibold))
                    .foregroundStyle(store.style.isHighlighted(weekday: wd)
                                     ? Neon.textPrimary : Neon.textSecondary)
                    .frame(width: cellW, height: sz(20))
            }
        }
    }

    // MARK: - Month grid

    private var grid: some View {
        let style = store.style
        let weeks = CalendarGridMath.monthGrid(
            anchor: store.monthAnchor, rows: style.gridRows,
            firstWeekday: style.resolvedFirstWeekday, calendar: store.calendar)
        return VStack(spacing: 0) {
            ForEach(0..<weeks.count, id: \.self) { row in
                HStack(spacing: 0) {
                    if style.showWeekNumbers {
                        Text("\(CalendarGridMath.isoWeekNumber(for: weeks[row][0].date, calendar: store.calendar))")
                            .font(Neon.font(11 * f))
                            .foregroundStyle(Neon.textSecondary.opacity(0.7))
                            .frame(width: weekColW, height: cellH)
                    }
                    ForEach(0..<7, id: \.self) { col in
                        dayCell(weeks[row][col])
                    }
                }
            }
        }
        .background(weekendBackground)
    }

    /// One rounded rect per contiguous highlighted-column run, behind the grid.
    private var weekendBackground: some View {
        let runs = CalendarGridMath.highlightedColumnRuns(
            firstWeekday: store.style.resolvedFirstWeekday,
            mask: store.style.highlightedWeekdays)
        return HStack(spacing: 0) {
            if store.style.showWeekNumbers { Color.clear.frame(width: weekColW) }
            ZStack(alignment: .leading) {
                Color.clear
                ForEach(0..<runs.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: sz(8), style: .continuous)
                        .fill(Neon.cardHi.opacity(0.85))
                        .frame(width: CGFloat(runs[i].count) * cellW)
                        .offset(x: CGFloat(runs[i].lowerBound) * cellW)
                }
            }
            .frame(width: cellW * 7)
        }
    }

    @ViewBuilder
    private func dayCell(_ day: CalendarGridDay) -> some View {
        let style = store.style
        let isToday = day.date == store.today
        let isSelected = day.date == store.selectedDay
        let isHovered = hoveredDay == day.date
        let dotColors = store.dotColors(for: day.date)
        let hasEvents = store.hasEvents(on: day.date)

        VStack(spacing: sz(2)) {
            Text("\(day.day)")
                .font(Neon.font(14 * f, weight: day.inCurrentMonth ? .medium : .regular))
                .foregroundStyle(day.inCurrentMonth
                                 ? Neon.textPrimary
                                 : Neon.textSecondary.opacity(0.55))
            if style.showEventDots {
                HStack(spacing: sz(3)) {
                    if hasEvents {
                        if dotColors.isEmpty {
                            Circle().fill(Neon.textPrimary.opacity(0.8))
                                .frame(width: sz(4) * f, height: sz(4) * f)
                        } else {
                            ForEach(0..<dotColors.count, id: \.self) { i in
                                Circle().fill(dotColors[i].color)
                                    .frame(width: sz(4) * f, height: sz(4) * f)
                            }
                        }
                    } else {
                        Color.clear.frame(width: sz(4), height: sz(4) * f)
                    }
                }
                .frame(height: sz(5) * f)
            }
        }
        .frame(width: cellW, height: cellH)
        .background(
            RoundedRectangle(cornerRadius: sz(6), style: .continuous)
                .fill(isToday ? Neon.blueBright.opacity(0.16)
                      : (isSelected ? Neon.blue.opacity(0.32) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: sz(6), style: .continuous)
                .stroke(isToday ? Neon.blueBright
                        : (isSelected ? Neon.blue
                           : (isHovered ? Neon.textSecondary.opacity(0.4) : Color.clear)),
                        lineWidth: isToday ? 2 : (isSelected ? 1.5 : 1))
        )
        .contentShape(Rectangle())
        .onHover { hoveredDay = $0 ? day.date : (hoveredDay == day.date ? nil : hoveredDay) }
        // One single-tap gesture, double-click detected via AppKit's clickCount:
        // any two-tap SwiftUI gesture (plain pair or simultaneous) delays or
        // swallows the single tap while disambiguating. This fires on every
        // mouse-up — instant selection; the second click of a double-click
        // arrives with clickCount == 2 and additionally opens Calendar.app.
        .onTapGesture {
            store.selectedDay = day.date
            if NSApp.currentEvent?.clickCount ?? 1 >= 2 { openCalendarApp() }
        }
    }

    /// Bottom drag pill: resize the grid 6–10 rows (Itsycal parity).
    private var resizeHandle: some View {
        Capsule()
            .fill(Neon.textSecondary.opacity(0.35))
            .frame(width: sz(36), height: sz(4))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle().inset(by: -sz(6)))
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let base = dragStartRows ?? store.style.gridRows
                        dragStartRows = base
                        let delta = Int((value.translation.height / cellH).rounded())
                        let rows = min(10, max(6, base + delta))
                        if rows != store.style.gridRows { onRowsChanged(rows) }
                    }
                    .onEnded { _ in dragStartRows = nil }
            )
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: sz(14)) {
            toolbarButton("plus", help: "New event in Calendar") { openCalendarApp() }
            Spacer()
            Button {
                store.pinned.toggle()
                onPinChanged(store.pinned)
            } label: {
                Image(systemName: store.pinned ? "pin.fill" : "pin")
                    .font(.system(size: sz(13)))
                    .foregroundStyle(store.pinned ? Neon.blue : Neon.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Keep the calendar open")
            toolbarButton("calendar", help: "Open Calendar") { openCalendarApp() }
            toolbarButton("gearshape.fill", help: "Calendar settings") { onOpenSettings() }
        }
    }

    private func toolbarButton(_ symbol: String, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: sz(13)))
                .foregroundStyle(Neon.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Open the system Calendar app. Date-targeted deep links (BusyCal /
    /// Fantastical routing) are an upgrade path if anyone asks.
    private func openCalendarApp() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: - Agenda

    private var agendaDays: [Date] {
        // Anchored to the selected day (not today) so clicking a day in the
        // grid moves the event list to it.
        (0..<max(store.style.agendaDays, 1)).compactMap {
            store.calendar.date(byAdding: .day, value: $0, to: store.selectedDay)
        }
    }

    private var agenda: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !store.accessGranted {
                    accessHint
                } else {
                    ForEach(agendaDays, id: \.self) { day in
                        let events = store.eventsByDay[day] ?? []
                        if !events.isEmpty || store.style.showDaysWithNoEvents {
                            agendaHeader(day)
                            if events.isEmpty {
                                Text("—")
                                    .font(Neon.font(12 * f))
                                    .foregroundStyle(Neon.textSecondary.opacity(0.6))
                                    .padding(.horizontal, sz(14)).padding(.vertical, sz(3))
                            } else {
                                ForEach(events) { agendaRow($0) }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, sz(6))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: sz(240) * f)
    }

    private var accessHint: some View {
        VStack(alignment: .leading, spacing: sz(6)) {
            Text("Calendar access needed")
                .font(Neon.font(13 * f, weight: .semibold))
                .foregroundStyle(Neon.textPrimary)
            Text("Grant Calendar access in System Settings to see your events here.")
                .font(Neon.font(11 * f))
                .foregroundStyle(Neon.textSecondary)
            Button("Open System Settings") {
                PermissionsManager.openSettings(forPermission: "calendar")
            }
            .font(Neon.font(11 * f))
        }
        .padding(.horizontal, sz(14)).padding(.vertical, sz(8))
    }

    private func agendaHeader(_ day: Date) -> some View {
        let title: String = day == store.today ? "Today"
            : (day == store.calendar.date(byAdding: .day, value: 1, to: store.today)
               ? "Tomorrow" : dayTitle(day))
        return HStack {
            Text(title)
                .font(Neon.font(13 * f, weight: .semibold))
                .foregroundStyle(Neon.textPrimary)
            Spacer()
            Text(shortDate(day))
                .font(Neon.font(12 * f))
                .foregroundStyle(Neon.textSecondary)
        }
        .padding(.horizontal, sz(14)).padding(.top, sz(8)).padding(.bottom, sz(2))
    }

    private func dayTitle(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = store.calendar
        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "EEEE", options: 0, locale: .current)
        return formatter.string(from: day)
    }

    private func shortDate(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = store.calendar
        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "MMMd", options: 0, locale: .current)
        return formatter.string(from: day)
    }

    private func agendaRow(_ event: CalendarEventInfo) -> some View {
        HStack(alignment: .top, spacing: sz(8)) {
            // Colored dot: capsule for all-day, ring (stroked) for tentative.
            Group {
                if event.isAllDay {
                    Capsule().fill(event.color.color)
                        .frame(width: sz(7) * f, height: sz(14) * f)
                } else if event.isTentative {
                    Circle().stroke(event.color.color, lineWidth: 1.5)
                        .frame(width: sz(8) * f, height: sz(8) * f)
                } else {
                    Circle().fill(event.color.color)
                        .frame(width: sz(8) * f, height: sz(8) * f)
                }
            }
            .padding(.top, sz(4) * f)
            VStack(alignment: .leading, spacing: sz(1)) {
                Text(event.title)
                    .font(Neon.font(13 * f))
                    .foregroundStyle(Neon.textPrimary)
                    .lineLimit(2)
                if store.style.showEventLocation, !event.location.isEmpty {
                    Text(event.location)
                        .font(Neon.font(11 * f))
                        .foregroundStyle(Neon.textSecondary)
                        .lineLimit(1)
                }
                if !event.isAllDay {
                    HStack(spacing: sz(6)) {
                        Text(timeRange(event))
                            .font(Neon.font(11 * f).monospacedDigit())
                            .foregroundStyle(Neon.textSecondary)
                        if let url = event.videoURL {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Image(systemName: "video")
                                    .font(.system(size: sz(10) * f))
                                    .foregroundStyle(Neon.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("Join video call")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, sz(14)).padding(.vertical, sz(3))
    }

    private func timeRange(_ event: CalendarEventInfo) -> String {
        let formatter = DateFormatter()
        formatter.calendar = store.calendar
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        if !event.isStartDay { return "ends \(formatter.string(from: event.endDate))" }
        return "\(formatter.string(from: event.startDate))–\(formatter.string(from: event.endDate))"
    }
}
