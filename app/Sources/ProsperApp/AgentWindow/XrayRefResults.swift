import AppKit

/// #1567 (X-ray C1, spec 5.8): one window's --ref results, keyed (session target, ref, mode, scope); the oldest use goes
/// first past 64 keys or 32 MB, and an entry is kept 30 s on the injected clock. A full result serves a later hover's
/// light ask; a light one never serves a full ask (a pin, a Refs row), #1824: it only opens that card while the full
/// read runs (XrayPanels.runRef `staged`). A follow's `ref` delta for the ref, an `evict`
/// (dch README v1.99.0:2201: shell only, no key) and a `reset` rotated / shrunk / cleared (:2204-2212) drop entries;
/// the window's hide empties it and its close forgets it (XrayRequests' hide and close, XrayRequests.swift:67-81).
@MainActor
final class XrayRefResults {
    struct Key: Equatable {
        let target: XrayTarget
        /// The ref as the card names it (runRef's `shown`, else the text sent).
        let ref: String
        let light: Bool
        let scope: String
    }

    static let maxKeys = 64
    static let maxBytes = 32 * 1024 * 1024
    static let keptFor: TimeInterval = 30
    /// The resets that drop a session's entries (README v1.99.0:2206-2212); `evicted` and `full` keep them (entry text).
    static let resets: Set<String> = ["rotated", "shrunk", "cleared"]

    var now: @MainActor () -> Date = { Date() }
    /// Oldest use first.
    /// #1760: `parsed`: the answer's stream, parsed off main by the read that put it, so a hit parses nothing on main.
    private(set) var entries: [(key: Key, out: Data, at: Date, parsed: XrayRefStream?, cost: Int)] = []
    /// #1772: `out` plus the parsed stream's estimate (cost, worked out once in put). Each cost is at most maxBytes (put
    /// refuses more) and at most maxKeys are kept: the sum cannot overflow.
    var bytes: Int { entries.reduce(0) { $0 + $1.cost } }

    /// #1772: a parsed stream's size, estimated: the kept strings' UTF-8 bytes plus a constant per struct and run.
    static let perItem = 64
    static func estimate(_ s: XrayRefStream) -> Int {
        var n = s.definitions.count * perItem + s.mentions.count * perItem
        for d in s.definitions { n += d.title.utf8.count + d.passage.utf8.count + d.rule.utf8.count }
        for m in s.mentions {
            n += m.line.utf8.count + m.fold.utf8.count + m.rich.count * perItem
            for r in m.rich { n += r.text.utf8.count }
            if let t = m.sentence { n += t.before.utf8.count + t.hit.utf8.count + t.after.utf8.count }
        }
        return n
    }

    /// A read's exit-0 answer. One over the byte cap is never kept.
    func put(_ k: Key, _ out: Data, parsed: XrayRefStream? = nil) {
        let t = now()
        entries.removeAll { $0.key == k || t.timeIntervalSince($0.at) >= Self.keptFor }   // #1772: stale ones go on put too
        let cost = out.count + (parsed.map(Self.estimate) ?? 0)
        guard cost <= Self.maxBytes else { return }
        entries.append((k, out, t, parsed, cost))
        while entries.count > Self.maxKeys || bytes > Self.maxBytes { entries.removeFirst() }
    }

    /// The kept answer for `k` within 30 s: a full ask takes a full result only; a light one a full result first, else a
    /// light one. `light`: the answer served came from a light read. A hit becomes the newest use.
    func get(_ k: Key) -> (out: Data, light: Bool, parsed: XrayRefStream?)? {
        let t = now()
        entries.removeAll { t.timeIntervalSince($0.at) >= Self.keptFor }
        let full = Key(target: k.target, ref: k.ref, light: false, scope: k.scope)
        guard let i = entries.firstIndex(where: { $0.key == full }) ?? (k.light ? entries.firstIndex(where: { $0.key == k }) : nil)
        else { return nil }
        let e = entries.remove(at: i)
        entries.append(e)
        return (e.out, e.key.light, e.parsed)
    }

    func clear() { entries = [] }

    /// One follow line of `target`'s session (XrayFollow.take, every schema-1 line): a `ref` delta drops that ref's
    /// entries (by its key or text), an `evict` or a dropping `reset` the session's.
    func take(_ target: XrayTarget, _ o: [String: Any]) {
        if let r = o["ref"] as? [String: Any] {
            let names = [r["key"], r["text"]].compactMap { ($0 as? String).map { OutsideText.shown($0, max: XrayRefs.maxRefBytes) } }
            entries.removeAll { $0.key.target == target && names.contains($0.key.ref) }
        } else if o["evict"] != nil || ((o["reset"] as? [String: Any])?["why"] as? String).map(Self.resets.contains) == true {
            entries.removeAll { $0.key.target == target }
        }
    }

    // MARK: the windows

    /// Each window's cache, by the window's identity (a close forgets it, so an identity is never reused while kept).
    private(set) static var windows: [ObjectIdentifier: XrayRefResults] = [:]
    /// Off under XCTest as XrayPanels.searchTab is, so rows that count spawns keep them; rows set it and restore it.
    static var on: @MainActor () -> Bool = { NSClassFromString("XCTestCase") == nil }
    private static var observing = false

    /// `w`'s cache (made on first use; the hide and close observers go on with the first one).
    static func of(_ w: NSWindow) -> XrayRefResults {
        if !observing { observing = true; observe(.default) }
        if let c = windows[ObjectIdentifier(w)] { return c }
        let c = XrayRefResults()
        windows[ObjectIdentifier(w)] = c
        return c
    }

    /// The follow hook (XrayFollow.take): every window's cache hears the line.
    static func followed(_ target: XrayTarget, _ o: [String: Any]) {
        guard !windows.isEmpty else { return }
        for c in windows.values { c.take(target, o) }
    }

    /// Hide (not visible: miniaturized, covered, another Space, the app hidden) empties the window's cache; close forgets it.
    @discardableResult
    static func observe(_ center: NotificationCenter) -> [NSObjectProtocol] {
        let hide = center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { n in
            let w = n.object as? NSWindow
            MainActor.assumeIsolated {
                guard let w, !w.occlusionState.contains(.visible) else { return }
                windows[ObjectIdentifier(w)]?.clear()
            }
        }
        let close = center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { n in
            let w = n.object as? NSWindow
            MainActor.assumeIsolated {
                guard let w else { return }
                windows[ObjectIdentifier(w)]?.clear()
                windows[ObjectIdentifier(w)] = nil
            }
        }
        return [hide, close]
    }

    /// Rows: register `c` as `w`'s cache, or forget every window's.
    static func set(_ c: XrayRefResults?, for w: NSWindow?) {
        guard let w else { return windows = [:] }
        windows[ObjectIdentifier(w)] = c
    }
}
