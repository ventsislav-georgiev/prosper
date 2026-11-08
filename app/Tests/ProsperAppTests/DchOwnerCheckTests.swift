import Foundation
import XCTest
@testable import ProsperApp

/// #777: the owner check's policy, cache, timeout, relax setting and status text, through a whois
/// fake or a fake `tailscale` CLI. Never the real Tailscale CLI and never the live Preferences (the
/// relax setting is a closure). dch serve's gate (serve.c serve_gate) is the reference for the
/// cases. Every address, name, login and id here is made up.
final class DchOwnerCheckTests: XCTestCase {

    typealias Verdict = DchOwnerCheck.Verdict

    static let phoneIP = "100.64.0.1"
    static let me = TailscaleNode(userID: 1, login: "me@example.com", name: "my-mac")
    static let phone = TailscaleNode(userID: 1, login: "me@example.com", name: "my-phone")

    /// A whois fake: answers `answer` (or throws it) and counts its calls.
    final class FakeWhois: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var answer: Result<TailscaleWhois, any Error>
        var delay: TimeInterval = 0
        /// Held until signalled, after the call is counted.
        var hold: DispatchSemaphore?
        init(_ answer: Result<TailscaleWhois, any Error>) { self.answer = answer }
        var asked: [String] { lock.withLock { calls } }
        func callAsFunction(_ ip: String) throws -> TailscaleWhois {
            lock.withLock { calls.append(ip) }
            hold?.wait()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return try lock.withLock { answer }.get()
        }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_000_000)
        var now: Date { lock.withLock { t } }
        func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var v = false
        var value: Bool {
            get { lock.withLock { v } }
            set { lock.withLock { v = newValue } }
        }
    }

    /// A fake `tailscale` CLI for `DchOwnerCheck.tailscaleWhois`, the production status-then-whois
    /// path: replies per "<path> <verb>" ("/cli status", "/cli whois"), records every call.
    final class FakeCLI: @unchecked Sendable {
        enum Reply {
            case out(TailscaleCLIOutput)
            /// Killed at its bound: the production runner answers nil.
            case timeout
            /// Still running when the check's own bound passes.
            case hang(TimeInterval)
        }
        private let lock = NSLock()
        private var log: [String] = []
        private var table: [String: Reply]
        let installed: Set<String>
        init(_ replies: [String: Reply], installed: Set<String> = ["/cli"]) {
            table = replies
            self.installed = installed
        }
        var calls: [String] { lock.withLock { log } }
        func set(_ key: String, _ reply: Reply) { lock.withLock { table[key] = reply } }
        func run(_ path: String, _ args: [String]) -> TailscaleCLIOutput? {
            let key = "\(path) \(args[0])"
            let reply: Reply? = lock.withLock { log.append(key); return table[key] }
            switch reply {
            case .out(let o)?: return o
            case .timeout?: return nil
            case .hang(let s)?: Thread.sleep(forTimeInterval: s); return nil
            case nil: return TailscaleCLIOutput(exit: 99, err: "unexpected call \(key)")
            }
        }
        func whois(_ candidates: [String] = ["/cli"]) -> DchOwnerCheck.Lookup {
            { ip, answered in
                try DchOwnerCheck.tailscaleWhois(ip, statusAnswered: answered, candidates: candidates,
                                                 isExecutable: { self.installed.contains($0) }, run: self.run)
            }
        }
    }

    static func json(_ s: String, exit: Int32 = 0) -> FakeCLI.Reply { .out(TailscaleCLIOutput(exit: exit, out: Data(s.utf8))) }
    static func fail(_ err: String, exit: Int32 = 1) -> FakeCLI.Reply { .out(TailscaleCLIOutput(exit: exit, err: err)) }
    static func status(_ state: String, id: String = "n1") -> FakeCLI.Reply {
        json(#"{"BackendState":"\#(state)","Self":{"ID":"\#(id)","UserID":1,"HostName":"my-mac"}}"#)
    }
    static let running = status("Running")
    static let phoneWhois = json(#"{"Node":{"StableID":"n2","ComputedName":"my-phone","Tags":null},"UserProfile":{"ID":1,"LoginName":"me@example.com"}}"#)
    static let refusedToConnect = "failed to connect to local Tailscale service; is Tailscale running?"

    private func gate(_ whois: FakeWhois, relax: Flag = Flag(), timeout: TimeInterval = 2,
                      clock: Clock = Clock(), local: Set<String> = []) -> DchOwnerCheck {
        gate(whois: { ip, _ in try whois(ip) }, relax: relax, timeout: timeout, clock: clock, local: local)
    }

    private func gate(whois: @escaping DchOwnerCheck.Lookup, relax: Flag = Flag(), timeout: TimeInterval = 2,
                      clock: Clock = Clock(), local: Set<String> = []) -> DchOwnerCheck {
        DchOwnerCheck(whois: whois, allowWhenDown: { relax.value },
                      isLocalAddress: { local.contains($0) }, timeout: timeout, now: { clock.now })
    }

    private func verdict(_ c: DchOwnerCheck, _ ip: String = phoneIP) -> Verdict? {
        final class Box: @unchecked Sendable { var v: Verdict? }
        let box = Box(), e = expectation(description: "check \(ip)")
        c.check(ip) { box.v = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        return box.v
    }

    private func answer(peer: TailscaleNode?, host: TailscaleNode = me) -> FakeWhois {
        FakeWhois(.success(TailscaleWhois(host: host, peer: peer)))
    }

    // MARK: - Policy

    /// The phone on a personal tailnet: the same user id as the host. Allowed, no status line.
    func testOwnersDeviceIsAllowed() {
        let w = answer(peer: Self.phone)
        let c = gate(w)
        XCTAssertEqual(verdict(c), .owner)
        XCTAssertTrue(Verdict.owner.allowed)
        XCTAssertEqual(w.asked, [Self.phoneIP])
        XCTAssertNil(DchOwnerCheck.statusText(ip: Self.phoneIP, .owner))
    }

    func testOtherUserIsRefused() {
        let bob = TailscaleNode(userID: 2, login: "bob@example.com", name: "bobs-phone")
        let v = verdict(gate(answer(peer: bob)))
        XCTAssertEqual(v, .otherUser(bob))
        XCTAssertEqual(v?.allowed, false)
    }

    /// The id decides, never the login: a same-login peer with another id is someone else
    /// (a login can be reused across tailnets/IdPs), a different login with the owner's id is the owner.
    func testOwnerIsTheUserIDNotTheLogin() {
        let sameLogin = TailscaleNode(userID: 99, login: Self.me.login, name: "lookalike")
        XCTAssertEqual(verdict(gate(answer(peer: sameLogin))), .otherUser(sameLogin))
        let renamed = TailscaleNode(userID: Self.me.userID, login: "me@new-idp.example", name: "my-phone")
        XCTAssertEqual(verdict(gate(answer(peer: renamed))), .owner)
    }

    /// Refused even when whois reports the owner's id for it (some Tailscale versions give a
    /// tagged node the tagging user's profile).
    func testTaggedPeerIsRefusedEvenWithTheOwnersID() {
        let tagged = TailscaleNode(userID: Self.me.userID, login: Self.me.login, name: "exit-node", tagged: true)
        XCTAssertEqual(verdict(gate(answer(peer: tagged))), .taggedPeer(tagged))
        let taggedDevices = TailscaleNode(userID: 2_147_455_555, login: "tagged-devices", name: "server-a", tagged: true)
        XCTAssertEqual(verdict(gate(answer(peer: taggedDevices))), .taggedPeer(taggedDevices))
    }

    /// A tagged host has no owner: every peer is refused, including a tagged peer that shares
    /// the tagged-devices id with it.
    func testTaggedHostRefusesEveryPeer() {
        let host = TailscaleNode(userID: 2_147_455_555, login: "tagged-devices", name: "my-mac", tagged: true)
        let sibling = TailscaleNode(userID: 2_147_455_555, login: "tagged-devices", name: "server-b", tagged: true)
        XCTAssertEqual(verdict(gate(answer(peer: sibling, host: host))), .taggedHost)
        XCTAssertEqual(verdict(gate(answer(peer: Self.phone, host: host))), .taggedHost)
    }

    func testUnknownPeerIsRefused() {
        XCTAssertEqual(verdict(gate(answer(peer: nil))), .unknownPeer)
    }

    /// The "tagged-devices" identity is tagged even with no Tags key (dch serve does the same).
    func testTaggedDevicesLoginCountsAsTagged() throws {
        let whois = #"{"Node":{"StableID":"7","Name":"x"},"UserProfile":{"ID":5,"LoginName":"tagged-devices"}}"#
        XCTAssertTrue(try DchOwnerCheck.parsePeer(Data(whois.utf8)).tagged)
        let status = #"{"BackendState":"Running","Self":{"ID":"9","UserID":5},"User":{"5":{"LoginName":"tagged-devices"}}}"#
        XCTAssertTrue(try DchOwnerCheck.parseHost(Data(status.utf8)).tagged)
    }

    /// dch serve's G_SELF: this Mac's own addresses (any local user or app can connect from them)
    /// are refused with no whois; its own node through another address is refused too, though
    /// its user id is the owner's. Loopback is left to the address gate.
    func testThisMacIsRefused() {
        let w = answer(peer: Self.phone)
        let c = gate(w, local: ["192.168.1.20", "100.64.0.2", "127.0.0.1"])
        XCTAssertEqual(verdict(c, "100.64.0.2"), .thisMac)
        XCTAssertEqual(verdict(c, "192.168.1.20"), .thisMac)
        XCTAssertEqual(w.asked, [], "decided with no whois")
        XCTAssertEqual(verdict(c, "127.0.0.1"), .owner, "loopback: the address gate's, a test's allowPeer lets it here")
        var me = Self.me
        me.nodeID = "n1"
        var sameNode = Self.phone
        sameNode.nodeID = "n1"
        XCTAssertEqual(verdict(gate(answer(peer: sameNode, host: me))), .thisMac)
        var phone = Self.phone
        phone.nodeID = "n2"
        XCTAssertEqual(verdict(gate(answer(peer: phone, host: me))), .owner)
        XCTAssertEqual(verdict(gate(answer(peer: Self.phone, host: Self.me))), .owner, "no node ids: no node match")
        XCTAssertEqual(verdict(gate(answer(peer: Self.phone, host: me))), .unusable("Tailscale's whois answer has no device id"),
                       "dch serve: with this Mac's node id known, a peer without one can't be told apart from it")
        XCTAssertTrue(DchOwnerCheck.isLocalAddress("127.0.0.1"))
        XCTAssertFalse(DchOwnerCheck.isLocalAddress("100.127.255.254"))
        XCTAssertFalse(DchOwnerCheck.isLocalAddress("not an address"))
    }

    // MARK: - Whois unavailable

    func testWhoisErrorFailsClosed() {
        let v = verdict(gate(FakeWhois(.failure(WhoisUnavailable(cause: "Tailscale isn't installed")))))
        XCTAssertEqual(v, .unavailable("Tailscale isn't installed"))
        XCTAssertEqual(v?.allowed, false)
        let u = verdict(gate(FakeWhois(.failure(WhoisUnusable(cause: "tailscale whois failed (boom)")))))
        XCTAssertEqual(u, .unusable("tailscale whois failed (boom)"))
        XCTAssertEqual(u?.allowed, false)
        struct Odd: Error {}
        XCTAssertEqual(verdict(gate(FakeWhois(.failure(Odd()))))?.allowed, false, "any other throw refuses")
    }

    /// A hung whois is cut at the timeout and refused; the late answer is ignored.
    func testWhoisTimeoutFailsClosedWithinTheBound() {
        let w = answer(peer: Self.phone)
        w.delay = 3
        let c = gate(w, timeout: 0.2)
        let start = Date()
        XCTAssertEqual(verdict(c), .unavailable("Tailscale didn't answer within 0.2 s"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "the listener never waits on a hung whois")
        XCTAssertEqual(DchOwnerCheck.timeoutCause(DchOwnerCheck.timeout), "Tailscale didn't answer within 2 s")
    }

    /// "Allow when Tailscale isn't answering" relaxes only that case (dch serve's --whois-optional),
    /// read per check: never a whois failure while status works, never anything Tailscale answered
    /// (a host answering "Stopped" is answering: testCLIOutcomesMapToVerdicts).
    func testRelaxSettingAllowsOnlyTailscaleNotAnswering() {
        let relax = Flag()
        let cause = "Tailscale isn't answering (\(Self.refusedToConnect))"
        let down = FakeWhois(.failure(WhoisUnavailable(cause: cause)))
        let c = gate(down, relax: relax)
        XCTAssertEqual(verdict(c), .unavailable(cause))
        relax.value = true
        let v = verdict(c)
        XCTAssertEqual(v, .unverified(cause))
        XCTAssertEqual(v?.allowed, true)
        // a timeout before status answered is "unavailable" too (one after it: testTimeoutAfterStatusIsNeverRelaxed)
        let hung = answer(peer: nil)
        hung.delay = 3
        XCTAssertEqual(verdict(gate(hung, relax: relax, timeout: 0.2)), .unverified("Tailscale didn't answer within 0.2 s"))
        // never anything whois actually answered
        let bob = TailscaleNode(userID: 2, login: "bob@example.com", name: "bobs-phone")
        XCTAssertEqual(verdict(gate(answer(peer: bob), relax: relax)), .otherUser(bob))
        let tagged = TailscaleNode(userID: 1, name: "exit-node", tagged: true)
        XCTAssertEqual(verdict(gate(answer(peer: tagged), relax: relax)), .taggedPeer(tagged))
        XCTAssertEqual(verdict(gate(answer(peer: nil), relax: relax)), .unknownPeer)
        XCTAssertEqual(verdict(gate(answer(peer: Self.phone, host: TailscaleNode(userID: 7, tagged: true)), relax: relax)),
                       .taggedHost)
        XCTAssertEqual(verdict(gate(FakeWhois(.failure(WhoisUnusable(cause: "tailscale whois failed (boom)"))), relax: relax)),
                       .unusable("tailscale whois failed (boom)"))
        XCTAssertEqual(verdict(gate(answer(peer: Self.phone), relax: relax, local: [Self.phoneIP])), .thisMac)
    }

    // MARK: - Cache

    /// One whois per IP per TTL for an answer; another IP and an expired entry ask again.
    func testCacheHitsWithinTheTTL() {
        let w = answer(peer: Self.phone), clock = Clock()
        let c = gate(w, clock: clock)
        XCTAssertEqual(verdict(c), .owner)
        XCTAssertEqual(verdict(c), .owner)
        XCTAssertEqual(w.asked, [Self.phoneIP], "the second connection is a cache hit")
        XCTAssertEqual(verdict(c, "100.64.0.3"), .owner)
        XCTAssertEqual(w.asked, [Self.phoneIP, "100.64.0.3"])
        clock.advance(DchOwnerCheck.ttl - 1)
        _ = verdict(c)
        XCTAssertEqual(w.asked.count, 2, "still inside the 30 s TTL")
        clock.advance(2)
        _ = verdict(c)
        XCTAssertEqual(w.asked.count, 3, "expired: asked again")
        XCTAssertEqual(DchOwnerCheck.ttl, 30)
    }

    /// Every answer Tailscale gave is cached, refusals too (dch serve's 30 s NEG_MS: a refused
    /// peer that keeps reconnecting forks nothing). "Not answering" is asked again, so a
    /// Tailscale that comes back is seen on the next connection.
    func testOnlyNotAnsweringIsAskedAgain() {
        let w = FakeWhois(.failure(WhoisUnavailable(cause: "Tailscale isn't installed")))
        let relax = Flag()
        let c = gate(w, relax: relax)
        _ = verdict(c)
        relax.value = true
        XCTAssertEqual(verdict(c), .unverified("Tailscale isn't installed"), "nor is a relaxed one cached")
        w.answer = .success(TailscaleWhois(host: Self.me, peer: nil))
        XCTAssertEqual(verdict(c), .unknownPeer)
        XCTAssertEqual(w.asked.count, 3)
        w.answer = .success(TailscaleWhois(host: Self.me, peer: Self.phone))
        XCTAssertEqual(verdict(c), .unknownPeer, "cached for the TTL")
        XCTAssertEqual(w.asked.count, 3)
        for refusal in [Result<TailscaleWhois, any Error>.success(TailscaleWhois(host: Self.me, peer: TailscaleNode(userID: 2, name: "bob"))),
                        .failure(WhoisUnusable(cause: "x"))] {
            let other = FakeWhois(refusal)
            let c2 = gate(other)
            _ = verdict(c2); _ = verdict(c2)
            XCTAssertEqual(other.asked.count, 1)
        }
    }

    // MARK: - Status text

    /// QA #635 INFO 1: "Couldn't verify" says whether the setting would help.
    func testStatusText() {
        let ip = Self.phoneIP
        XCTAssertEqual(DchOwnerCheck.statusText(ip: ip, .unavailable("Tailscale isn't installed")),
                       "Couldn't verify 100.64.0.1: Tailscale isn't installed. "
                       + "Turning on \"Allow when Tailscale isn't answering\" would let it in.")
        XCTAssertEqual(DchOwnerCheck.statusText(ip: ip, .unverified("Tailscale isn't installed")),
                       "Let in 100.64.0.1 without verifying it: Tailscale isn't installed.")
        XCTAssertEqual(DchOwnerCheck.statusText(ip: ip, .otherUser(TailscaleNode(userID: 2, login: "bob@example.com", name: "bobs-phone"))),
                       "Refused bobs-phone (100.64.0.1): it belongs to another Tailscale user, bob@example.com.")
        XCTAssertEqual(DchOwnerCheck.statusText(ip: ip, .taggedPeer(TailscaleNode(userID: 1, name: "exit-node", tagged: true))),
                       "Refused exit-node (100.64.0.1): tagged Tailscale devices aren't allowed.")
        XCTAssertEqual(DchOwnerCheck.statusText(ip: ip, .unusable("tailscale whois failed (boom)")),
                       "Couldn't verify 100.64.0.1: tailscale whois failed (boom). Tailscale is answering, so this can't be allowed.")
        XCTAssertEqual(DchOwnerCheck.statusText(ip: ip, .thisMac),
                       "Refused 100.64.0.1: it's this Mac's own address, which any app or user on this Mac can use.")
        XCTAssertEqual(DchOwnerCheck.statusText(ip: ip, .unknownPeer),
                       "Refused 100.64.0.1: Tailscale doesn't know this device.")
        XCTAssertEqual(DchOwnerCheck.statusText(ip: ip, .taggedHost),
                       "Refused 100.64.0.1: this Mac is a tagged Tailscale device, so no user owns it. "
                       + "Log this Mac in to Tailscale as yourself.")
    }

    /// The settings line follows the last check, on main: set by a refusal, cleared by the owner.
    func testStatusIsPublishedOnMainAndClearedByTheOwner() {
        let w = FakeWhois(.failure(WhoisUnavailable(cause: "Tailscale isn't installed")))
        let c = gate(w)
        _ = verdict(c)
        waitForStatus(c, DchOwnerCheck.statusText(ip: Self.phoneIP, .unavailable("Tailscale isn't installed")))
        w.answer = .success(TailscaleWhois(host: Self.me, peer: Self.phone))
        _ = verdict(c)
        waitForStatus(c, nil)
    }

    private func waitForStatus(_ c: DchOwnerCheck, _ want: String?, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date() + 5
        while c.status != want, Date() < end { RunLoop.main.run(until: Date() + 0.02) }
        XCTAssertEqual(c.status, want, file: file, line: line)
    }

    // MARK: - CLI output parsing (shapes from tailscale 1.104.4, ids and names made up)

    func testParsesStatusAndWhois() throws {
        let status = #"{"Version":"1.104.4","BackendState":"Running","Self":{"ID":"7","UserID":1,"HostName":"my-mac","Tags":null},"User":{"1":{"ID":1,"LoginName":"me@example.com"}}}"#
        XCTAssertEqual(try DchOwnerCheck.parseHost(Data(status.utf8)),
                       TailscaleNode(userID: 1, nodeID: "7", login: "me@example.com", name: "my-mac"))
        // Tailscale's own control plane: Self.ID is the stable id string, as whois's Node.StableID.
        let saas = #"{"BackendState":"Running","Self":{"ID":"nAbC123CNTRL","UserID":1}}"#
        XCTAssertEqual(try DchOwnerCheck.parseHost(Data(saas.utf8)).nodeID, "nAbC123CNTRL")
        let tagged = #"{"BackendState":"Running","Self":{"UserID":2147455555,"HostName":"my-mac","Tags":["tag:server"]}}"#
        XCTAssertEqual(try DchOwnerCheck.parseHost(Data(tagged.utf8)).tagged, true)
        let big = #"{"BackendState":"Running","Self":{"UserID":9007199254740993}}"#
        XCTAssertEqual(try DchOwnerCheck.parseHost(Data(big.utf8)).userID, 9_007_199_254_740_993, "int64 ids parse exactly")

        let whois = #"{"Node":{"ID":8,"StableID":"8","Name":"my-phone.example.ts.net.","ComputedName":"my-phone","User":1,"Tags":null},"UserProfile":{"ID":1,"LoginName":"me@example.com","DisplayName":"Me"},"CapMap":null}"#
        XCTAssertEqual(try DchOwnerCheck.parsePeer(Data(whois.utf8)),
                       TailscaleNode(userID: 1, nodeID: "8", login: "me@example.com", name: "my-phone"))
        let taggedPeer = #"{"Node":{"Name":"exit-node.example.ts.net.","Tags":["tag:exit"]},"UserProfile":{"ID":2147455555,"LoginName":"tagged-devices"}}"#
        XCTAssertEqual(try DchOwnerCheck.parsePeer(Data(taggedPeer.utf8)),
                       TailscaleNode(userID: 2_147_455_555, login: "tagged-devices", name: "exit-node.example.ts.net.", tagged: true))
    }

    /// A changed or broken CLI output, or a host not Running, is "unusable" with a cause, never a
    /// guess. Not Running is asked again (`askAgain`), the rest is remembered for the TTL.
    func testUnreadableOrNotRunningStatusIsUnusable() {
        func error(_ json: String, peer: Bool = false) -> WhoisUnusable? {
            do {
                if peer { _ = try DchOwnerCheck.parsePeer(Data(json.utf8)) } else { _ = try DchOwnerCheck.parseHost(Data(json.utf8)) }
                return nil
            } catch { return error as? WhoisUnusable }
        }
        for state in ["Stopped", "NeedsLogin", "Starting"] {
            XCTAssertEqual(error(#"{"BackendState":"\#(state)","Self":{"UserID":1}}"#),
                           WhoisUnusable(cause: "Tailscale isn't connected (\(state))", askAgain: true))
        }
        XCTAssertEqual(error(#"{"Self":{"UserID":1}}"#), WhoisUnusable(cause: "Tailscale isn't connected (no state)", askAgain: true))
        XCTAssertEqual(error(#"{"BackendState":"Running","Self":{}}"#), WhoisUnusable(cause: "Tailscale's status has no user for this Mac"))
        XCTAssertEqual(error("not json"), WhoisUnusable(cause: "Tailscale's status couldn't be read"))
        XCTAssertEqual(error(#"{"Node":{"Name":"x"},"UserProfile":{"LoginName":"me@example.com"}}"#, peer: true),
                       WhoisUnusable(cause: "Tailscale's whois answer couldn't be read"), "a login without an id is never trusted")
        XCTAssertEqual(error("", peer: true), WhoisUnusable(cause: "Tailscale's whois answer couldn't be read"))
        // QA #635 INFO 5: dch serve refuses a whois answer with no Node; so does Prosper.
        XCTAssertEqual(error(#"{"UserProfile":{"ID":1,"LoginName":"me@example.com"}}"#, peer: true),
                       WhoisUnusable(cause: "Tailscale's whois answer names no device"))
        XCTAssertEqual(error(#"{"Node":null,"UserProfile":{"ID":1}}"#, peer: true),
                       WhoisUnusable(cause: "Tailscale's whois answer names no device"))
    }

    func testCLICandidatesCoverEveryInstall() {
        XCTAssertEqual(DchOwnerCheck.cliCandidates, [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
            "/opt/local/bin/tailscale",
        ])
    }

    // MARK: - CLI outcomes (QA #635): the production status-then-whois path over a fake CLI

    /// QA #635 INFO 2: how each real CLI outcome maps to a verdict, and whether it is remembered
    /// for the TTL (a second check that asks the CLI again was not).
    func testCLIOutcomesMapToVerdicts() {
        struct Row {
            let name: String
            let status: FakeCLI.Reply
            var whois: FakeCLI.Reply?
            let want: Verdict
            let cached: Bool
        }
        let rows = [
            Row(name: "owner", status: Self.running, whois: Self.phoneWhois, want: .owner, cached: true),
            Row(name: "status exits 1", status: Self.fail(Self.refusedToConnect),
                want: .unavailable("Tailscale isn't answering (\(Self.refusedToConnect))"), cached: false),
            Row(name: "status exits 1, no message", status: Self.fail(""),
                want: .unavailable("Tailscale isn't answering (no message)"), cached: false),
            Row(name: "Stopped", status: Self.status("Stopped"), want: .unusable("Tailscale isn't connected (Stopped)"), cached: false),
            Row(name: "NeedsLogin", status: Self.status("NeedsLogin"), want: .unusable("Tailscale isn't connected (NeedsLogin)"), cached: false),
            Row(name: "Starting", status: Self.status("Starting"), want: .unusable("Tailscale isn't connected (Starting)"), cached: false),
            Row(name: "status unreadable", status: Self.json("Warning: something\n{"),
                want: .unusable("Tailscale's status couldn't be read"), cached: true),
            Row(name: "CLI can't start", status: .out(TailscaleCLIOutput(exit: -1)),
                want: .unavailable("the Tailscale command couldn't start"), cached: false),
            Row(name: "status timed out", status: .timeout,
                want: .unavailable(DchOwnerCheck.timeoutCause(DchOwnerCheck.timeout)), cached: false),
            Row(name: "whois peer not found", status: Self.running, whois: Self.fail("peer not found\n"),
                want: .unknownPeer, cached: true),
            Row(name: "whois other error", status: Self.running, whois: Self.fail("boom: LocalAPI said no\nmore"),
                want: .unusable("tailscale whois failed (boom: LocalAPI said no)"), cached: true),
            Row(name: "whois unreadable", status: Self.running, whois: Self.json("{}"),
                want: .unusable("Tailscale's whois answer couldn't be read"), cached: true),
            // A host with no node id, so the answer without a Node would otherwise pass as the owner.
            Row(name: "whois without Node", status: Self.json(#"{"BackendState":"Running","Self":{"UserID":1}}"#),
                whois: Self.json(#"{"UserProfile":{"ID":1,"LoginName":"me@example.com"}}"#),
                want: .unusable("Tailscale's whois answer names no device"), cached: true),
            Row(name: "whois Node without StableID", status: Self.running,
                whois: Self.json(#"{"Node":{"ComputedName":"my-phone"},"UserProfile":{"ID":1}}"#),
                want: .unusable("Tailscale's whois answer has no device id"), cached: true),
            Row(name: "whois this Mac's node", status: Self.running,
                whois: Self.json(#"{"Node":{"StableID":"n1"},"UserProfile":{"ID":1}}"#), want: .thisMac, cached: false),
            Row(name: "whois can't start", status: Self.running, whois: .out(TailscaleCLIOutput(exit: -1)),
                want: .unusable("tailscale whois couldn't start"), cached: false),
            Row(name: "whois timed out", status: Self.running, whois: .timeout,
                want: .unusable("tailscale whois didn't answer within 2 s"), cached: false),
        ]
        for row in rows {
            var replies = ["/cli status": row.status]
            if let w = row.whois { replies["/cli whois"] = w }
            let cli = FakeCLI(replies)
            let relax = Flag()
            relax.value = true   // relaxes "not answering" only: the rest must come out unchanged
            let c = gate(whois: cli.whois(), relax: relax)
            let want: Verdict = if case .unavailable(let cause) = row.want { .unverified(cause) } else { row.want }
            XCTAssertEqual(verdict(c), want, row.name)
            XCTAssertEqual(cli.calls, row.whois == nil ? ["/cli status"] : ["/cli status", "/cli whois"], row.name)
            let first = cli.calls.count
            XCTAssertEqual(verdict(c), want, row.name)
            XCTAssertEqual(cli.calls.count, row.cached ? first : 2 * first, "\(row.name): cached \(row.cached)")
        }
    }

    /// QA #635 F2: once `tailscale status` answered, a timeout is "unusable" and refused even with
    /// "Allow when Tailscale isn't answering" on; only a timeout before it is "not answering".
    func testTimeoutAfterStatusIsNeverRelaxed() {
        let relax = Flag()
        relax.value = true
        let hungWhois = FakeCLI(["/cli status": Self.running, "/cli whois": .hang(3)])
        let start = Date()
        let late = verdict(gate(whois: hungWhois.whois(), relax: relax, timeout: 0.2))
        XCTAssertEqual(late, .unusable("Tailscale answered but didn't finish within 0.2 s"))
        XCTAssertEqual(late?.allowed, false)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "cut at the bound")
        let hungStatus = FakeCLI(["/cli status": .hang(3)])
        XCTAssertEqual(verdict(gate(whois: hungStatus.whois(), relax: relax, timeout: 0.2)),
                       .unverified("Tailscale didn't answer within 0.2 s"))
        // The seam: a whois that reports status answered, then hangs or claims "not answering".
        let hang: DchOwnerCheck.Lookup = { _, answered in
            answered()
            Thread.sleep(forTimeInterval: 3)
            throw WhoisUnavailable(cause: "late")
        }
        XCTAssertEqual(verdict(gate(whois: hang, relax: relax, timeout: 0.2)), .unusable("Tailscale answered but didn't finish within 0.2 s"))
        let claims: DchOwnerCheck.Lookup = { _, answered in
            answered()
            throw WhoisUnavailable(cause: "Tailscale isn't answering (x)")
        }
        XCTAssertEqual(verdict(gate(whois: claims, relax: relax)), .unusable("Tailscale isn't answering (x)"))
        XCTAssertEqual(DchOwnerCheck.lateCause(DchOwnerCheck.timeout), "Tailscale answered but didn't finish within 2 s")
    }

    /// QA #635 INFO 3: a host that isn't Running yet (Starting after wake) is refused, never
    /// relaxed, and not remembered: the next connection, once Tailscale is up, gets in at once.
    func testNotRunningIsRefusedButAskedAgain() {
        let relax = Flag()
        relax.value = true
        let cli = FakeCLI(["/cli status": Self.status("Starting"), "/cli whois": Self.phoneWhois])
        let c = gate(whois: cli.whois(), relax: relax)
        XCTAssertEqual(verdict(c), .unusable("Tailscale isn't connected (Starting)"))
        cli.set("/cli status", Self.running)
        XCTAssertEqual(verdict(c), .owner, "no 30 s lockout once Tailscale is up")
        XCTAssertEqual(cli.calls, ["/cli status", "/cli status", "/cli whois"])
    }

    /// QA #635 INFO 6: the first CLI that ANSWERS is used, not the first that exists: the App Store
    /// app installed with its daemon off, Homebrew's tailscaled running.
    func testFirstAnsweringCLIWins() {
        let app = "/Applications/Tailscale.app/Contents/MacOS/Tailscale", brew = "/opt/homebrew/bin/tailscale"
        let ports = "/opt/local/bin/tailscale"
        let all = DchOwnerCheck.cliCandidates
        let cli = FakeCLI(["\(app) status": Self.fail(Self.refusedToConnect), "\(brew) status": Self.running,
                           "\(brew) whois": Self.phoneWhois], installed: [app, brew])
        XCTAssertEqual(verdict(gate(whois: cli.whois(all))), .owner)
        XCTAssertEqual(cli.calls, ["\(app) status", "\(brew) status", "\(brew) whois"], "whois asks the CLI that answered")

        let notInstalled = FakeCLI(["\(ports) status": Self.running, "\(ports) whois": Self.phoneWhois], installed: [ports])
        XCTAssertEqual(verdict(gate(whois: notInstalled.whois(all))), .owner)
        XCTAssertEqual(notInstalled.calls, ["\(ports) status", "\(ports) whois"], "a CLI that isn't there is skipped")

        let notRunningFirst = FakeCLI(["\(app) status": Self.status("Stopped"), "\(brew) status": Self.running,
                                       "\(brew) whois": Self.phoneWhois], installed: [app, brew])
        XCTAssertEqual(verdict(gate(whois: notRunningFirst.whois(all))), .owner, "a Stopped app hands over to a running tailscaled")

        let relax = Flag()
        relax.value = true
        let noneUp = FakeCLI(["\(app) status": Self.fail("first"), "\(brew) status": .out(TailscaleCLIOutput(exit: -1))],
                             installed: [app, brew])
        XCTAssertEqual(verdict(gate(whois: noneUp.whois(all))), .unavailable("Tailscale isn't answering (first)"))
        let oneAnswered = FakeCLI(["\(app) status": Self.status("NeedsLogin"), "\(brew) status": Self.fail("down")],
                                  installed: [app, brew])
        XCTAssertEqual(verdict(gate(whois: oneAnswered.whois(all), relax: relax)), .unusable("Tailscale isn't connected (NeedsLogin)"),
                       "one CLI answered: Tailscale is answering, never relaxed")
        let unreadable = FakeCLI(["\(app) status": Self.json("{"), "\(brew) status": Self.running], installed: [app, brew])
        XCTAssertEqual(verdict(gate(whois: unreadable.whois(all), relax: relax)), .unusable("Tailscale's status couldn't be read"))
        XCTAssertEqual(unreadable.calls, ["\(app) status"], "an answer it can't read stops there")
        XCTAssertEqual(verdict(gate(whois: FakeCLI([:], installed: []).whois(all), relax: relax)), .unverified("Tailscale isn't installed"))
    }

    /// QA #635 INFO 4: connections from an address whose check is in flight wait for that check;
    /// one CLI round per address, not per connection. Another address asks on its own.
    func testConcurrentChecksFromOneAddressShareOneLookup() {
        let w = answer(peer: Self.phone)
        let hold = DispatchSemaphore(value: 0)
        w.hold = hold
        let c = gate(w, timeout: 10)
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var got: [Verdict] = []
            func add(_ v: Verdict) { lock.withLock { got.append(v) } }
            var all: [Verdict] { lock.withLock { got } }
        }
        let box = Box()
        let e = expectation(description: "three verdicts")
        e.expectedFulfillmentCount = 3
        c.check(Self.phoneIP) { box.add($0); e.fulfill() }
        c.check(Self.phoneIP) { box.add($0); e.fulfill() }
        c.check(Self.phoneIP) { box.add($0); e.fulfill() }
        let end = Date() + 5
        while w.asked.isEmpty, Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        Thread.sleep(forTimeInterval: 0.3)   // room for a second lookup to start, if one would
        XCTAssertEqual(w.asked, [Self.phoneIP], "the later connections wait on the first lookup")
        for _ in 0..<3 { hold.signal() }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(box.all, [.owner, .owner, .owner])
        XCTAssertEqual(w.asked, [Self.phoneIP])

        w.hold = nil
        XCTAssertEqual(verdict(c, "100.64.0.3"), .owner)
        XCTAssertEqual(w.asked, [Self.phoneIP, "100.64.0.3"])
    }
}
