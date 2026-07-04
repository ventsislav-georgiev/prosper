// EventKit access for the menu-bar Calendar: authorization, calendar list
// (grouped by EKSource for the settings checklist), and per-day event fetch.
//
// The EKEventStore is created lazily on first use — instantiating one is
// harmless, but we never touch EventKit at all until the extension is enabled,
// so a disabled install shows no Calendar entry in Privacy & Security.
// Fetches run on a background queue (EKEventStore is thread-safe; EKEvent
// objects are not, so everything is copied into plain Sendable structs before
// hopping back to the main thread).

import AppKit
import EventKit

/// One attendee of an event, for the detail view.
struct CalendarAttendee: Equatable, Sendable {
    enum Status: Equatable, Sendable { case accepted, declined, pending, unknown }
    let name: String
    let status: Status
}

/// One occurrence-day of an event, pre-flattened for the popup. A multi-day
/// event contributes one info per visible day, tagged with span position.
struct CalendarEventInfo: Identifiable, Equatable, Sendable {
    let id: String              // eventIdentifier + day, unique per (event, day)
    let title: String
    let location: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let isStartDay: Bool        // this info's day is the event's first day
    let isEndDay: Bool
    let isTentative: Bool       // pending/tentative → stroked (not filled) dot
    let color: RGBAColor        // the calendar's colour
    let calendarID: String
    let videoURL: URL?          // detected conference link, if any
    let notes: String           // event notes, "" when none (detail view)
    let attendees: [CalendarAttendee]
}

/// A calendar row for the settings checklist.
struct CalendarListEntry: Identifiable, Equatable, Sendable {
    let id: String              // calendarIdentifier
    let title: String
    let color: RGBAColor
}

/// Calendars grouped by their EKSource (Google / iCloud / Other / Subscribed…).
struct CalendarSourceGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let calendars: [CalendarListEntry]
}

@MainActor
final class CalendarEventCenter {

    /// Fired (on main) whenever the underlying store reports a change — the
    /// controller refetches the visible range.
    var onStoreChanged: (() -> Void)?

    private var store: EKEventStore?
    private var changeObserver: NSObjectProtocol?
    private let fetchQueue = DispatchQueue(label: "prosper.calendarbar.fetch", qos: .userInitiated)
    /// Monotonic fetch token — a stale background fetch (user paged months
    /// quickly) is dropped instead of overwriting a newer result.
    private var fetchGeneration = 0

    static var authorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Idempotent store setup + change observation.
    private func ensureStore() -> EKEventStore {
        if let store { return store }
        let s = EKEventStore()
        store = s
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: s, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onStoreChanged?() }
        }
        return s
    }

    /// Request full read access (macOS 14+ API; the app's floor is 14.0).
    /// Completion on main with the resulting grant state.
    func requestAccess(_ completion: @escaping @MainActor (Bool) -> Void) {
        if Self.authorized { completion(true); return }
        ensureStore().requestFullAccessToEvents { granted, _ in
            Task { @MainActor in completion(granted) }
        }
    }

    // MARK: - Calendar list

    /// All event calendars grouped by source, for the settings checklist.
    func calendarGroups() -> [CalendarSourceGroup] {
        guard Self.authorized else { return [] }
        let calendars = ensureStore().calendars(for: .event)
        var groups: [String: (title: String, cals: [CalendarListEntry])] = [:]
        var order: [String] = []
        for cal in calendars {
            let sourceID = cal.source?.sourceIdentifier ?? "other"
            let sourceTitle = cal.source?.title ?? "Other"
            if groups[sourceID] == nil {
                groups[sourceID] = (sourceTitle, [])
                order.append(sourceID)
            }
            groups[sourceID]?.cals.append(CalendarListEntry(
                id: cal.calendarIdentifier, title: cal.title,
                color: RGBAColor(cgColor: cal.cgColor)))
        }
        return order.compactMap { id in
            guard let g = groups[id] else { return nil }
            return CalendarSourceGroup(
                id: id, title: g.title,
                calendars: g.cals.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
        }
    }

    // MARK: - Event fetch

    /// Fetch events in `range` from the selected calendars and deliver them on
    /// main as a per-day map (keys = startOfDay). Declined events are skipped;
    /// multi-day events are expanded into one entry per visible day.
    func fetchEvents(range: DateInterval, selectedCalendarIDs: [String]?,
                     calendar: Calendar,
                     completion: @escaping @MainActor ([Date: [CalendarEventInfo]]) -> Void) {
        guard Self.authorized else { completion([:]); return }
        let store = ensureStore()
        let calendars = store.calendars(for: .event).filter {
            selectedCalendarIDs?.contains($0.calendarIdentifier) ?? true
        }
        guard !calendars.isEmpty else { completion([:]); return }
        let predicate = store.predicateForEvents(
            withStart: range.start, end: range.end, calendars: calendars)
        fetchGeneration += 1
        let generation = fetchGeneration
        fetchQueue.async { [weak self] in
            let events = store.events(matching: predicate)
            let byDay = Self.expand(events: events, range: range, calendar: calendar)
            Task { @MainActor in
                guard let self, generation == self.fetchGeneration else { return }
                completion(byDay)
            }
        }
    }

    /// Flatten EKEvents into per-day plain structs. Runs off-main; touches the
    /// EKEvent objects only here, never after the hop.
    private nonisolated static func expand(events: [EKEvent], range: DateInterval,
                                           calendar: Calendar) -> [Date: [CalendarEventInfo]] {
        var byDay: [Date: [CalendarEventInfo]] = [:]
        for event in events {
            guard let start = event.startDate, let end = event.endDate else { continue }
            if let me = event.attendees?.first(where: { $0.isCurrentUser }),
               me.participantStatus == .declined { continue }
            let isTentative = event.availability == .tentative
                || event.status == .tentative
                || (event.attendees?.first(where: { $0.isCurrentUser })
                        .map { $0.participantStatus == .pending } ?? false)
            let color = RGBAColor(cgColor: event.calendar?.cgColor)
            let video = detectVideoURL(event)
            let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let attendees: [CalendarAttendee] = (event.attendees ?? []).map { p in
                let name = p.name ?? p.url.absoluteString
                    .replacingOccurrences(of: "mailto:", with: "")
                let status: CalendarAttendee.Status = switch p.participantStatus {
                case .accepted: .accepted
                case .declined: .declined
                case .pending, .tentative: .pending
                default: .unknown
                }
                return CalendarAttendee(name: name, status: status)
            }
            let firstDay = calendar.startOfDay(for: start)
            // A timed event "covers" every day it overlaps; an all-day event's
            // endDate is the exclusive midnight, so back it off by a second to
            // avoid bleeding into an extra day.
            let effectiveEnd = end > start ? end.addingTimeInterval(-1) : start
            let lastDay = calendar.startOfDay(for: effectiveEnd)
            var day = max(firstDay, calendar.startOfDay(for: range.start))
            let stop = min(lastDay, calendar.startOfDay(for: range.end))
            while day <= stop {
                let info = CalendarEventInfo(
                    id: (event.eventIdentifier ?? event.calendarItemIdentifier) + "@\(day.timeIntervalSince1970)",
                    title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled",
                    location: event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    startDate: start, endDate: end,
                    isAllDay: event.isAllDay,
                    isStartDay: day == firstDay, isEndDay: day == lastDay,
                    isTentative: isTentative,
                    color: color,
                    calendarID: event.calendar?.calendarIdentifier ?? "",
                    videoURL: video,
                    notes: notes,
                    attendees: attendees)
                byDay[day, default: []].append(info)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        // Sort each day: all-day first, then by start time (Itsycal agenda order).
        for (day, infos) in byDay {
            byDay[day] = infos.sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return $0.startDate < $1.startDate
            }
        }
        return byDay
    }

    /// Detect a video-conference link in the event URL / location / notes.
    /// Zoom links are the Itsycal baseline; Meet/Teams/Webex/FaceTime cover the
    /// rest of the common macOS meeting stack.
    private nonisolated static func detectVideoURL(_ event: EKEvent) -> URL? {
        var haystacks: [String] = []
        if let u = event.url?.absoluteString { haystacks.append(u) }
        if let l = event.location { haystacks.append(l) }
        if let n = event.notes { haystacks.append(n) }
        guard !haystacks.isEmpty else { return nil }
        let pattern = #"https://[^\s<>"']*(zoom\.us/[jsw]/|zoomgov\.com/[jsw]/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join|\.webex\.com/(meet|join)/|facetime\.apple\.com/join)[^\s<>"']*"#
        for hay in haystacks {
            if let range = hay.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
               let url = URL(string: String(hay[range])) {
                return url
            }
        }
        return nil
    }
}

extension RGBAColor {
    /// Lossy read of a CGColor (EKCalendar.cgColor) into the app's codable
    /// colour. Falls back to the Neon accent-ish blue when conversion fails.
    init(cgColor: CGColor?) {
        if let cg = cgColor, let ns = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) {
            self.init(Double(ns.redComponent), Double(ns.greenComponent),
                      Double(ns.blueComponent), Double(ns.alphaComponent))
        } else {
            self.init(0.36, 0.68, 1.00)
        }
    }
}
