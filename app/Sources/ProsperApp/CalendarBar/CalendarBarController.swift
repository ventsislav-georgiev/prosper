// Owns the menu-bar Calendar end to end: the NSStatusItem with its SwiftUI
// icon (day badge / outline / glyph / custom pattern), the transient popover
// with the Itsycal-style month grid + agenda, day-change/wake observers plus a
// minute tick (only while a time-bearing custom pattern is shown), and the
// EventKit fetch orchestration. Gated by the com.prosper.calendar system
// extension (ships default-disabled): `extLive` is set by AppDelegate at launch
// and on every extension toggle; `reload()` brings the feature up or tears it
// fully down — a disabled install never touches EventKit at all.

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted by the settings pane when the calendar style changes.
    static let calendarBarConfigChanged = Notification.Name("calendarBarConfigChanged")
}

/// Shared observable state for the menu-bar icon + popup. The controller pushes
/// style/date/event changes here; all hosted SwiftUI views observe this one
/// object so the icon and any open popup redraw together.
@MainActor
final class CalendarBarStore: ObservableObject {
    @Published var style: CalendarBarStyle
    @Published var today: Date
    @Published var now: Date          // minute-tick for time-bearing patterns
    @Published var monthAnchor: Date  // any date inside the displayed month
    @Published var selectedDay: Date
    @Published var eventsByDay: [Date: [CalendarEventInfo]] = [:]
    @Published var pinned = false     // popover survives focus loss while set
    @Published var accessGranted = CalendarEventCenter.authorized

    var calendar = Calendar.autoupdatingCurrent

    init(style: CalendarBarStyle) {
        self.style = style
        let start = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        today = start
        now = Date()
        monthAnchor = start
        selectedDay = start
    }

    /// Colors for the event dots under a day cell (max 3, Itsycal rule).
    /// Colored mode: one dot per distinct calendar. Plain mode: empty array —
    /// the cell draws a single text-colored dot when the day has events.
    func dotColors(for day: Date) -> [RGBAColor] {
        guard let events = eventsByDay[day], !events.isEmpty else { return [] }
        guard style.useColoredDots else { return [] }
        var seen: Set<String> = []
        var colors: [RGBAColor] = []
        for e in events where !seen.contains(e.calendarID) {
            seen.insert(e.calendarID)
            colors.append(e.color)
            if colors.count == 3 { break }
        }
        return colors
    }

    func hasEvents(on day: Date) -> Bool { !(eventsByDay[day]?.isEmpty ?? true) }
}

@MainActor
final class CalendarBarController {
    static let shared = CalendarBarController()

    /// Whether the calendar extension is enabled + trusted. Set by AppDelegate
    /// at launch and from onEnabledChanged — same gate shape as MenuBarManager.
    var extLive = false

    /// Opens the Settings window (wired by AppDelegate; the controller has no
    /// AppDelegate reference of its own).
    var openSettingsHandler: (() -> Void)?

    private let store = CalendarBarStore(style: CalendarBarStyleStore.load())
    private let eventCenter = CalendarEventCenter()
    private var item: NSStatusItem?
    private var host: NSHostingView<CalendarIconWidget>?
    private lazy var popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = false
        p.delegate = popoverDelegate
        return p
    }()
    private lazy var popoverDelegate = CalendarPopoverDelegate { [weak self] in
        guard let self else { return }
        self.updateOutsideClickMonitor()
        // Drop the hosting controller once truly closed so the SwiftUI view
        // deallocs (idle-CPU teardown rule — a closed-but-alive hosting view
        // keeps rendering). Deferred + re-guarded to survive reshow races.
        if !self.popover.isShown {
            DispatchQueue.main.async {
                if !self.popover.isShown { self.popover.contentViewController = nil }
            }
        }
    }
    private var outsideClickMonitor: Any?
    private var minuteTimer: DispatchSourceTimer?
    /// Process-lifetime observers; the controller is a singleton, never removed.
    private var configObserver: NSObjectProtocol?
    private var dayChangeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var selectionObserver: AnyCancellable?
    private var lastIconWidthKey = ""

    private init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .calendarBarConfigChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Midnight rollover. A mach-time DispatchSourceTimer pauses during
        // sleep, so a Mac asleep over midnight kept showing yesterday until the
        // timer finally fired hours late. NSCalendarDayChanged covers midnight,
        // a wake that crossed midnight, and timezone/clock changes.
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rollToToday() }
        }
        // Wake also re-syncs `now` so a time-bearing pattern doesn't show the
        // pre-sleep minute until its next tick.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rollToToday() }
        }
        eventCenter.onStoreChanged = { [weak self] in self?.refetch() }
        // Agenda is anchored to the selected day — refetch when it moves so the
        // span past the visible grid has events. receive(on:) defers past the
        // @Published willSet so refetch reads the NEW value.
        selectionObserver = store.$selectedDay.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refetch() }
    }

    /// Bring the feature to match extension state + style. Idempotent — called
    /// at launch, on extension toggle, and on every settings change.
    func reload() {
        store.style = CalendarBarStyleStore.load()
        guard extLive else { teardown(); return }

        if !CalendarEventCenter.authorized {
            // First enable: request the TCC grant now so the popup has data.
            // The status item still appears immediately; events fill in on grant.
            eventCenter.requestAccess { [weak self] granted in
                self?.store.accessGranted = granted
                if granted { self?.refetch() }
            }
        }

        syncItem()
        rollToToday()
        syncMinuteTimer()
        refetch()
    }

    // MARK: - Status item

    private func syncItem() {
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "ProsperCalendar"
            // .content: stays in the menubar-management ordering/preview set.
            ProsperStatusItems.register(item, role: .content, name: "Calendar")
            if let button = item.button {
                let host = NSHostingView(rootView: CalendarIconWidget(store: store))
                host.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(host)
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                    host.topAnchor.constraint(equalTo: button.topAnchor),
                    host.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                ])
                button.target = self
                button.action = #selector(itemClicked(_:))
                self.host = host
            }
            self.item = item
        }
        resizeItem()
    }

    /// Width memo keyed on the width-driving text — a `length` write relayouts
    /// the whole menu bar, so only write when the rendered text actually moved.
    private func resizeItem() {
        guard let item, let host else { return }
        let key = CalendarIconWidget.widthKey(style: store.style, today: store.today,
                                              now: store.now, calendar: store.calendar)
            + "|\(ThemeRuntime.scale)"
        guard key != lastIconWidthKey else { return }
        lastIconWidthKey = key
        host.layoutSubtreeIfNeeded()
        let w = host.fittingSize.width
        if w > 0, abs(item.length - w) > 0.5 { item.length = w }
    }

    @objc private func itemClicked(_ sender: NSStatusBarButton) {
        togglePopup()
    }

    /// Toggle the popup — shared by the status-item click and the rebindable
    /// global shortcut.
    func togglePopup() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item?.button else { return }
        // Reset navigation to today on open (Itsycal behaviour).
        store.today = store.calendar.startOfDay(for: Date())
        store.monthAnchor = store.today
        store.selectedDay = store.today
        refetch()
        let host = NSHostingController(rootView: CalendarPopupView(
            store: store,
            onMonthChanged: { [weak self] in self?.refetch() },
            onPinChanged: { [weak self] pinned in
                self?.popover.behavior = pinned ? .applicationDefined : .transient
            },
            onOpenSettings: { [weak self] in
                self?.popover.performClose(nil)
                self?.openSettingsHandler?()
            },
            onClose: { [weak self] in self?.popover.performClose(nil) },
            onRowsChanged: { [weak self] rows in self?.persistRows(rows) }))
        // Size the popover to the SwiftUI content BEFORE anchoring — without
        // this the first show anchors a 0×0 popover that then grows offscreen.
        host.sizingOptions = [.preferredContentSize]
        popover.behavior = store.pinned ? .applicationDefined : .transient
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Accessory-app popover: without key status the first click inside only
        // activates the window and SwiftUI never sees it ("first click on
        // another day does nothing"). Make it key on open.
        host.view.window?.makeKey()
    }

    /// Persist a grid-row resize (drag handle) without routing through the pane.
    private func persistRows(_ rows: Int) {
        var style = CalendarBarStyleStore.load()
        style.gridRows = rows
        CalendarBarStyleStore.save(style)
        store.style.gridRows = rows
        refetch()   // more rows = wider visible range
    }

    /// Global outside-click monitor: as an LSUIElement accessory app the
    /// transient popover doesn't reliably see dismissing clicks on the desktop,
    /// so close explicitly. Global monitors never fire for our own windows, so
    /// clicks inside the popover are unaffected. Skipped while pinned.
    private func updateOutsideClickMonitor() {
        if popover.isShown, !store.pinned {
            guard outsideClickMonitor == nil else { return }
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self, !self.store.pinned else { return }
                self.popover.performClose(nil)
            }
        } else if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Timers

    /// Re-anchor "today"/`now` and re-render — midnight, wake, timezone/clock
    /// change, and `reload()`.
    private func rollToToday() {
        guard extLive, item != nil else { return }
        store.now = Date()
        let day = store.calendar.startOfDay(for: Date())
        if store.today != day {
            store.today = day
            refetch()
        }
        resizeItem()
    }

    /// A per-minute tick only while a custom pattern renders time fields —
    /// day-number modes never pay a timer. Second-precision patterns are
    /// deliberately ticked per-minute too (a menu-bar seconds clock is out of
    /// scope; the field still shows, just updates once a minute).
    private func syncMinuteTimer() {
        let needsTick = store.style.iconMode == .pattern
            && CalendarIconWidget.patternHasTimeFields(store.style.datetimePattern)
        if needsTick {
            guard minuteTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            let toNextMinute = 60 - Date().timeIntervalSince1970
                .truncatingRemainder(dividingBy: 60)
            timer.schedule(deadline: .now() + toNextMinute, repeating: 60, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in
                self?.store.now = Date()
                self?.resizeItem()
            }
            timer.resume()
            minuteTimer = timer
        } else {
            minuteTimer?.cancel()
            minuteTimer = nil
        }
    }

    // MARK: - Events

    /// Fetch the union of the visible grid and the agenda span in one go.
    /// Whole-range refetch on every navigation — an EventKit month query is
    /// single-digit milliseconds and runs off-main; the Itsycal-style
    /// incremental Julian cache is an upgrade path if it ever shows up in a
    /// profile.
    private func refetch() {
        guard extLive, CalendarEventCenter.authorized else { return }
        let calendar = store.calendar
        let style = store.style
        let gridStart = CalendarGridMath.gridStart(
            anchor: store.monthAnchor, firstWeekday: style.resolvedFirstWeekday,
            calendar: calendar)
        let gridEnd = calendar.date(byAdding: .day, value: style.gridRows * 7, to: gridStart)!
        let agendaEnd = calendar.date(byAdding: .day, value: max(style.agendaDays, 1),
                                      to: store.selectedDay)!
        let range = DateInterval(start: min(gridStart, store.selectedDay),
                                 end: max(gridEnd, agendaEnd))
        eventCenter.fetchEvents(range: range,
                                selectedCalendarIDs: style.selectedCalendarIDs,
                                calendar: calendar) { [weak self] byDay in
            self?.store.eventsByDay = byDay
        }
    }

    /// Calendar checklist data for the settings pane.
    func calendarGroups() -> [CalendarSourceGroup] { eventCenter.calendarGroups() }

    /// Settings-pane hook: request access when the user interacts with the
    /// checklist before the first grant.
    func requestAccess(_ completion: @escaping @MainActor (Bool) -> Void) {
        eventCenter.requestAccess { [weak self] granted in
            self?.store.accessGranted = granted
            if granted { self?.refetch() }
            completion(granted)
        }
    }

    private func teardown() {
        minuteTimer?.cancel(); minuteTimer = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil; host = nil
        lastIconWidthKey = ""
        store.eventsByDay = [:]
        if popover.isShown { popover.performClose(nil) }
    }
}

/// Bridges NSPopover open/close to the outside-click monitor + teardown.
private final class CalendarPopoverDelegate: NSObject, NSPopoverDelegate {
    let reconcile: () -> Void
    init(_ reconcile: @escaping () -> Void) { self.reconcile = reconcile }
    func popoverDidShow(_ n: Notification) { reconcile() }
    func popoverDidClose(_ n: Notification) { reconcile() }
}
