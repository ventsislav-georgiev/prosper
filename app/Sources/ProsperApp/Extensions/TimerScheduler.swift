import Foundation
import os

/// Host-owned durable timer scheduler — the stateless-extension replacement for
/// Hammerspoon's `hs.timer.doAfter/doEvery` (which hold a live Lua closure across
/// the session). Instead, an extension schedules a timer by *name of handler*; the
/// host owns the `DispatchSourceTimer`, persists the schedule, and on fire delivers
/// a `timer.fired` event back into the extension's serialized invoke lane. No
/// resident VM, no Lua closure held natively.
///
/// Durability: entries are persisted to UserDefaults and re-armed on launch. A
/// one-shot (`after`) that elapsed while the app was quit fires once on restore
/// (fire-overdue policy — openlid's expiry depends on it). A repeating (`every`)
/// timer reschedules from now.
///
/// Concurrency: all state is confined to `queue`. `deliver` is invoked from that
/// queue; the registry hops to the MainActor inside it. See
/// .omc/plans/hammerspoon-parity-host-api.md §2.2.
final class TimerScheduler: @unchecked Sendable {

    static let shared = TimerScheduler()

    /// One persisted timer. `every == false` is a one-shot; `interval` is the delay
    /// (one-shot) or period (repeating). `fireAt` is the next absolute epoch second.
    private struct Entry: Codable {
        let extID: String
        let id: String
        let handler: String
        let every: Bool
        let interval: Double
        var fireAt: Double
    }

    private let queue = DispatchQueue(label: "com.prosper.extensions.timers")
    private var entries: [String: Entry] = [:]          // key = "extID\u{1}id"
    private var sources: [String: DispatchSourceTimer] = [:]
    private let defaults: UserDefaults
    private let log = Logger(subsystem: "com.prosper.app", category: "ext-timers")

    private static let persistKey = "ext.timers.v1"

    /// Delivers a `timer.fired` event: (extensionID, handler, payloadJSON). Set by
    /// the app once the registry exists; nil → the fire is dropped (headless/test).
    var deliver: ((String, String, String) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func key(_ extID: String, _ id: String) -> String { "\(extID)\u{1}\(id)" }
    private func now() -> Double { Date().timeIntervalSince1970 }

    // MARK: - Public API (called from the extension async lane via host services)

    /// Schedule (or replace) a named timer for an extension. `seconds` is the delay
    /// (one-shot) or period (repeating); clamped to a sane floor so a buggy `every=0`
    /// can't spin.
    func schedule(extID: String, id: String, every: Bool, seconds: Double, handler: String) {
        let secs = max(seconds, every ? 0.05 : 0)
        queue.async {
            let entry = Entry(extID: extID, id: id, handler: handler, every: every,
                              interval: secs, fireAt: self.now() + secs)
            self.entries[Self.key(extID, id)] = entry
            self.persistLocked()
            self.armLocked(entry)
        }
    }

    /// Cancel a single named timer (no-op if absent).
    func cancel(extID: String, id: String) {
        queue.async { self.removeLocked(Self.key(extID, id)) ; self.persistLocked() }
    }

    /// Cancel every timer owned by an extension (used when it is disabled/reset).
    func cancelAll(extID: String) {
        queue.async {
            for k in self.entries.keys where self.entries[k]?.extID == extID { self.removeLocked(k) }
            self.persistLocked()
        }
    }

    /// Re-arm persisted timers at launch. Overdue one-shots fire once immediately.
    func restore() {
        queue.async {
            self.loadLocked()
            for (_, entry) in self.entries { self.armLocked(entry) }
        }
    }

    // MARK: - Internals (queue-confined)

    private func armLocked(_ entry: Entry) {
        let k = Self.key(entry.extID, entry.id)
        sources[k]?.cancel()
        let src = DispatchSource.makeTimerSource(queue: queue)
        let delay = max(entry.fireAt - now(), 0)
        if entry.every {
            src.schedule(deadline: .now() + delay, repeating: entry.interval)
        } else {
            src.schedule(deadline: .now() + delay)
        }
        src.setEventHandler { [weak self] in self?.fireLocked(k) }
        sources[k] = src
        src.resume()
    }

    private func fireLocked(_ k: String) {
        guard let entry = entries[k] else { return }
        deliver?(entry.extID, entry.handler, Self.firePayload(id: entry.id))
        if entry.every {
            // ponytail: do NOT persist on every repeating fire — a 0.05s timer would
            // hammer UserDefaults ~20×/sec. The fireAt bump only matters across a
            // relaunch, and restore re-arms from the (possibly stale) original fireAt:
            // worst case an overdue repeating timer fires once immediately, then
            // resumes cadence. So the in-memory bump is enough.
            entries[k]?.fireAt = now() + entry.interval
        } else {
            removeLocked(k)        // one-shot: durable removal must survive relaunch
            persistLocked()
        }
    }

    /// `{ "id": <name> }` with the extension-controlled id properly escaped — a name
    /// containing `"`/`\`/newline must not corrupt the JSON the handler decodes.
    static func firePayload(id: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["id": id]),
              let s = String(data: data, encoding: .utf8) else { return #"{"id":""}"# }
        return s
    }

    private func removeLocked(_ k: String) {
        sources[k]?.cancel()
        sources[k] = nil
        entries[k] = nil
    }

    private func persistLocked() {
        let list = Array(entries.values)
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: Self.persistKey)
    }

    private func loadLocked() {
        guard let data = defaults.data(forKey: Self.persistKey),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = Dictionary(uniqueKeysWithValues: list.map { (Self.key($0.extID, $0.id), $0) })
    }
}
