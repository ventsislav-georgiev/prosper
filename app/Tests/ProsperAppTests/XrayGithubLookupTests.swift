import XCTest
@testable import ProsperApp

/// #1623: the "Look up issues and pull requests on GitHub" setting on the X-ray ref reads (XrayTarget.refCall, runRef).
/// A fake Run records argv and env; the setting lives in the scratch defaults. No dch, no process, no window.
@MainActor
final class XrayGithubLookupTests: XCTestCase {
    static let local = XrayTarget(name: "api", dir: "/tmp/dch-test")
    static let remote = XrayTarget(name: "box:api", dir: nil)
    static let key = "xrayGithubLookups"

    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(args: [String], env: [String: String])] = []
        /// The status of call n (0-based); beyond the list: 0.
        var statuses: [Int32] = []
        var calls: [(args: [String], env: [String: String])] { lock.withLock { _calls } }
        var run: XrayPanels.Run {
            { [self] _, args, env in
                lock.withLock {
                    _calls.append((args, env))
                    let n = _calls.count - 1
                    return (n < statuses.count ? statuses[n] : 0, Data(XrayRefStreamTests.golden.joined(separator: "\n").utf8))
                }
            }
        }
    }

    private var saved: Any?
    override func setUp() {
        saved = Preferences.defaults.object(forKey: Self.key)
        Preferences.defaults.removeObject(forKey: Self.key)
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 114, 0])
    }
    override func tearDown() {
        if let saved { Preferences.defaults.set(saved, forKey: Self.key) } else { Preferences.defaults.removeObject(forKey: Self.key) }
        XrayPanels.probed = nil
    }

    func read(_ target: XrayTarget, _ run: Run, off: Bool = true) async {
        if off { Preferences.xrayGithubLookups = false }
        let panels = XrayPanels(), p = XrayPanelModel(target: target, tab: .search)
        (p.dch, p.run) = ("/fake/dch", run.run)
        XCTAssertTrue(panels.runRef("#12", for: p))
        await panels.refReading?.value
    }

    func testLookupsAreOnByDefault() {
        XCTAssertTrue(Preferences.defaults.object(forKey: Self.key) == nil)
        XCTAssertTrue(Preferences.xrayGithubLookups)
        Preferences.xrayGithubLookups = false
        XCTAssertEqual(Preferences.defaults.object(forKey: Self.key) as? Bool, false)
    }

    func testOnSendsNeitherTheEnvNorTheFlag() async {
        let run = Run()
        await read(Self.local, run, off: false)
        XCTAssertTrue(run.calls.last?.env["DCH_NO_GITHUB"] == nil)
        XCTAssertFalse(run.calls.last?.args.contains("--no-github") ?? true)
        let r = Run()
        await read(Self.remote, r, off: false)
        XCTAssertFalse(r.calls.last?.args.contains("--no-github") ?? true)
    }

    func testOffSetsTheEnvOnALocalReadAndNoFlag() async {
        let run = Run()
        await read(Self.local, run)
        XCTAssertEqual(run.calls.last?.env["DCH_NO_GITHUB"], "1")
        XCTAssertFalse(run.calls.last?.args.contains("--no-github") ?? true, "a local read uses the env var")
    }

    func testOffPutsTheFlagOnARemoteReadFrom1_113AndNotBelow() async {
        let run = Run()
        await read(Self.remote, run)
        XCTAssertEqual(run.calls.last?.args, ["--xray", "box:api", "--ref", "#12", "--scope", "project", "--full", "--no-github", "--json"])
        XCTAssertTrue(run.calls.last?.env["DCH_NO_GITHUB"] == nil, "the env var cannot reach a remote")
        for v in [[1, 112, 0], [1, 111, 0]] {
            XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: v)
            let old = Run()
            await read(Self.remote, old)
            XCTAssertFalse(old.calls.last?.args.contains("--no-github") ?? true, "\(v)")
        }
        XrayPanels.probed = nil
        let none = Run()
        await read(Self.remote, none)
        XCTAssertFalse(none.calls.last?.args.contains("--no-github") ?? true, "no probe yet")
    }

    func testTheFlagIsAForm() {
        let args = Self.remote.refCall(Self.remote.refArgs("#12"), version: [1, 113, 0], lookups: false).args
        XCTAssertEqual(XrayRequests.form(args, name: "box:api"), Array(args.dropFirst(2)), "--requests takes it next to --ref/--json")
    }

    func testANonRefReadNeverCarriesIt() {
        let t = Self.remote
        for a in [t.chaptersArgs, t.chapterArgs("a"), t.searchArgs("x"), t.args("tasks")] {
            XCTAssertFalse(a.contains("--no-github"), "\(a)")
        }
    }

    func testARefusingHostGetsOneRetryWithoutTheFlag() async {
        let run = Run()
        run.statuses = [1, 0]
        await read(Self.remote, run)
        XCTAssertEqual(run.calls.count, 2)
        XCTAssertTrue(run.calls.first?.args.contains("--no-github") ?? false)
        XCTAssertFalse(run.calls.last?.args.contains("--no-github") ?? true)
        let again = Run()
        again.statuses = [1, 1, 1]
        await read(Self.remote, again)
        XCTAssertEqual(again.calls.count, 2, "once, never a loop")
    }

    func testNoRetryWithoutTheFlagOrOnAnotherExit() async {
        let local = Run()
        local.statuses = [1]
        await read(Self.local, local)
        XCTAssertEqual(local.calls.count, 1, "a local read sent no flag")
        let other = Run()
        other.statuses = [2]
        await read(Self.remote, other)
        XCTAssertEqual(other.calls.count, 1)
    }
}
