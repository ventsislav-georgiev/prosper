import AppKit
import XCTest
@testable import ProsperApp

/// #1561 (Phase H, X-R b): the warm `dch --xray host:name --requests --json` connection (XrayRequests.swift) through
/// a fake child with scripted NDJSON and a recorder cold run. A private XrayPanels and NotificationCenter; no dch, no
/// process, no window shown.
@MainActor
final class XrayRequestsTests: XCTestCase {
    static let remote = XrayTarget(name: "box:api", dir: nil)
    static let path = "/fake/dch"

    /// The fake `--requests` child: `start` is its first line (ready by default); each request line gets `reply`'s
    /// lines; a cancel of the running request gets the end line `cancel`; stdin EOF ends a running one the same way.
    final class Child: XrayRequestChild, @unchecked Sendable {
        private let lock = NSLock()
        private var queued: [Data] = []
        private var waiter: CheckedContinuation<Data?, Never>?
        private var ended = false, running: Int?
        private var _writes: [[String: Any]] = []
        private var _inputClosed = false, _terminated = false
        let reply: @Sendable (_ n: Int, _ argv: [String]) -> [String]

        init(start: String = #"{"schema":1,"ready":{"ops":["json","ref","chapter","clear"]}}"#,
             reply: @escaping @Sendable (_ n: Int, _ argv: [String]) -> [String]) {
            self.reply = reply
            push(start)
        }

        var writes: [[String: Any]] { lock.withLock { _writes } }
        var inputClosed: Bool { lock.withLock { _inputClosed } }
        var terminated: Bool { lock.withLock { _terminated } }

        func push(_ s: String) {
            lock.withLock {
                if let w = waiter { waiter = nil; w.resume(returning: Data(s.utf8)) } else { queued.append(Data(s.utf8)) }
            }
        }

        private func end() {
            lock.withLock {
                ended = true
                if let w = waiter { waiter = nil; w.resume(returning: nil) }
            }
        }

        private func cancelled(_ n: Int) {
            let was = lock.withLock { () -> Bool in
                guard running == n else { return false }
                running = nil
                return true
            }
            guard was else { return }   // dch writes nothing when N is not running
            push(#"{"req":\#(n),"exit":2,"why":"cancel"}"#)
        }

        func write(_ line: Data) {
            guard lock.withLock({ !_inputClosed }),
                  let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
            lock.withLock { _writes.append(o) }
            if let n = o["cancel"] as? Int { return cancelled(n) }
            guard let n = o["req"] as? Int, let argv = o["argv"] as? [String] else { return }
            let lines = reply(n, argv)
            lock.withLock { running = lines.contains { $0.contains(#""exit""#) } ? nil : n }
            lines.forEach(push)
        }

        func nextLine() async -> Data? {
            await withCheckedContinuation { c in
                lock.withLock {
                    if !queued.isEmpty { c.resume(returning: queued.removeFirst()) }
                    else if ended { c.resume(returning: nil) }
                    else { waiter = c }
                }
            }
        }

        func closeInput() {
            let n = lock.withLock { () -> Int? in _inputClosed = true; return running }
            if let n { cancelled(n) }
            end()
        }

        func terminate() { lock.withLock { _terminated = true }; end() }
    }

    /// The spawn seam's recorder: each argv, and the children it handed out (`make` builds the next).
    final class Spawns: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = [], _children: [Child] = []
        let make: @Sendable () -> Child
        init(_ make: @escaping @Sendable () -> Child) { self.make = make }
        var calls: [[String]] { lock.withLock { _calls } }
        var children: [Child] { lock.withLock { _children } }
        var spawn: XrayRequests.Spawn {
            { [self] _, args, _ in
                let c = make()
                lock.withLock { _calls.append(args); _children.append(c) }
                return c
            }
        }
    }

    /// The cold run (today's spawn): records each argv, answers `answer`.
    final class Cold: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        let answer: (status: Int32, out: Data) = (0, Data("cold\n".utf8))
        var calls: [[String]] { lock.withLock { _calls } }
        var run: XrayPanels.Run { { [self] _, args, _ in lock.withLock { _calls.append(args) }; return answer } }
    }

    /// Echo: each request answers one line naming its N and argv, then exit 0.
    nonisolated static let echo: @Sendable (Int, [String]) -> [String] = { n, argv in
        [#"{"req":\#(n),"line":{"n":\#(n),"form":"\#(argv.first ?? "")"}}"#, #"{"req":\#(n),"exit":0,"why":null}"#]
    }

    func until(_ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    func requests(_ spawns: Spawns) -> XrayRequests {
        let r = XrayRequests()
        r.spawn = spawns.spawn
        return r
    }

    /// Ready, then two sequential requests on one child: one spawn with dch's form, N 1 then 2, each argv the flags
    /// after `--xray <name>`, each answer the host's line (red with a dial per request, or argv sent whole).
    func testReadyThenTwoSequentialRequestsOnOneChild() async {
        let spawns = Spawns { Child(reply: XrayRequestsTests.echo) }, cold = Cold()
        let run = requests(spawns).run(for: Self.remote, cold: cold.run)
        let a = await run(Self.path, ["--xray", "box:api", "--json"], [:])
        let b = await run(Self.path, ["--xray", "box:api", "--chapter", "c7", "--json"], [:])
        XCTAssertEqual(spawns.calls, [["--xray", "box:api", "--requests", "--json"]])
        XCTAssertEqual(spawns.children.last?.writes.map { $0["req"] as? Int }, [1, 2])
        XCTAssertEqual(spawns.children.last?.writes.map { $0["argv"] as? [String] }, [["--json"], ["--chapter", "c7", "--json"]])
        XCTAssertEqual(a.status, 0)
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: a.out)) as? [String: AnyHashable], ["n": 1, "form": "--json"])
        XCTAssertEqual(b.status, 0)
        XCTAssertEqual((try? JSONSerialization.jsonObject(with: b.out)) as? [String: AnyHashable], ["n": 2, "form": "--chapter"])
        XCTAssertEqual(cold.calls, [])
    }

    /// The panel's own reads (XrayPanelModel.read wires the warm run): a remote --ref goes warm; --tasks and --memory,
    /// not request forms, stay cold (red with read() keeping the cold run, or with the form check gone).
    func testAPanelSendsItsRefWarmAndItsTasksCold() async {
        let spawns = Spawns { Child(reply: XrayRequestsTests.echo) }, cold = Cold(), panels = XrayPanels()
        panels.requests.spawn = spawns.spawn
        let p = XrayPanelModel(target: Self.remote, tab: .tasks)
        p.panels = panels
        p.read(dch: Self.path, run: cold.run)
        await p.reading?.value
        XCTAssertEqual(cold.calls.count, 2)
        XCTAssertEqual(Set(cold.calls.compactMap { $0.dropFirst(2).first }), ["--tasks", "--memory"])
        XCTAssertTrue(panels.runRef("#12", for: p))
        await panels.refReading?.value
        XCTAssertEqual(spawns.children.last?.writes.last?["argv"] as? [String], ["--ref", "#12", "--scope", "project", "--full", "--json"])
        XCTAssertEqual(cold.calls.count, 2, "the --ref never ran cold")
        p.stop()
    }

    /// A cancel writes {"cancel":N} and dch's end line `cancel` is a cancelled read (-1, nothing); the child stays
    /// for the next request (red with the cancel handler gone: the read waits for the 10 s watchdog).
    func testCancelWritesCancelNAndEndsTheRead() async {
        let spawns = Spawns { Child { n, argv in argv.first == "--ref" ? [] : XrayRequestsTests.echo(n, argv) } }
        let run = requests(spawns).run(for: Self.remote, cold: Cold().run)
        let t = Task { await run(Self.path, ["--xray", "box:api", "--ref", "#9", "--json"], [:]) }
        await until { spawns.children.last?.writes.count == 1 }
        let start = Date()
        t.cancel()
        let r = await t.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(r.status, -1)
        XCTAssertEqual(r.out, Data())
        XCTAssertEqual(spawns.children.last?.writes.last?["cancel"] as? Int, 1)
        let next = await run(Self.path, ["--xray", "box:api", "--json"], [:])
        XCTAssertEqual(next.status, 0)
        XCTAssertEqual(spawns.calls.count, 1, "the same child")
    }

    /// `lost` (exit 7) maps to 7, and the ref card says "host unreachable" (red with lost mapped to its exit 1 here).
    func testLostMapsToHostUnreachable() async {
        let spawns = Spawns { Child { n, _ in [#"{"req":\#(n),"stderr":"dch: box: lost"}"#, #"{"req":\#(n),"exit":1,"why":"lost"}"#] } }
        let panels = XrayPanels()
        panels.requests.spawn = spawns.spawn
        let p = XrayPanelModel(target: Self.remote, tab: .refs)
        p.panels = panels
        (p.dch, p.run) = (Self.path, panels.requests.run(for: Self.remote, cold: Cold().run))
        XCTAssertTrue(panels.runRef("#12", for: p))
        await panels.refReading?.value
        XCTAssertEqual(p.refNote, "host unreachable")
    }

    /// `busy` runs the request cold, whole argv (red with busy taken as exit 1: "no corpus" for a ref).
    func testBusyRunsTheRequestCold() async {
        let spawns = Spawns { Child { n, _ in [#"{"req":\#(n),"exit":1,"why":"busy"}"#] } }, cold = Cold()
        let run = requests(spawns).run(for: Self.remote, cold: cold.run)
        let r = await run(Self.path, ["--xray", "box:api", "--json"], [:])
        XCTAssertEqual(cold.calls, [["--xray", "box:api", "--json"]])
        XCTAssertEqual(r.out, Data("cold\n".utf8))
    }

    /// The end-line table (README v1.99.0:1303-1310): cap -> overCap, cancel and timeout -> -1, lost -> 7, busy ->
    /// cold (nil), refused keeps its exit, null keeps exit and output; Prosper's own byte cap -> overCap.
    func testEndLinesMapToTodaysStatuses() {
        let out = Data("x\n".utf8)
        func s(_ e: Int, _ w: String?, over: Bool = false) -> Int32? { XrayRequestLine.status(exit: e, why: w, over: over, out: out)?.status }
        XCTAssertEqual(s(2, "cap"), XrayPanels.overCap)
        XCTAssertEqual(s(0, nil, over: true), XrayPanels.overCap)
        XCTAssertEqual(s(2, "cancel"), -1)
        XCTAssertEqual(s(2, "timeout"), -1)
        XCTAssertEqual(s(1, "lost"), 7)
        XCTAssertTrue(s(1, "busy") == nil)
        XCTAssertEqual(s(4, "refused"), 4)
        XCTAssertEqual(s(6, "refused"), 6)
        XCTAssertTrue(s(2, "refused") == nil, "R1611-b: a local refusal runs cold; red without the refused-2 case (status 2)")
        XCTAssertEqual(s(2, nil), 2, "a plain exit 2 stays a failed read")
        XCTAssertEqual(XrayRequestLine.status(exit: 0, why: nil, over: false, out: out)?.out, out)
    }

    /// The window's close gives the child stdin EOF and drops the connections; a hide closes too, and the next request
    /// dials again (red with the observers gone).
    func testWindowCloseAndHideCloseStdin() async {
        let spawns = Spawns { Child(reply: XrayRequestsTests.echo) }, center = NotificationCenter()
        let r = requests(spawns)
        r.observe(center)
        let run = r.run(for: Self.remote, cold: Cold().run)
        _ = await run(Self.path, ["--xray", "box:api", "--json"], [:])
        let win = AgentsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: win)   // never shown: not visible
        await until { spawns.children.last?.inputClosed == true }
        XCTAssertEqual(spawns.children.last?.inputClosed, true, "hide: stdin EOF")
        XCTAssertEqual(r.lines.count, 1)
        _ = await run(Self.path, ["--xray", "box:api", "--json"], [:])
        XCTAssertEqual(spawns.calls.count, 2, "after a hide the next request dials again")
        center.post(name: NSWindow.willCloseNotification, object: win)
        await until { spawns.children.last?.inputClosed == true }
        XCTAssertEqual(spawns.children.last?.inputClosed, true, "close: stdin EOF")
        XCTAssertTrue(r.lines.isEmpty)
        center.post(name: NSWindow.willCloseNotification, object: NSObject())   // another object: nothing
    }

    /// A start failure (dch's `{"schema":1,"exit":7,...}` line) runs that request cold and records 7; the next request
    /// dials again (red with the ready check gone).
    func testAStartFailureFallsBackToTheColdSpawn() async {
        let spawns = Spawns { Child(start: #"{"schema":1,"exit":7,"stderr":"dch: box: unreachable"}"#, reply: XrayRequestsTests.echo) }
        let cold = Cold(), r = requests(spawns)
        let run = r.run(for: Self.remote, cold: cold.run)
        let a = await run(Self.path, ["--xray", "box:api", "--json"], [:])
        XCTAssertEqual(a.out, Data("cold\n".utf8))
        XCTAssertEqual(cold.calls, [["--xray", "box:api", "--json"]])
        let failures = await r.lines["box:api"]?.startFailures
        XCTAssertEqual(failures, [7])
        XCTAssertEqual(spawns.children.last?.writes.count, 0, "no request on a child that never was ready")
        XCTAssertEqual(spawns.children.last?.inputClosed, true)
        _ = await run(Self.path, ["--xray", "box:api", "--json"], [:])
        XCTAssertEqual(spawns.calls.count, 2)
    }

    /// A local target never uses it: the cold run, no spawn (red with the dir check gone).
    func testALocalTargetNeverUsesIt() async {
        let spawns = Spawns { Child(reply: XrayRequestsTests.echo) }, cold = Cold(), r = requests(spawns)
        let run = r.run(for: XrayTarget(name: "api", dir: "/tmp/dch-test"), cold: cold.run)
        _ = await run(Self.path, ["--xray", "api", "--json"], [:])
        XCTAssertEqual(spawns.calls, [])
        XCTAssertEqual(cold.calls, [["--xray", "api", "--json"]])
        XCTAssertTrue(r.lines.isEmpty)
    }

    /// Only dch's request forms go warm: --json alone, --ref, --chapter, --clear; --tasks, --memory, --search,
    /// --follow, another name or a short argv run cold (README v1.99.0:1287-1289).
    func testOnlyTheRequestFormsGoWarm() {
        func f(_ a: [String]) -> [String]? { XrayRequests.form(a, name: "box:api") }
        XCTAssertEqual(f(["--xray", "box:api", "--json"]), ["--json"])
        XCTAssertEqual(f(["--xray", "box:api", "--ref", "#1", "--json"]), ["--ref", "#1", "--json"])
        XCTAssertEqual(f(["--xray", "box:api", "--chapter", "c1", "--json"]), ["--chapter", "c1", "--json"])
        XCTAssertEqual(f(["--xray", "box:api", "--clear", "--json"]), ["--clear", "--json"])
        for a in [["--xray", "box:api", "--tasks", "--json"], ["--xray", "box:api", "--memory", "--json"],
                  ["--xray", "box:api", "--search", "x", "--json"], ["--xray", "box:api", "--follow", "--json"],
                  ["--xray", "box:api", "--json", "--follow"], ["--xray", "box:other", "--json"], ["--xray", "box:api"]] {
            XCTAssertTrue(f(a) == nil, "\(a)")
        }
    }
}
