// #523: "Live status on iPhone". Posts this Mac's dch session states to the
// Worker (POST /push/sessions, server/src/pushLogic.mjs parseSessionsBody), which
// turns them into the iPhone's Live Activity pushes.
//
// The source is Agent Island's poller (AgentIslandController.onSessions): no dch
// poll of its own, so nothing is posted while Agent Island is off. The full list
// goes out on a change and as the heartbeat, 60 s after the last post. #766 (each post
// can wake the phone): a blocked edge or the card start goes out in 2 s, any other change
// in 25 s; the list is sorted by name, so a reorder is no change; the heartbeat stops once
// nothing has been working or blocked for 12 min. Offline goes out on sleep, quit (not a Sparkle update
// relaunch), sign-out, toggle-off and when the island stops. Posts only while signed in,
// activated and switched on; a 401/403 stops posting until the next activation (sign-in
// activates). A response to a post sent before the last sign-out or activation is
// ignored (#532).

import AppKit
import os.log
import Sparkle

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

    /// A blocked edge (a session entering or leaving blocked, the "needs you" latency) and the
    /// card start (nothing active -> something working or blocked, once per activity period).
    static let debounce: TimeInterval = 2
    /// #766 J6b: every other change (working <-> idle, done, alias, agents, a session
    /// coming or going) waits this long, so a burst of them is one post and one phone wake.
    static let calmDebounce: TimeInterval = 25
    static let heartbeat: TimeInterval = 60
    /// #766 J5: once nothing is working or blocked, heartbeats go on this long and then
    /// stop. The Worker ends an idle card at IDLE_END_S (600 s) + one cron minute, so it is
    /// ended (online) before the missing heartbeat lapses the Mac (LAPSE_S 180 s after the
    /// last one, which would end it as "Mac offline"). With no card left, a lapse is a D1 row.
    static let idleTail: TimeInterval = 720
    /// Sparkle posts this right before it installs and relaunches the app (#766 J7).
    static let updateWillRelaunch = Notification.Name.SUUpdaterWillRestart
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
    var loadSeq: @MainActor () -> Int64 = { Preferences.liveStatusSeq }
    var saveSeq: @MainActor (Int64) -> Void = { Preferences.liveStatusSeq = $0 }
    var center = NSWorkspace.shared.notificationCenter
    /// Where Sparkle posts updateWillRelaunch.
    var appCenter = NotificationCenter.default

    // MARK: - State

    /// The last list from the island; nil until it speaks and after it stops.
    private(set) var latest: [Session]?
    /// Posting (the last gate check passed and no offline went out since).
    private(set) var isLive = false
    /// A 401/403 came back: nothing posts until the next activation.
    private(set) var halted = false
    /// Asleep or quitting.
    private var paused = false
    /// The last seq sent, persisted (#532): a relaunch after a fast clock is fixed still
    /// posts above what the Worker stored, which drops a lower seq with a bare 204.
    /// Read on first use, after the seams are set.
    private lazy var lastSeq: Int64 = loadSeq()
    /// Bumped by sign-out and activation; each post carries the one it went out under,
    /// so a 401 sent before a sign-out cannot halt the next session (#532).
    private var generation = 0
    private var cancelDebounce: (() -> Void)?
    /// When the pending change post fires; an earlier one (a blocked edge) replaces it.
    private var debounceDue: Date?
    /// The list last sent while live: blocked edges are measured against it.
    private var posted: [Session]?
    /// When the posted list stopped having anything working or blocked; nil while it does.
    private var idleSince: Date?
    /// #766 J5: the session token, read from SupporterStore (a file and a keychain read)
    /// once, not per post. Dropped on sign-out, activation and a 401/403.
    private var bearerCache: String?
    /// Sparkle is relaunching the app into an update: the quit posts no offline.
    private(set) var updateRelaunch = false
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
            appCenter.addObserver(forName: Self.updateWillRelaunch, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRelaunch = true }
            },
        ]
    }

    // MARK: - Events

    /// Agent Island's sorted sessions, on main; nil when the island stops.
    func sessionsChanged(_ sessions: [AgentSession]?) {
        let wire = sessions.map(Self.wire)
        guard wire != latest else { return }   // an activity-only tick changes nothing here
        latest = wire
        guard isLive, let wire else { refresh(); return }
        // A blocked edge, or the card start (nothing working or blocked -> something is):
        // 2 s. Everything else, the card going idle included: 25 s.
        let urgent = Self.blocked(wire) != Self.blocked(posted ?? [])
            || (Self.isActive(wire) && !Self.isActive(posted ?? []))
        let delay = urgent ? Self.debounce : Self.calmDebounce
        let due = now().addingTimeInterval(delay)
        if let debounceDue, debounceDue <= due { return }   // an earlier post covers it
        cancelDebounce?()
        debounceDue = due
        cancelDebounce = after(delay) { [weak self] in self?.postList() }
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
            if let bearer = offlineBearer() { send(body(nil), bearer) }
        }
    }

    /// Quit (applicationWillTerminate): offline like a sleep, except when Sparkle is
    /// relaunching into an update (#766 J7). The new process posts the list within
    /// seconds, inside the Worker's 180 s lapse, so the phone's card just stays, where an
    /// offline would end it and push-start a new one (two phone wakes per update). A
    /// relaunch that never comes lapses the Mac after 180 s and ends the card then.
    func quit() {
        guard updateRelaunch else { pause(); return }
        paused = true
        goQuiet()
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
        generation += 1
        defer { bearerCache = nil }   // after the offline body's check: the session goes next
        guard isLive else { return nil }
        goQuiet()
        return offlineBearer() == nil ? nil : body(nil)
    }

    /// A successful POST /activate (every sign-in does one): a 401/403 stop lifts.
    func deviceActivated() {
        halted = false
        bearerCache = nil
        generation += 1
        refresh()
    }

    // MARK: - Posting

    /// The bearer when every gate is open, else nil.
    private func gatedBearer() -> String? {
        guard latest != nil, !paused, !halted, enabled(), isActivated() else { return nil }
        return cachedBearer()
    }

    /// Offline only where the Worker would take it: not after a 401/403, not deactivated.
    private func offlineBearer() -> String? {
        guard !halted, isActivated() else { return nil }
        return cachedBearer()
    }

    /// A missing token is not cached: signing in fills it.
    private func cachedBearer() -> String? {
        if bearerCache == nil { bearerCache = bearer() }
        return bearerCache
    }

    private func goQuiet() {
        isLive = false
        cancelDebounce?(); cancelDebounce = nil; debounceDue = nil
        cancelHeartbeat?(); cancelHeartbeat = nil
        posted = nil       // offline: the Worker holds no sessions for us any more
        idleSince = nil
    }

    private func postList(_ checked: String? = nil) {
        cancelDebounce?(); cancelDebounce = nil; debounceDue = nil
        guard isLive, let latest else { return }
        guard let bearer = checked ?? gatedBearer() else { refresh(); return }   // a gate closed unseen
        let t = now()
        if Self.isActive(latest) { idleSince = nil } else if idleSince == nil { idleSince = t }
        cancelHeartbeat?(); cancelHeartbeat = nil
        if idleSince.map({ t.timeIntervalSince($0) < Self.idleTail }) ?? true {
            cancelHeartbeat = after(Self.heartbeat) { [weak self] in self?.postList() }
        }
        posted = latest
        send(body(latest), bearer)
    }

    private func send(_ data: Data, _ bearer: String) {
        let gen = generation
        post(data, bearer) { [weak self] in self?.handle($0, gen) }
    }

    /// 2xx: fine. 401/403: stop until activation. 429, 5xx, 400, 413 and network errors:
    /// no retry of our own; the next change or heartbeat sends the full list again.
    /// A post from before the last sign-out or activation: ignored, whatever it got.
    private func handle(_ code: Int?, _ gen: Int) {
        guard gen == generation else { return }
        switch code {
        case 401, 403:
            halted = true
            bearerCache = nil
            goQuiet()
        case 400, 413:   // a clock or a bug on our side: logged once, then treated like a 5xx
            if code == 400 {
                // Most likely invalid_seq: a seq over 1 h ahead of the Worker, from a
                // clock that ran fast and was fixed. The next post goes out on wall time.
                lastSeq = 0
                saveSeq(0)
            }
            if !loggedBadRequest {
                loggedBadRequest = true
                Self.log.error("live status: the Worker answered \(code ?? 0, privacy: .public) to a sessions post")
            }
        default:
            break
        }
    }

    /// `{mac_id, seq, sessions}`, or `{mac_id, seq, offline: true}` for nil. seq is
    /// wall-clock ms, strictly increasing across relaunches: max(now, last + 1).
    func body(_ sessions: [Session]?) -> Data {
        let ms = Int64((now().timeIntervalSince1970 * 1000).rounded(.down))
        lastSeq = max(ms, lastSeq + 1)
        saveSeq(lastSeq)
        let b = Body(mac_id: macID(), seq: lastSeq, sessions: sessions, offline: sessions == nil ? true : nil)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(b)) ?? Data()
    }

    /// The Settings row's footnote (GeneralPane). On by default, but only while signed
    /// in and activated; it reads Agent Island's session list, so it says so while the
    /// island is off. A refused /activate (device_limit) leaves the toggle on: say why
    /// nothing posts (#532).
    nonisolated static func settingsNote(signedIn: Bool, activated: Bool, islandOn: Bool) -> String {
        var note = "Sends session names and states, never terminal text, to your Prosper account for the iPhone app's Live Activity."
        if !signedIn { note = "Sign in under Account to use it. " + note }
        else if !activated { note = "This Mac is not activated on your account, so nothing is sent. " + note }
        if !islandOn { note += " Needs Agent Island turned on." }
        return note
    }

    // MARK: - Wire list

    /// The pushLogic isActive: something working or blocked (a card can be showing).
    nonisolated static func isActive(_ list: [Session]) -> Bool {
        list.contains { $0.state == "working" || $0.state == "blocked" }
    }

    nonisolated static func blocked(_ list: [Session]) -> Set<String> {
        Set(list.lazy.filter { $0.state == "blocked" }.map(\.name))
    }

    /// The island's (urgency-sorted) sessions as the Worker takes them: stripped,
    /// cut to 64 code points, deduped by name, empty names dropped, at most 20 (the most
    /// urgent), then sorted by name (#766 J6c): the island reorders by activity, and the
    /// Worker sorts by itself, so a reorder must not look like a change.
    nonisolated static func wire(_ sessions: [AgentSession]) -> [Session] {
        var seen = Set<String>(), out: [Session] = []
        for s in sessions where out.count < maxSessions {
            let name = clean(s.name)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            let alias = clean(s.alias)
            out.append(Session(name: name, alias: alias.isEmpty ? nil : alias, state: s.state.wireName,
                               agents: s.agents > 0 ? min(s.agents, 999) : nil))
        }
        return out.sorted { $0.name < $1.name }
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
