// Native settings footer for the Calendar extension (merged below the
// manifest's Permissions section, same pattern as MenuBarPane). Menu-bar icon
// appearance, popup calendar options, and the per-calendar checklist. Every
// edit writes through to the JSON style blob and posts
// `.calendarBarConfigChanged` so the live controller reconfigures immediately.

import SwiftUI

struct CalendarPane: View {
    @State private var style = CalendarBarStyleStore.load()
    @State private var groups: [CalendarSourceGroup] = []
    @State private var accessGranted = CalendarEventCenter.authorized
    /// Coalesces rapid edits (checklist sweeps, pattern typing) into one
    /// persist+notify, so we don't JSON-encode + reload the controller per key.
    @State private var commitWork: DispatchWorkItem?

    var body: some View {
        Group {
            menuBarSection
            calendarSection
            calendarsSection
        }
        .onAppear { reloadGroups() }
    }

    // MARK: - Menu Bar

    private var menuBarSection: some View {
        NeonSection("Menu Bar") {
            NeonRow("Icon style") {
                Picker("", selection: binding(\.iconMode)) {
                    ForEach(CalendarIconMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: sz(280))
                .disabled(style.hideIcon)
            }
            if style.iconMode == .solid || style.iconMode == .outline {
                NeonDivider()
                NeonRow("Show month in icon") {
                    Toggle("", isOn: binding(\.showMonthInIcon)).labelsHidden()
                        .disabled(style.hideIcon)
                }
                NeonRow("Show day of week in icon") {
                    Toggle("", isOn: binding(\.showDayOfWeekInIcon)).labelsHidden()
                        .disabled(style.hideIcon)
                }
            }
            if style.iconMode == .pattern {
                NeonDivider()
                NeonRow("Datetime pattern",
                        subtitle: "Unicode date format, e.g. EEE, d MMM or d MMM HH:mm") {
                    TextField("EEE, d MMM", text: binding(\.datetimePattern))
                        .textFieldStyle(.roundedBorder).frame(width: sz(180))
                        .disabled(style.hideIcon)
                }
            }
            NeonDivider()
            NeonRow("Hide icon",
                    subtitle: "Keeps the calendar reachable via its shortcut") {
                Toggle("", isOn: binding(\.hideIcon)).labelsHidden()
            }
        }
    }

    // MARK: - Calendar (popup appearance)

    private var calendarSection: some View {
        NeonSection("Calendar") {
            NeonRow("Text size") {
                Picker("", selection: binding(\.textScale)) {
                    ForEach(CalendarTextScale.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: sz(220))
            }
            NeonDivider()
            NeonRow("First day of week") {
                Picker("", selection: binding(\.firstWeekday)) {
                    Text("System").tag(0)
                    ForEach(1...7, id: \.self) { wd in
                        Text(Calendar.current.standaloneWeekdaySymbols[wd - 1]).tag(wd)
                    }
                }
                .labelsHidden().frame(width: sz(140))
            }
            NeonDivider()
            NeonRow("Highlight days") { highlightPicker }
            NeonDivider()
            NeonRow("Show event dots") {
                Toggle("", isOn: binding(\.showEventDots)).labelsHidden()
            }
            if style.showEventDots {
                NeonRow("Use colored dots", subtitle: "One dot per calendar, in its color") {
                    Toggle("", isOn: binding(\.useColoredDots)).labelsHidden()
                }
            }
            NeonRow("Show event location") {
                Toggle("", isOn: binding(\.showEventLocation)).labelsHidden()
            }
            NeonRow("Show days with no events") {
                Toggle("", isOn: binding(\.showDaysWithNoEvents)).labelsHidden()
            }
            NeonRow("Show calendar weeks", subtitle: "ISO week numbers beside the grid") {
                Toggle("", isOn: binding(\.showWeekNumbers)).labelsHidden()
            }
            NeonDivider()
            NeonRow("Event list shows") {
                Picker("", selection: binding(\.agendaDays)) {
                    ForEach(CalendarGridMath.agendaOptions, id: \.days) {
                        Text($0.label).tag($0.days)
                    }
                }
                .labelsHidden().frame(width: sz(120))
            }
        }
    }

    /// Seven checkboxes in week order (Itsycal's highlight picker).
    private var highlightPicker: some View {
        HStack(spacing: sz(8)) {
            ForEach(0..<7, id: \.self) { col in
                let wd = CalendarGridMath.weekday(
                    forColumn: col, firstWeekday: style.resolvedFirstWeekday)
                VStack(spacing: sz(2)) {
                    Text(Calendar.current.veryShortStandaloneWeekdaySymbols[wd - 1])
                        .font(Neon.font(10))
                        .foregroundStyle(Neon.textSecondary)
                    Toggle("", isOn: Binding(
                        get: { style.isHighlighted(weekday: wd) },
                        set: { style.setHighlighted(weekday: wd, $0); commit() }))
                        .labelsHidden().toggleStyle(.checkbox)
                }
            }
        }
    }

    // MARK: - Calendars checklist

    private var calendarsSection: some View {
        NeonSection("Calendars") {
            if !accessGranted {
                NeonRow("Calendar access",
                        subtitle: "Grant access to choose which calendars appear") {
                    Button("Request Access") {
                        CalendarBarController.shared.requestAccess { granted in
                            accessGranted = granted
                            if granted { reloadGroups() }
                            else { PermissionsManager.openSettings(forPermission: "calendar") }
                        }
                    }
                }
            } else if groups.isEmpty {
                NeonRow("No calendars found") { EmptyView() }
            } else {
                ForEach(groups) { group in
                    NeonRow(group.title) { EmptyView() }
                    ForEach(group.calendars) { cal in
                        HStack(spacing: sz(8)) {
                            Toggle("", isOn: calendarBinding(cal.id)).labelsHidden()
                                .toggleStyle(.checkbox)
                            Circle().fill(cal.color.color)
                                .frame(width: sz(8), height: sz(8))
                            Text(cal.title)
                                .font(Neon.font(12))
                                .foregroundStyle(Neon.textPrimary)
                            Spacer()
                        }
                        .padding(.leading, sz(16)).padding(.vertical, sz(2))
                    }
                    if group.id != groups.last?.id { NeonDivider() }
                }
            }
        }
    }

    private func reloadGroups() {
        accessGranted = CalendarEventCenter.authorized
        guard accessGranted else { return }
        groups = CalendarBarController.shared.calendarGroups()
    }

    /// nil selection = "all calendars". The first explicit toggle materializes
    /// the full identifier list so future calendars default to unchecked only
    /// after the user has expressed a choice.
    private func calendarBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { style.isCalendarSelected(id) },
            set: { on in
                var selected = style.selectedCalendarIDs
                    ?? groups.flatMap { $0.calendars.map(\.id) }
                if on { if !selected.contains(id) { selected.append(id) } }
                else { selected.removeAll { $0 == id } }
                style.selectedCalendarIDs = selected
                commit()
            })
    }

    // MARK: - Write-through

    private func binding<T>(_ keyPath: WritableKeyPath<CalendarBarStyle, T>) -> Binding<T> {
        Binding(get: { style[keyPath: keyPath] },
                set: { style[keyPath: keyPath] = $0; commit() })
    }

    /// Debounced save + controller reload — 120 ms after the last edit.
    private func commit() {
        commitWork?.cancel()
        let snapshot = style
        let work = DispatchWorkItem {
            CalendarBarStyleStore.save(snapshot)
            NotificationCenter.default.post(name: .calendarBarConfigChanged, object: nil)
        }
        commitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
}
