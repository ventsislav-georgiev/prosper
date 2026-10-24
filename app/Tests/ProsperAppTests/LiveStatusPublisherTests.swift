import AppKit
import XCTest
@testable import ProsperApp

/// #523: Live status on iPhone. A fake clock, fake timers and a fake transport:
/// no network, no real sleep notification, no real credentials.
@MainActor
final class LiveStatusPublisherTests: XCTestCase {

    /// Drives one publisher: `clock` is wall time, `advance` fires due timers in order.
    @MainActor private final class Rig {
        struct Post { let json: String; let bearer: String; let waited: Bool }
        let p = LiveStatusPublisher()
        let center = NotificationCenter()
        var clock: TimeInterval = 1_800_000_000
        var timers: [(due: TimeInterval, id: Int, fire: @MainActor () -> Void)] = []
        var cancelled: Set<Int> = []
        var nextID = 0
        var posts: [Post] = []
        var reply: Int? = 204
        var bearer: String? = "tok"
        var activated = true
        var enabled = true

        init() {
            p.now = { [unowned self] in Date(timeIntervalSince1970: self.clock) }
            p.after = { [unowned self] delay, fire in
                let id = self.nextID
                self.nextID += 1
                self.timers.append((self.clock + delay, id, fire))
                return { [unowned self] in self.cancelled.insert(id) }
            }
            p.post = { [unowned self] body, bearer, done in
                self.posts.append(Post(json: String(decoding: body, as: UTF8.self), bearer: bearer, waited: false))
                done(self.reply)
            }
            p.postAndWait = { [unowned self] body, bearer in
                self.posts.append(Post(json: String(decoding: body, as: UTF8.self), bearer: bearer, waited: true))
            }
            p.bearer = { [unowned self] in self.bearer }
            p.isActivated = { [unowned self] in self.activated }
            p.enabled = { [unowned self] in self.enabled }
            p.macID = { "mac1" }
            p.center = center
            p.start()
        }

        func advance(_ dt: TimeInterval) {
            let end = clock + dt
            while let next = timers.filter({ !cancelled.contains($0.id) && $0.due <= end })
                .min(by: { $0.due < $1.due || ($0.due == $1.due && $0.id < $1.id) }) {
                clock = next.due
                cancelled.insert(next.id)
                next.fire()
            }
            clock = end
        }

        var last: [String: Any] { Self.parse(posts.last!.json) }
        static func parse(_ json: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        }
        var names: [String] { (last["sessions"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
        var isOffline: Bool { last["offline"] as? Bool == true }
    }

    private func s(_ name: String, _ state: AgentState = .idle, alias: String = "", agents: Int = 0) -> AgentSession {
        AgentSession(key: AgentSessionKey(dir: "/d", name: name), alias: alias, activity: 0, state: state, agents: agents)
    }

    private let ms: Int64 = 1_800_000_000_000

    // MARK: - Body

    func testFirstListPostsAtOnceAsExactJSON() {
        let r = Rig()
        r.p.sessionsChanged([s("a", .working, alias: "Fix it", agents: 2), s("b")])
        XCTAssertEqual(r.posts.count, 1)
        XCTAssertEqual(r.posts[0].json,
            #"{"mac_id":"mac1","seq":\#(ms),"sessions":[{"agents":2,"alias":"Fix it","name":"a","state":"working"},{"name":"b","state":"idle"}]}"#)
        XCTAssertEqual(r.posts[0].bearer, "tok")
        XCTAssertFalse(r.posts[0].waited)
    }

    func testOfflineBodyIsExactJSON() {
        let r = Rig()
        r.p.sessionsChanged([s("a")])
        r.clock += 5
        r.enabled = false
        r.p.refresh()
        XCTAssertEqual(r.posts.count, 2)
        XCTAssertEqual(r.posts[1].json, #"{"mac_id":"mac1","offline":true,"seq":\#(ms + 5000)}"#)
    }

    func testEmptyListIsSentAsAnEmptyArray() {
        let r = Rig()
        r.p.sessionsChanged([])
        XCTAssertEqual(r.posts.map(\.json), [#"{"mac_id":"mac1","seq":\#(ms),"sessions":[]}"#])
    }

    // MARK: - Debounce and heartbeat

    func testChangesCoalesceOverTwoSeconds() {
        let r = Rig()
        r.p.sessionsChanged([s("a")])
        XCTAssertEqual(r.posts.count, 1)
        r.p.sessionsChanged([s("a", .working)])
        r.advance(1)
        r.p.sessionsChanged([s("a", .blocked)])
        r.advance(0.9)
        XCTAssertEqual(r.posts.count, 1, "nothing inside the 2 s window")
        r.advance(0.1)
        XCTAssertEqual(r.posts.count, 2, "one post for both changes")
        XCTAssertEqual((r.last["sessions"] as? [[String: Any]])?.first?["state"] as? String, "blocked")
        r.advance(10)
        XCTAssertEqual(r.posts.count, 2)
    }

    func testAnActivityOnlyTickPostsNothing() {
        let r = Rig()
        r.p.sessionsChanged([s("a")])
        var moved = s("a")
        moved.activity = 99
        r.p.sessionsChanged([moved])
        r.advance(5)
        XCTAssertEqual(r.posts.count, 1)
    }

    func testHeartbeatSendsTheFullListSixtySecondsAfterTheLastPost() {
        let r = Rig()
        r.p.sessionsChanged([s("a"), s("b")])
        r.advance(59)
        XCTAssertEqual(r.posts.count, 1)
        r.advance(1)
        XCTAssertEqual(r.posts.count, 2)
        XCTAssertEqual(r.names, ["a", "b"], "a heartbeat is the full list, never a bare one")
        r.advance(30)
        r.p.sessionsChanged([s("a", .working), s("b")])
        r.advance(2)
        XCTAssertEqual(r.posts.count, 3, "the change at 90 s posts at 92 s")
        r.advance(59)
        XCTAssertEqual(r.posts.count, 3, "the heartbeat restarted at the change post")
        r.advance(1)
        XCTAssertEqual(r.posts.count, 4)
        r.advance(60)
        XCTAssertEqual(r.posts.count, 5)
    }

    // MARK: - Offline events

    func testSleepPostsOfflineWaitedOnAndWakeSendsTheListAtOnce() {
        let r = Rig()
        r.p.sessionsChanged([s("a")])
        r.center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(r.posts.count, 2)
        XCTAssertTrue(r.isOffline)
        XCTAssertTrue(r.posts[1].waited, "sleep waits for the post")
        r.p.sessionsChanged([s("a"), s("b")])
        r.advance(300)
        XCTAssertEqual(r.posts.count, 2, "no change post and no heartbeat while asleep")
        r.center.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(r.posts.count, 3, "wake posts at once")
        XCTAssertEqual(r.names, ["a", "b"])
        r.advance(60)
        XCTAssertEqual(r.posts.count, 4, "and the heartbeat is back")
    }

    func testQuitPostsOfflineWaitedOnAndThenNothing() {
        let r = Rig()
        r.p.sessionsChanged([s("a")])
        r.p.pause()   // applicationWillTerminate
        XCTAssertEqual(r.posts.count, 2)
        XCTAssertTrue(r.isOffline)
        XCTAssertTrue(r.posts[1].waited)
        r.p.sessionsChanged([s("b")])
        r.advance(300)
        XCTAssertEqual(r.posts.count, 2)
    }

    func testSignOutHandsBackTheOfflineBodyAndGoesQuiet() throws {
        let r = Rig()
        r.p.sessionsChanged([s("a")])
        r.clock += 1
        let body = try XCTUnwrap(r.p.signOut())
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"mac_id":"mac1","offline":true,"seq":\#(ms + 1000)}"#)
        XCTAssertEqual(r.posts.count, 1, "SupporterClient sends it, ahead of the revoke")
        r.bearer = nil
        r.activated = false
        r.p.sessionsChanged([s("b")])
        r.p.refresh()
        r.advance(300)
        XCTAssertEqual(r.posts.count, 1)
        XCTAssertNil(r.p.signOut(), "nothing live, nothing to send")
    }

    func testToggleOffPostsOfflineAndStopsThenOnPostsTheList() {
        let r = Rig()
        r.p.sessionsChanged([s("a")])
        r.enabled = false
        r.p.refresh()
        XCTAssertEqual(r.posts.count, 2)
        XCTAssertTrue(r.isOffline)
        XCTAssertFalse(r.posts[1].waited)
        r.p.sessionsChanged([s("b")])
        r.advance(300)
        XCTAssertEqual(r.posts.count, 2)
        r.enabled = true
        r.p.refresh()
        XCTAssertEqual(r.posts.count, 3)
        XCTAssertEqual(r.names, ["b"])
    }

    func testIslandStoppingPostsOffline() {
        let r = Rig()
        r.p.sessionsChanged([s("a")])
        r.p.sessionsChanged(nil)
        XCTAssertEqual(r.posts.count, 2)
        XCTAssertTrue(r.isOffline)
        r.advance(300)
        XCTAssertEqual(r.posts.count, 2)
    }

    // MARK: - Gates

    func testNothingPostsWhileSignedOutNotActivatedOrToggledOff() {
        for gate in ["signed out", "not activated", "toggled off"] {
            let r = Rig()
            switch gate {
            case "signed out": r.bearer = nil
            case "not activated": r.activated = false
            default: r.enabled = false
            }
            r.p.sessionsChanged([s("a")])
            r.p.sessionsChanged([s("b")])
            r.advance(300)
            r.p.pause()
            r.p.didWake()
            _ = r.p.signOut()
            r.p.refresh()
            XCTAssertEqual(r.posts.count, 0, gate)
            r.bearer = "tok"; r.activated = true; r.enabled = true
            r.p.refresh()
            XCTAssertEqual(r.posts.count, 1, "\(gate): the gate opening posts the list")
            XCTAssertEqual(r.names, ["b"], gate)
        }
    }

    func testNothingPostsBeforeTheIslandSpeaks() {
        let r = Rig()
        r.p.refresh()
        r.p.didWake()
        r.advance(300)
        XCTAssertEqual(r.posts.count, 0)
    }

    // MARK: - Caps, dedupe, stripping

    func testCapsAtTwentyKeepingTheIslandOrder() {
        let r = Rig()
        r.p.sessionsChanged((0..<25).map { s("s\($0)") })
        XCTAssertEqual(r.names, (0..<20).map { "s\($0)" })
    }

    func testNamesAndAliasesCutToSixtyFourScalars() {
        let long = String(repeating: "x", count: 70)
        let wire = LiveStatusPublisher.wire([s(long, alias: long)])
        XCTAssertEqual(wire.first?.name.unicodeScalars.count, 64)
        XCTAssertEqual(wire.first?.alias?.unicodeScalars.count, 64)
        // 👨‍👩‍👧 is 5 scalars in one Character: the cut counts scalars like the Worker does.
        let family = String(repeating: "👨‍👩‍👧", count: 20)
        let cut = LiveStatusPublisher.clean(family)
        XCTAssertEqual(cut.unicodeScalars.count, 64)
        XCTAssertEqual(Array(cut.unicodeScalars), Array(family.unicodeScalars.prefix(64)), "a scalar prefix, mid-grapheme allowed")
        XCTAssertEqual(LiveStatusPublisher.clean(String(repeating: "é", count: 64)).count, 64)
    }

    func testDedupesByNameAfterStrippingAndCutting() {
        let long = String(repeating: "n", count: 64)
        let wire = LiveStatusPublisher.wire([
            s("a", .blocked), s("a", .idle), s("a\u{7}", .working),
            s(long + "1"), s(long + "2"),
        ])
        XCTAssertEqual(wire.map(\.name), ["a", long])
        XCTAssertEqual(wire.first?.state, "blocked", "the first (most urgent) one wins")
    }

    func testStripsControlBidiSeparatorAndBOMCharacters() {
        let stripped: [UInt32] = [0x00, 0x09, 0x0A, 0x1B, 0x1F, 0x7F, 0x80, 0x85, 0x9F,
                                  0x200E, 0x200F, 0x202A, 0x202C, 0x202E, 0x2066, 0x2068, 0x2069,
                                  0x2028, 0x2029, 0xFEFF,
                                  // every Cf the Worker's CTRL_RE rejects, not only the bidi ones
                                  0xAD, 0x61C, 0x200B, 0x200C, 0x2060, 0x206A, 0xFFF9, 0xE0001]
        for v in stripped {
            let c = String(Character(Unicode.Scalar(v)!))
            XCTAssertEqual(LiveStatusPublisher.clean("a\(c)b"), "ab", String(v, radix: 16))
        }
        let kept: [UInt32] = [0x20, 0x7E, 0xA0, 0x200D, 0x2027, 0x202F, 0xFEFE]
        for v in kept {
            let c = String(Character(Unicode.Scalar(v)!))
            XCTAssertEqual(LiveStatusPublisher.clean("a\(c)b"), "a\(c)b", String(v, radix: 16))
        }
        // A subdivision flag (U+1F3F4, tag characters, U+E007F cancel tag) survives whole.
        let flag = String(String.UnicodeScalarView([0x1F3F4, 0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F]
            .map { Unicode.Scalar($0)! }))
        XCTAssertEqual(Array(LiveStatusPublisher.clean("x" + flag).unicodeScalars), Array(("x" + flag).unicodeScalars))
        let r = Rig()
        r.p.sessionsChanged([s("evil\u{202E}txt.exe\u{2066}x", alias: "\u{2066}\u{202E}"), s("\u{1B}\u{7}")])
        XCTAssertEqual(r.posts.last?.json,
            #"{"mac_id":"mac1","seq":\#(ms),"sessions":[{"name":"eviltxt.exex","state":"idle"}]}"#,
            "a stripped-empty alias is omitted, a stripped-empty name dropped")
    }

    /// The Worker answers 413 over 32 KB: the worst case (20 sessions, 64 four-byte
    /// scalars or 64 escaped quotes per name and alias, 999 agents) stays well under.
    func testWorstCaseBodyStaysUnder32KB() {
        let r = Rig()
        r.p.sessionsChanged((0..<20).map { i in
            let wide = String(repeating: "\u{1F600}", count: 63) + "\(i % 10)"
            let quotes = String(repeating: "\"", count: 63) + "\(i % 10)"
            return s(i < 10 ? wide : quotes , .blocked, alias: i < 10 ? quotes : wide, agents: 999)
        })
        XCTAssertEqual(r.names.count, 20)
        let bytes = r.posts.last!.json.utf8.count
        XCTAssertLessThan(bytes, 32 * 1024)
        XCTAssertGreaterThan(bytes, 8_000, "the worst case really is wide (8.7 KB today)")
    }

    func testUnknownStateIsIdleAndAgentsAreBounded() {
        let wire = LiveStatusPublisher.wire([
            AgentSession(key: AgentSessionKey(dir: "/d", name: "a"), alias: "", activity: 0,
                         state: AgentState(dch: "thinking"), agents: 5000),
            s("b", .done, agents: 0),
        ])
        XCTAssertEqual(wire, [.init(name: "a", alias: nil, state: "idle", agents: 999),
                              .init(name: "b", alias: nil, state: "done", agents: nil)])
    }

    // MARK: - seq

    func testSeqIsStrictlyIncreasingAndTracksTheClock() {
        let r = Rig()
        r.p.sessionsChanged([s("a")])
        r.enabled = false; r.p.refresh()
        r.enabled = true; r.p.refresh()
        r.clock -= 3600   // the wall clock steps back
        r.enabled = false; r.p.refresh()
        let seqs = r.posts.map { Rig.parse($0.json)["seq"] as? Int64 }
        XCTAssertEqual(seqs, [ms, ms + 1, ms + 2, ms + 3])
        r.clock += 7200
        r.enabled = true; r.p.refresh()
        XCTAssertEqual(r.last["seq"] as? Int64, ms + 3_600_000, "back on the wall clock, never ahead of it")
    }

    // MARK: - Responses

    func testBackoffOn429And5xx400AndNetworkError() {
        for code in [429, 500, 503, 400, 413, nil] as [Int?] {
            let r = Rig()
            r.reply = code
            r.p.sessionsChanged([s("a")])
            r.advance(59)
            XCTAssertEqual(r.posts.count, 1, "\(String(describing: code)): no retry of its own")
            r.advance(1)
            XCTAssertEqual(r.posts.count, 2, "\(String(describing: code)): the heartbeat retries")
            XCTAssertEqual(r.names, ["a"])
            r.p.sessionsChanged([s("a"), s("b")])
            r.advance(2)
            XCTAssertEqual(r.posts.count, 3, "\(String(describing: code)): so does the next change")
            XCTAssertEqual(r.names, ["a", "b"])
        }
    }

    func testStopsOn401And403UntilTheNextActivation() {
        for code in [401, 403] {
            let r = Rig()
            r.reply = code
            r.p.sessionsChanged([s("a")])
            XCTAssertTrue(r.p.halted)
            r.p.sessionsChanged([s("b")])
            r.advance(300)
            r.p.pause(); r.p.didWake()
            r.enabled = false; r.p.refresh()
            r.enabled = true; r.p.refresh()
            XCTAssertEqual(r.posts.count, 1, "\(code): nothing at all, offline included")
            r.reply = 204
            r.p.deviceActivated()
            XCTAssertEqual(r.posts.count, 2, "\(code): activation posts the list")
            XCTAssertEqual(r.names, ["b"])
        }
    }

    func testSignOutLiftsTheStopForTheNextSignIn() {
        let r = Rig()
        r.reply = 403
        r.p.sessionsChanged([s("a")])
        XCTAssertNil(r.p.signOut())
        XCTAssertFalse(r.p.halted)
    }

    // MARK: - Setting, real queue

    func testSettingDefaultsOn() {
        let key = "liveStatusEnabled"
        let saved = Preferences.defaults.object(forKey: key)
        defer { Preferences.defaults.set(saved, forKey: key) }
        Preferences.defaults.removeObject(forKey: key)
        XCTAssertTrue(Preferences.liveStatusEnabled)
        Preferences.liveStatusEnabled = false
        XCTAssertFalse(Preferences.liveStatusEnabled)
    }

    /// The island's poll timer ticks on its utility queue; the list must reach
    /// onSessions on main (Swift 6 traps a main-inferred closure called off main).
    func testIslandTickReachesOnSessionsOnMainAndTeardownSendsNil() {
        let c = AgentIslandController()
        c.showsPanel = false
        c.center = NotificationCenter()
        c.touchFonts = {}
        c.currentGeometry = {
            AgentIslandGeometry.make(
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                topLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32), topRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32),
                safeTop: 32)
        }
        c.makePoller = { AgentIslandPoller(dirs: { [] }, list: { _, _ in [] }) }
        var got: [[AgentSession]?] = []
        var onMain: [Bool] = []
        let ticked = expectation(description: "list")
        c.onSessions = { list in
            got.append(list)
            onMain.append(Thread.isMainThread)
            if got.count == 1 { ticked.fulfill() }
        }
        addTeardownBlock { @MainActor in c.extLive = false; c.reload() }
        c.extLive = true
        c.reload()
        wait(for: [ticked], timeout: 5)
        c.extLive = false
        c.reload()
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got.first??.count, 0)
        XCTAssertNil(got.last!)
        XCTAssertEqual(onMain, [true, true])
    }
}
