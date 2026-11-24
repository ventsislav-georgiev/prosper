import AppKit
import XCTest
@testable import ProsperApp

/// #1569 (X7 c, spec 5.1 exception, 5.6, v2.1 7.3): extension spans on the grid, the handler call and its card. The marks
/// and the caps are pure; the requests run against a fake lane (XrayExtensionCalls.call); the Lua rows load a literal
/// fixture (or the shipped example) into a registry under a tempDir(), trusted, and run it in-process. No dch, no window.
@MainActor
final class XrayExtensionCardTests: XCTestCase {
    static func rule(_ template: String, id: String = "acme", handler: String? = "card",
                     ext: String = "com.example.kit") throws -> XrayExtensionRule {
        XrayExtensionRule(extensionID: ext, id: id, template: template, label: "Acme ticket", inCode: .never, handler: handler,
                          timeout: 3, pieces: try XrayExtensionRefs.pieces(template))
    }

    static func match(_ rule: XrayExtensionRule, _ text: String) throws -> XrayExtensionRefs.Match {
        try XCTUnwrap(XrayExtensionRefs.matches(of: rule, in: text).first)
    }

    // MARK: - Marks

    /// Red if a key with one span is marked, a rule with no handler marks anything, or two spans of a handler rule are
    /// not marked (XrayGridMarksView.extMarks).
    func testOneSpanNoMarkTwoSpansMarkNoHandlerNoMark() throws {
        let r = try Self.rule("ACME-{n}")
        XCTAssertTrue(XrayGridMarksView.extMarks(["see ACME-1 here", "ACME-2"], [r], rows: 24, taken: []).isEmpty)
        let two = XrayGridMarksView.extMarks(["see ACME-1 here", "and ACME-1"], [r], rows: 24, taken: [])
        XCTAssertEqual(two.map(\.mark), [.init(row: 0, col: 4, cells: 6, key: "xref:com.example.kit/acme:ACME-1"),
                                         .init(row: 1, col: 4, cells: 6, key: "xref:com.example.kit/acme:ACME-1")])
        XCTAssertEqual(two.last?.match.parts, ["1"])
        let none = try Self.rule("ACME-{n}", handler: nil)
        XCTAssertTrue(XrayGridMarksView.extMarks(["ACME-1 and ACME-1"], [none], rows: 24, taken: []).isEmpty)
        XCTAssertTrue(XrayGridMarksView.extMarks(["ACME-1 and ACME-1"], [r], rows: 0, taken: []).isEmpty)
        // only the first `rows` lines count
        XCTAssertTrue(XrayGridMarksView.extMarks(["ACME-1", "ACME-1"], [r], rows: 1, taken: []).isEmpty)
    }

    /// Overlap: a span over a dch mark is dropped, and so is a later rule's span over an earlier rule's (first rule wins).
    /// Red if extMarks ignores `taken` or the spans kept so far.
    func testOverlapsGoToTheDchMarkThenTheFirstRule() throws {
        let a = try Self.rule("ACME-{n}"), b = try Self.rule("{KEY}-{n}", id: "key")
        let both = XrayGridMarksView.extMarks(["ACME-1 x ACME-1"], [a, b], rows: 24, taken: [])
        XCTAssertEqual(Set(both.map(\.mark.key)), ["xref:com.example.kit/acme:ACME-1"])
        XCTAssertEqual(both.count, 2)
        let dch = XrayGridMarksView.Mark(row: 0, col: 0, cells: 6, key: "issue:#1")
        let left = XrayGridMarksView.extMarks(["ACME-1 x ACME-1"], [a, b], rows: 24, taken: [dch])
        XCTAssertTrue(left.isEmpty)   // one ACME-1 left: no mark; b's span overlaps nothing kept but is alone too
    }

    // MARK: - Caps

    /// Red if a cap goes (title 120, subtitle 200, body 8 KB, 4 actions), an outside string skips OutsideText, an action
    /// other than an http(s) url or a copy is kept, or an over-long answer is parsed.
    func testCaps() throws {
        let actions = (0..<6).map { ["label": "Open \($0)", "url": "https://example.com/acme/\($0)"] }
            + [["label": "Run", "url": "file:///etc/passwd"], ["label": "Shell", "run": "x"]]
        let o: [String: Any] = ["title": String(repeating: "t", count: 300) + "\u{202E}", "subtitle": String(repeating: "s", count: 300),
                                "body": String(repeating: "bbbbbbbb\u{0007}\n", count: 1500), "actions": actions]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
        // the body is past 8 KB once cleaned, the answer under resultBytes (a JSON "\u0007" is 6 bytes): else it is refused unread
        XCTAssertLessThan(raw.utf8.count, XrayExtensionRefs.resultBytes)
        guard case .card(let c) = XrayExtensionRefs.outcome(raw) else { return XCTFail("no card") }
        XCTAssertEqual(c.title, String(repeating: "t", count: 119) + "\u{2026}")   // OutsideText.shown's cap: max - 1 and an ellipsis
        XCTAssertEqual(c.subtitle.count, 200)
        XCTAssertLessThanOrEqual(c.body.utf8.count, 8 * 1024)
        XCTAssertFalse(c.body.contains("\u{0007}"))
        XCTAssertEqual(c.actions.map(\.label), ["Open 0", "Open 1", "Open 2", "Open 3"])
        XCTAssertEqual(c.actions.first?.url?.absoluteString, "https://example.com/acme/0")
        let bad = #"{"actions":[{"label":"Run","url":"file:///etc/passwd"},{"label":"Copy id","copy":"ACME-1"}]}"#
        guard case .card(let d) = XrayExtensionRefs.outcome(bad) else { return XCTFail("no card") }
        XCTAssertEqual(d.actions, [.init(label: "Copy id", url: nil, copy: "ACME-1")])
        XCTAssertEqual(XrayExtensionRefs.outcome(nil), .nothing)
        XCTAssertEqual(XrayExtensionRefs.outcome("{}"), .nothing)
        XCTAssertEqual(XrayExtensionRefs.outcome(#"{"error":"no such ticket"}"#), .failed("no such ticket"))
        XCTAssertEqual(XrayExtensionRefs.outcome("not json"), .failed(XrayExtensionRefs.unreadable))
        let huge = #"{"title":""# + String(repeating: "x", count: 70 * 1024) + #""}"#
        XCTAssertEqual(XrayExtensionRefs.outcome(huge), .failed(XrayExtensionRefs.unreadable))
    }

    // MARK: - Requests

    @MainActor final class Lane {
        var args: [String] = []
        var lanes: [LaneCall] = []
        var waiting: [CheckedContinuation<String?, Never>] = []
        var answer: String? = #"{"title":"Login retries"}"#
        var hold = false
        var version = 1
        func call(_ rule: XrayExtensionRule, _ arg: String, _ lane: LaneCall) async -> String? {
            args.append(arg)
            lanes.append(lane)
            guard hold else { return answer }
            return await withCheckedContinuation { waiting.append($0) }
        }
        func release() {
            let w = waiting
            waiting = []
            for k in w { k.resume(returning: answer) }
        }
    }

    func calls(_ lane: Lane) -> XrayExtensionCalls {
        let c = XrayExtensionCalls()
        c.call = { await lane.call($0, $1, $2) }
        c.version = { lane.version }
        c.sleep = { _ in try? await Task.sleep(nanoseconds: 60_000_000_000) }   // the race cancels it
        return c
    }

    func until(_ ok: @escaping @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !ok(), Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    /// Red if a third request does not drop the oldest (its LaneCall dropped), the same request is not joined (one lane
    /// call, one task), or more than 2 run at once.
    func testTwoInFlightOldestDroppedSameJoined() async throws {
        let lane = Lane()
        lane.hold = true
        let c = calls(lane)
        let r = try Self.rule("ACME-{n}")
        let (m1, m2, m3) = (try Self.match(r, "ACME-1"), try Self.match(r, "ACME-2"), try Self.match(r, "ACME-3"))
        let t1 = c.outcome(m1, dir: nil, session: "api")
        let t2 = c.outcome(m2, dir: nil, session: "api")
        XCTAssertEqual(c.outcome(m1, dir: nil, session: "api"), t1)   // joined
        await until { lane.lanes.count == 2 }
        XCTAssertEqual(lane.lanes.count, 2)
        let t3 = c.outcome(m3, dir: nil, session: "api")
        XCTAssertEqual(c.flying.count, 2)
        XCTAssertEqual(lane.lanes.first?.isDropped, true)
        XCTAssertEqual(lane.lanes.last?.isDropped, false)
        await until { lane.lanes.count == 3 }
        lane.release()
        let o1 = await t1.value, o2 = await t2.value, o3 = await t3.value
        XCTAssertEqual(o1, .failed(XrayExtensionRefs.dropped))
        XCTAssertEqual(o2, .card(.init(title: "Login retries", subtitle: "", body: "", actions: [])))
        XCTAssertEqual(o3, o2)
        XCTAssertEqual(lane.args.count, 3)
        XCTAssertTrue(c.flying.isEmpty)
    }

    /// Red if an answer is not kept 60 s, a failure is kept past 10 s, or the LRU holds more than 256.
    func testKeptSixtySecondsFailedTenLRU256() async throws {
        let lane = Lane()
        let c = calls(lane)
        var clock = Date(timeIntervalSince1970: 1_000_000)
        c.now = { clock }
        let r = try Self.rule("ACME-{n}")
        let m = try Self.match(r, "ACME-1")
        _ = await c.outcome(m, dir: nil, session: "api").value
        clock += 59
        _ = await c.outcome(m, dir: nil, session: "api").value
        XCTAssertEqual(lane.args.count, 1)
        clock += 2
        _ = await c.outcome(m, dir: nil, session: "api").value
        XCTAssertEqual(lane.args.count, 2)
        lane.answer = #"{"error":"boom"}"#
        let f = try Self.match(r, "ACME-2")
        let boom = await c.outcome(f, dir: nil, session: "api").value
        XCTAssertEqual(boom, .failed("boom"))
        clock += 9
        _ = await c.outcome(f, dir: nil, session: "api").value
        XCTAssertEqual(lane.args.count, 3)
        clock += 2
        _ = await c.outcome(f, dir: nil, session: "api").value
        XCTAssertEqual(lane.args.count, 4)
        lane.answer = #"{"title":"x"}"#
        for n in 100..<400 { _ = await c.outcome(try Self.match(r, "ACME-\(n)"), dir: nil, session: "api").value }
        XCTAssertEqual(c.keptCount, 256)
        let before = lane.args.count
        _ = await c.outcome(try Self.match(r, "ACME-100"), dir: nil, session: "api").value   // evicted: asked again
        XCTAssertEqual(lane.args.count, before + 1)
        _ = await c.outcome(try Self.match(r, "ACME-399"), dir: nil, session: "api").value   // kept
        XCTAssertEqual(lane.args.count, before + 1)
    }

    /// Red if a reload (rulesVersion moved) while the call ran shows the answer instead of "unavailable".
    func testReloadMidRequestShowsUnavailable() async throws {
        let lane = Lane()
        lane.hold = true
        let c = calls(lane)
        let card = XrayExtensionCard(try Self.match(try Self.rule("ACME-{n}"), "ACME-1"), calls: c, dir: nil, session: "api")
        XCTAssertEqual(card.note, "Reading\u{2026}")
        await until { lane.waiting.count == 1 }
        lane.version = 2
        lane.release()
        await card.task?.value
        XCTAssertEqual(card.outcome, .unavailable)
        XCTAssertTrue(card.note?.contains("unavailable") == true)
        XCTAssertTrue(XrayExtensionCard(try Self.match(try Self.rule("ACME-{n}"), "ACME-1"), calls: nil, dir: nil,
                                        session: nil).outcome == .unavailable)
    }

    /// Red if the rule's timeout does not fail the card and drop the lane call.
    func testTimeoutFailsTheCardAndDropsTheCall() async throws {
        let lane = Lane()
        lane.hold = true
        let c = calls(lane)
        c.sleep = { _ in }
        let o = await c.outcome(try Self.match(try Self.rule("ACME-{n}"), "ACME-1"), dir: nil, session: "api").value
        XCTAssertEqual(o, .failed(XrayExtensionRefs.timedOut))
        XCTAssertEqual(lane.lanes.last?.isDropped, true)
        lane.release()
    }

    /// Red if a dropped call does not cancel the host wait it is in (ExtensionHost.awaitSync: process.run's group kill
    /// goes through that task's cancel), or a call dropped before its wait is not cancelled at once.
    func testDropCancelsTheHostWait() async {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var value: Bool??
            func set(_ v: Bool?) { lock.withLock { value = .some(v) } }
            func get() -> Bool?? { lock.withLock { value } }
        }
        for early in [false, true] {
            let lane = LaneCall(), box = Box()
            if early { lane.drop() }
            DispatchQueue.global().async {
                let r = LaneCall.with(lane) {
                    ExtensionHost.awaitSync(timeout: 20) { () async -> Bool in (try? await Task.sleep(nanoseconds: 20_000_000_000)) == nil }
                }
                box.set(r)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            let start = Date()
            lane.drop()
            while box.get() == nil, Date().timeIntervalSince(start) < 5 { try? await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(box.get() == .some(.some(true)), "early \(early)")
        }
    }

    // MARK: - Lua

    func registry(_ id: String, toml: String, lua: String) throws -> ExtensionRegistry {
        let root = tempDir("xref-card")
        let user = root.appendingPathComponent("user", isDirectory: true)
        let dir = user.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("system"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try toml.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try lua.write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        return try registry(user: user, root: root, trusted: [id])
    }

    func registry(user: URL, root: URL, trusted: [String]) throws -> ExtensionRegistry {
        let defaults = scratchDefaults("xref-card")
        defaults.set(trusted, forKey: "trustedExtensionIDs")
        let reg = ExtensionRegistry(systemDir: root.appendingPathComponent("system", isDirectory: true), userDir: user,
                                    hostVersion: "2.0.0", defaults: defaults, services: LaunchRecordingServices())
        reg.discover()
        return reg
    }

    static let loopToml = """
        [extension]
        id = "com.example.kit.loop"
        name = "fixture"
        title = "Fixture"
        description = "xref handler fixture"
        version = "1.0.0"
        author = "Example"

        [extension.host]
        min_version = "2.0.0"
        api_level = 1

        [extension.entry]
        main = "init.lua"

        [[contributes.xrefs]]
        id = "spin"
        template = "SPIN-{n}"
        handler = "spin"

        [[contributes.xrefs]]
        id = "good"
        template = "GOOD-{n}"
        handler = "good"
        """

    static let loopLua = """
        function spin(a) while true do end end
        function good(a) return { title = "ok " .. a.text } end
        """

    /// Red if a Lua infinite loop hangs the card (no budget on the lane call), its failure reads as "nothing", or the
    /// lane does not serve the next call after it.
    func testLuaInfiniteLoopFailsTheCardAndTheLaneServesTheNext() async throws {
        let reg = try registry("com.example.kit.loop", toml: Self.loopToml, lua: Self.loopLua)
        XCTAssertEqual(reg.xrefRules.map(\.id), ["spin", "good"])
        let c = XrayExtensionCalls()
        c.call = { await reg.callXref($0, arg: $1, call: $2) }
        c.version = { reg.rulesVersion }
        let spin = try XCTUnwrap(reg.xrefRules.first), good = try XCTUnwrap(reg.xrefRules.last)
        let failed = await c.outcome(try Self.match(spin, "SPIN-1"), dir: nil, session: "api").value
        guard case .failed(let why) = failed else { return XCTFail("\(failed)") }
        XCTAssertTrue(why.hasPrefix("The extension failed"), why)
        let ok = await c.outcome(try Self.match(good, "GOOD-1"), dir: nil, session: "api").value
        XCTAssertEqual(ok, .card(.init(title: "ok GOOD-1", subtitle: "", body: "", actions: [])))
    }

    static let tableToml = loopToml.replacingOccurrences(of: "com.example.kit.loop", with: "com.example.kit.table")
        .replacingOccurrences(of: "SPIN-{n}", with: "ECHO-{n}").replacingOccurrences(of: "\"spin\"", with: "\"echo\"")
        .replacingOccurrences(of: "GOOD-{n}", with: "WORD-{n}").replacingOccurrences(of: "\"good\"", with: "\"word\"")

    static let tableLua = """
        function echo(arg)
          return { title = arg.text, subtitle = arg.parts[1] .. "|" .. arg.session .. "|" .. arg.dir,
                   actions = { { label = "Copy id", copy = arg.text } } }
        end
        function word(arg) return "a string, not a table" end
        """

    /// Review r1 (the public contract): the handler reads `arg.text` and the rest straight off a table and returns a
    /// table; a non-table answer fails the card. Red if the host passes the JSON string (arg.text is nil: the concat
    /// throws) or wants a string back.
    func testHandlerTakesATableAndReturnsATable() async throws {
        let reg = try registry("com.example.kit.table", toml: Self.tableToml, lua: Self.tableLua)
        XCTAssertEqual(reg.xrefRules.map(\.id), ["echo", "word"])
        let echo = try XCTUnwrap(reg.xrefRules.first), word = try XCTUnwrap(reg.xrefRules.last)
        let m = try Self.match(echo, "ECHO-7")
        let lane = LaneCall()
        let raw = await reg.callXref(echo, arg: XrayExtensionRefs.arg(m, dir: "/Users/example/api", session: "api"), call: lane)
        XCTAssertTrue(lane.failed == nil, lane.failed ?? "")
        XCTAssertEqual(XrayExtensionRefs.outcome(raw), .card(.init(title: "ECHO-7", subtitle: "7|api|/Users/example/api", body: "",
                                                                   actions: [.init(label: "Copy id", url: nil, copy: "ECHO-7")])))
        let bad = LaneCall()
        let none = await reg.callXref(word, arg: XrayExtensionRefs.arg(try Self.match(word, "WORD-1"), dir: nil, session: "api"), call: bad)
        XCTAssertTrue(none == nil)
        XCTAssertTrue(bad.failed?.contains("not a table") == true, bad.failed ?? "nil")
    }

    /// Red if the example extension does not load (manifest, rule, handler) or its card is not the fake ticket.
    func testTheExampleLoads() async throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Examples/extensions/xref-example", isDirectory: true)
        let root = tempDir("xref-example")
        let user = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("system"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: user.appendingPathComponent("com.example.xref-example"))
        let reg = try registry(user: user, root: root, trusted: ["com.example.xref-example"])
        XCTAssertEqual(reg.record(id: "com.example.xref-example")?.isLive, true)
        XCTAssertEqual(reg.xrefRules.map(\.id), ["acme-ticket"])
        let rule = try XCTUnwrap(reg.xrefRules.first)
        let marks = XrayGridMarksView.extMarks(["see ACME-12", "ACME-12 again"], [rule], rows: 24, taken: [])
        XCTAssertEqual(marks.count, 2)
        let m = try XCTUnwrap(marks.first?.match)
        let raw = await reg.callXref(rule, arg: XrayExtensionRefs.arg(m, dir: "/Users/example/api", session: "api"), call: LaneCall())
        guard case .card(let c) = XrayExtensionRefs.outcome(raw) else { return XCTFail("no card: \(raw ?? "nil")") }
        XCTAssertEqual(c.title, "Login retries")
        XCTAssertEqual(c.actions.map(\.label), ["Open", "Copy id"])
        XCTAssertEqual(c.actions.first?.url?.absoluteString, "https://example.com/acme/tickets/12")
        XCTAssertTrue(c.body.contains("session api"))
    }
}

/// #1569: the extension card through the grid's Command-click (XrayHoverTests' rig: a fake follow, a fake dch runner).
extension XrayHoverTests {
    /// The handler's argument is the match, the pane's dir and the session, and nothing of the screen or the transcript
    /// (mutant 5); the click spawns no dch and asks the lane once. Red if the arg carries more keys or other text, or an
    /// extension card runs a --ref read.
    func testExtensionCardArgHasNoTranscriptAndSpawnsNoDch() async throws {
        try await withSeams { fake in
            let r = try rig(fake)
            let lane = XrayExtensionCardTests.Lane()
            let calls = XrayExtensionCalls()
            calls.call = { await lane.call($0, $1, $2) }
            calls.version = { 1 }
            r.v.marks.hover.calls = { calls }
            let rule = try XrayExtensionCardTests.rule("API-{n}", id: "api")
            r.v.marks.rules = { [rule] }
            r.v.viewportText = { "$ git log\nfix #12 now, API-7 too\nsee #1 and API-7\n" }
            r.panel.cwd = { "/Users/example/api" }
            r.v.marks.place()
            let key = "xref:com.example.kit/api:API-7"
            XCTAssertEqual(r.v.marks.marks.filter { $0.key == key }.count, 2)
            XCTAssertEqual(r.v.marks.marks.filter { $0.key.hasPrefix("issue:") }.count, 2)
            open(r, key)
            XCTAssertEqual(r.cards.views.count, 1)
            XCTAssertTrue(r.v.marks.hover.model === r.panel)
            let end = Date().addingTimeInterval(5)
            while lane.args.isEmpty, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
            let arg = try XCTUnwrap(lane.args.last)
            let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(arg.utf8)) as? [String: Any])
            XCTAssertEqual(Set(o.keys), ["text", "parts", "dir", "session"])
            XCTAssertEqual(o["text"] as? String, "API-7")
            XCTAssertEqual(o["parts"] as? [String], ["7"])
            XCTAssertEqual(o["dir"] as? String, "/Users/example/api")
            XCTAssertEqual(o["session"] as? String, "api")
            for other in ["git log", "#12", "#1", "see", "fix"] { XCTAssertFalse(arg.contains(other), other) }
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(lane.args.count, 1)
            XCTAssertEqual(r.run.calls.count, 0)
            XCTAssertTrue(r.panels.refReading == nil)
        }
    }
}
