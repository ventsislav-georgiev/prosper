// #523: "Live status on iPhone". Posts this Mac's dch session states to the
// Worker (POST /push/sessions, server/src/pushLogic.mjs parseSessionsBody), which
// turns them into the iPhone's Live Activity pushes.
//
// The source is Agent Island's poller (AgentIslandController.onSessions): no dch
// poll of its own, so nothing is posted while Agent Island is off. The full list
// goes out on a change (coalesced over 2 s) and as the heartbeat, 60 s after the
// last post. Offline goes out on sleep, quit, sign-out, toggle-off and when the
// island stops. Posts only while signed in, activated and switched on; a 401/403
// stops posting until the next activation (sign-in activates).

import AppKit
import os.log

@MainActor
final class LiveStatusPublisher {
    static let shared = LiveStatusPublisher()

    /// One session as the Worker takes it.
    struct Session: Encodable, Equatable {
        let name: String
        var alias: String?
        let state: String
        var agents: Int?
    }

    private struct Body: Encodable {
        let mac_id: String
        let seq: Int64
        var sessions: [Session]?
        var offline: Bool?
    }

    static let debounce: TimeInterval = 2
    static let heartbeat: TimeInterval = 60
    nonisolated static let maxSessions = 20   // pushLogic MAX_SESSIONS
    nonisolated static let maxText = 64       // name and alias, in code points (pushLogic isText)

    // MARK: - Seams (tests swap every one; nothing here touches the network)

    var now: @MainActor () -> Date = { Date() }
    /// Runs `fire` on main after `delay`; returns its cancel.
    var after: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void = { delay, fire in
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !Task.isCancelled { fire() }
        }
        return { task.cancel() }
    }
    /// The POST; `done` gets the HTTP status on main, nil on a network error.
    var post: @MainActor (Data, String, @escaping @MainActor (Int?) -> Void) -> Void = { body, bearer, done in
        Task { @MainActor in done(await SupporterClient.postSessions(body, bearer: bearer)) }
    }
    /// Sleep and quit: the same POST, waited on briefly, as the Mac or the process stops next.
    var postAndWait: @MainActor (Data, String) -> Void = { SupporterClient.postSessionsAndWait($0, bearer: $1) }
    var bearer: @MainActor () -> String? = { SupporterStore.load()?.session }
    var isActivated: @MainActor () -> Bool = { Preferences.liveStatusActivated }
    var enabled: @MainActor () -> Bool = { Preferences.liveStatusEnabled }
    var macID: @MainActor () -> String = { SupporterStore.deviceID() }
    var center = NSWorkspace.shared.notificationCenter

    // MARK: - State

    /// The last list from the island; nil until it speaks and after it stops.
    private(set) var latest: [Session]?
    /// Posting (the last gate check passed and no offline went out since).
    private(set) var isLive = false
    /// A 401/403 came back: nothing posts until the next activation.
    private(set) var halted = false
    /// Asleep or quitting.
    private var paused = false
    private var lastSeq: Int64 = 0
    private var cancelDebounce: (() -> Void)?
    private var cancelHeartbeat: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var loggedBadRequest = false
    private static let log = Logger(subsystem: "eu.illegible.prosper", category: "livestatus")

    init() {}

    /// AppDelegate, once: sleep and wake.
    func start() {
        guard observers.isEmpty else { return }
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didWake() }
            },
        ]
    }

    // MARK: - Events

    /// Agent Island's sorted sessions, on main; nil when the island stops.
    func sessionsChanged(_ sessions: [AgentSession]?) {
        let wire = sessions.map(Self.wire)
        guard wire != latest else { return }   // an activity-only tick changes nothing here
        latest = wire
        guard isLive, wire != nil else { refresh(); return }
        if cancelDebounce == nil {
            cancelDebounce = after(Self.debounce) { [weak self] in self?.postList() }
        }
    }

    /// Re-check the gates (toggle, sign-in, activation): going live posts the full
    /// list at once, going quiet posts offline.
    func refresh() {
        let bearer = gatedBearer()
        if let bearer, !isLive {
            isLive = true
            postList(bearer)
        } else if bearer == nil, isLive {
            goQuiet()
            if let bearer = offlineBearer() { post(body(nil), bearer) { [weak self] in self?.handle($0) } }
        }
    }

    /// Sleep and quit: offline now, waited on; nothing more until wake.
    func pause() {
        paused = true
        guard isLive else { return }
        goQuiet()
        if let bearer = offlineBearer() { postAndWait(body(nil), bearer) }
    }

    /// Wake: the full list right away.
    func didWake() {
        paused = false
        refresh()
    }

    /// Sign-out, before the credentials go: the offline body for SupporterClient to
    /// send ahead of the session revoke, nil when nothing was live. Posts nothing itself.
    func signOut() -> Data? {
        halted = false   // the next sign-in starts clean
        guard isLive else { return nil }
        goQuiet()
        return offlineBearer() == nil ? nil : body(nil)
    }

    /// A successful POST /activate (every sign-in does one): a 401/403 stop lifts.
    func deviceActivated() {
        halted = false
        refresh()
    }

    // MARK: - Posting

    /// The bearer when every gate is open, else nil.
    private func gatedBearer() -> String? {
        guard latest != nil, !paused, !halted, enabled(), isActivated() else { return nil }
        return bearer()
    }

    /// Offline only where the Worker would take it: not after a 401/403, not deactivated.
    private func offlineBearer() -> String? {
        guard !halted, isActivated() else { return nil }
        return bearer()
    }

    private func goQuiet() {
        isLive = false
        cancelDebounce?(); cancelDebounce = nil
        cancelHeartbeat?(); cancelHeartbeat = nil
    }

    private func postList(_ checked: String? = nil) {
        cancelDebounce?(); cancelDebounce = nil
        guard isLive, let latest else { return }
        guard let bearer = checked ?? gatedBearer() else { refresh(); return }   // a gate closed unseen
        cancelHeartbeat?()
        cancelHeartbeat = after(Self.heartbeat) { [weak self] in self?.postList() }
        post(body(latest), bearer) { [weak self] in self?.handle($0) }
    }

    /// 2xx: fine. 401/403: stop until activation. 429, 5xx, 400, 413 and network errors:
    /// no retry of our own; the next change or heartbeat sends the full list again.
    private func handle(_ code: Int?) {
        switch code {
        case 401, 403:
            halted = true
            goQuiet()
        case 400, 413:   // a bug on our side: logged once, then treated like a 5xx
            if !loggedBadRequest {
                loggedBadRequest = true
                Self.log.error("live status: the Worker answered \(code ?? 0, privacy: .public) to a sessions post")
            }
        default:
            break
        }
    }

    /// `{mac_id, seq, sessions}`, or `{mac_id, seq, offline: true}` for nil. seq is
    /// wall-clock ms, strictly increasing: max(now, last + 1).
    func body(_ sessions: [Session]?) -> Data {
        let ms = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
        lastSeq = max(ms, lastSeq + 1)
        let b = Body(mac_id: macID(), seq: lastSeq, sessions: sessions, offline: sessions == nil ? true : nil)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(b)) ?? Data()
    }

    // MARK: - Wire list

    /// The island's (urgency-sorted) sessions as the Worker takes them: stripped,
    /// cut to 64 code points, deduped by name, empty names dropped, at most 20.
    nonisolated static func wire(_ sessions: [AgentSession]) -> [Session] {
        var seen = Set<String>(), out: [Session] = []
        for s in sessions where out.count < maxSessions {
            let name = clean(s.name)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            let alias = clean(s.alias)
            out.append(Session(name: name, alias: alias.isEmpty ? nil : alias, state: s.state.wireName,
                               agents: s.agents > 0 ? min(s.agents, 999) : nil))
        }
        return out
    }

    /// Strip the characters the Worker rejects, then keep the first 64 scalars. A
    /// String is always well-formed and a scalar cut never splits a surrogate pair.
    nonisolated static func clean(_ s: String) -> String {
        var v = String.UnicodeScalarView(), n = 0
        for u in s.unicodeScalars where !isStripped(u) {
            v.append(u)
            n += 1
            if n == maxText { break }
        }
        return String(v)
    }

    /// Mirrors the Worker's CTRL_RE (pushLogic.mjs): every control, format, line or
    /// paragraph separator (C0, DEL, C1, bidi marks, zero-width, BOM, U+2028/2029,
    /// U+FFF9-FFFB, U+E0001...), except U+200D ZWJ and the tags U+E0020-E007F, which
    /// build emoji (subdivision flags). Narrower than AgentPrompt.isHidden on purpose.
    nonisolated static func isStripped(_ u: Unicode.Scalar) -> Bool {
        if u.value == 0x200D || (0xE0020...0xE007F).contains(u.value) { return false }
        switch u.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}

extension AgentState {
    /// The state name the Worker takes (pushLogic RANK).
    var wireName: String {
        switch self {
        case .blocked: "blocked"
        case .working: "working"
        case .done: "done"
        case .idle: "idle"
        }
    }
}
