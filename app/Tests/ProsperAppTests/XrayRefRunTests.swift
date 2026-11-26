import XCTest
@testable import ProsperApp

/// #1416 (#1356 step 2): the --ref runner (XrayPanels.runRef) through a fake XrayPanels.Run that records each argv and
/// each cancel. A private XrayPanels, never the shared one. No dch, no process, no window shown.
@MainActor
final class XrayRefRunTests: XCTestCase {
    static let local = XrayTarget(name: "api", dir: "/tmp/dch-test")

    /// The fake dch: the ref "#1" waits until its read is cancelled (at most 5 s), counts that, then answers; any other
    /// argv answers at once with `answer` (default: the golden-shaped stream).
    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        private var _stdins: [String?] = []   // #1410: XrayPanels.stdin per call, nil when none was bound
        private var _cancelled = 0
        var answer: (status: Int32, out: Data) = (0, Data(XrayRefStreamTests.golden.joined(separator: "\n").utf8))
        var calls: [[String]] { lock.withLock { _calls } }
        var stdins: [String?] { lock.withLock { _stdins } }
        var cancelled: Int { lock.withLock { _cancelled } }
        var run: XrayPanels.Run {
            { [self] _, args, _ in
                let input = XrayPanels.stdin.get().map { String(decoding: $0, as: UTF8.self) }
                lock.withLock { _calls.append(args); _stdins.append(input) }
                if args.contains("#1") || input == "#1\n" {
                    let end = Date().addingTimeInterval(5)
                    while !Task.isCancelled, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
                    if Task.isCancelled { lock.withLock { _cancelled += 1 } }
                }
                return lock.withLock { answer }
            }
        }
    }

    override func setUp() { XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 84, 0]) }   // #1443: stdin needs 1.84.0
    override func tearDown() { XrayPanels.probed = nil }

    func panel(_ run: Run) -> XrayPanelModel {
        let p = XrayPanelModel(target: Self.local, tab: .search)
        (p.dch, p.run) = ("/fake/dch", run.run)
        return p
    }

    /// Waits (at most 5 s) until the fake has seen `n` calls.
    func called(_ run: Run, _ n: Int) async {
        let end = Date().addingTimeInterval(5)
        while run.calls.count < n, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    func testExactArgvAndTheContextLands() async {
        let run = Run(), panels = XrayPanels(), p = panel(run)
        XCTAssertTrue(panels.runRef("#12", for: p))
        await panels.refReading?.value
        XCTAssertEqual(run.calls, [["--xray", "api", "--ref", "-", "--scope", "project", "--full", "--json"]], "#1410: no text in argv")
        XCTAssertEqual(run.stdins, ["#12\n"], "#1410: the text and one newline on stdin")
        XCTAssertEqual(p.refContext?.ref, "#12")
        XCTAssertEqual(p.refContext?.heading, "Definition")
    }

    /// #1442: dch 1.84.0 reads stdin for every local name: one with ":" sends "-" in argv and the text plus a newline on
    /// stdin, for a ref and for a search (red with the colon test back).
    func testALocalNameWithAColonTakesStdin() async {
        let run = Run(), panels = XrayPanels()
        let p = XrayPanelModel(target: XrayTarget(name: "api:2", dir: "/tmp/dch-test"), tab: .search)
        (p.dch, p.run) = ("/fake/dch", run.run)
        XCTAssertTrue(panels.runRef("#12", for: p))
        await panels.refReading?.value
        XCTAssertEqual(run.calls, [["--xray", "api:2", "--ref", "-", "--scope", "project", "--full", "--json"]])
        XCTAssertEqual(run.stdins.last, "#12\n")
        p.query = "login"
        p.runSearch()
        await p.reading?.value
        XCTAssertEqual(run.calls.last, ["--xray", "api:2", "--search", "-", "--json"])
        XCTAssertEqual(run.stdins.last, "login\n")
    }

    /// #1443: a probed dch below 1.84.0 (1.82.0) or none probed (nil) reads "-" as the text: a local name keeps the text in
    /// argv and binds no stdin, for a ref and a search; 1.84.0 sends "-" plus stdin (red with the version ignored, or with
    /// an unknown version on stdin).
    func testAnOlderOrUnknownDchGetsTheTextInArgv() async {
        let versions: [[Int]?] = [[1, 82, 0], nil]
        for v in versions {
            XrayPanels.probed = v.map { DchCommand.Binary(path: "/fake/dch", version: $0) }
            let run = Run(), panels = XrayPanels(), p = panel(run)
            XCTAssertTrue(panels.runRef("#12", for: p))
            await panels.refReading?.value
            XCTAssertEqual(run.calls, [["--xray", "api", "--ref", "#12", "--scope", "project", "--full", "--json"]], "\(String(describing: v))")
            XCTAssertTrue(run.stdins.last == .some(nil), "no stdin for a ref")
            p.query = "login"
            p.runSearch()
            await p.reading?.value
            XCTAssertEqual(run.calls.last, ["--xray", "api", "--search", "login", "--json"])
            XCTAssertTrue(run.stdins.last == .some(nil), "no stdin for a search")
        }
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 84, 0])
        let run = Run(), panels = XrayPanels(), p = panel(run)
        XCTAssertTrue(panels.runRef("#12", for: p))
        await panels.refReading?.value
        XCTAssertEqual(run.calls.last, ["--xray", "api", "--ref", "-", "--scope", "project", "--full", "--json"])
        XCTAssertEqual(run.stdins.last, "#12\n")
    }

    /// #1410: dch reads at most 256 stdin bytes, newline included. A local 255-byte text runs, 256 runs nothing (red with
    /// the 255 cap gone); a remote 256-byte text keeps argv and no stdin (red with stdin for a remote name).
    func testALocalRefOver255BytesSpawnsNothingARemoteOneKeepsArgv() async {
        let run = Run(), panels = XrayPanels(), p = panel(run)
        let t255 = String(repeating: "a", count: 255), t256 = String(repeating: "a", count: 256)
        XCTAssertTrue(panels.runRef(t255, for: p))
        await panels.refReading?.value
        XCTAssertEqual(run.stdins, [t255 + "\n"])
        XCTAssertFalse(panels.runRef(t256, for: p), "256 + newline is over dch's cap")
        XCTAssertEqual(run.calls.count, 1, "nothing spawned for 256")
        let remote = XrayPanelModel(target: XrayTarget(name: "example-host:api", dir: nil), tab: .search)
        (remote.dch, remote.run) = ("/fake/dch", run.run)
        XCTAssertTrue(panels.runRef(t256, for: remote))
        await panels.refReading?.value
        XCTAssertEqual(run.calls.count, 2)
        XCTAssertEqual(run.calls.last, ["--xray", "example-host:api", "--ref", t256, "--scope", "project", "--full", "--json"])
        XCTAssertTrue(run.stdins.last == .some(nil), "a remote ref binds no stdin")
    }

    /// Red with M2c (refOK skipped): a bidi text spawns nothing; "-x" (a flag to dch) and an empty text neither.
    func testDashBidiAndEmptyTextsSpawnNothing() async {
        let run = Run(), panels = XrayPanels(), p = panel(run)
        for t in ["-x", "a\u{202E}b", "", "a\u{0007}"] { XCTAssertFalse(panels.runRef(t, for: p), t) }
        XCTAssertTrue(panels.refReading == nil)
        XCTAssertEqual(run.calls.count, 0)
    }

    /// Red with M2b (no cancel before a new read): the first read is cancelled and its answer never lands.
    func testASecondOpenCancelsTheFirst() async {
        let run = Run(), panels = XrayPanels(), p = panel(run)
        panels.runRef("#1", for: p)
        let first = panels.refReading
        await called(run, 1)
        panels.runRef("#12", for: p)
        await panels.refReading?.value
        await first?.value
        XCTAssertEqual(run.cancelled, 1)
        XCTAssertEqual(run.calls.count, 2)
        XCTAssertEqual(p.refContext?.ref, "#12")
    }

    func testCardCloseCancels() async {
        let run = Run(), panels = XrayPanels(), p = panel(run)
        panels.runRef("#1", for: p)
        let first = panels.refReading
        await called(run, 1)
        panels.closeRef()
        await first?.value
        XCTAssertEqual(run.cancelled, 1)
        XCTAssertTrue(panels.refReading == nil)
        XCTAssertTrue(p.refContext == nil)
    }

    /// #1991 (dch 1.174.0): exit 1 after a read that answered none with a Codex rollout reason says it after the
    /// no-corpus words, as dch's stderr does; reason null keeps the plain words. Red with the reason dropped.
    func testExitOneSaysTheCodexRolloutReason() async {
        for (reason, note) in [("compressed", "No X-ray history for this session: the Codex rollout is compressed"),
                               ("corrupt", "No X-ray history for this session: the Codex rollout is corrupt"),
                               ("", XrayPanelModel.refNoCorpus)] {
            let run = Run(), panels = XrayPanels(), p = panel(run)
            p.corpus = XrayChapters.corpus(["schema": 1, "corpus": "none", "reason": reason])
            run.answer = (1, Data())
            panels.runRef("#12", for: p)
            await panels.refReading?.value
            XCTAssertEqual(p.refNote, note, reason)
        }
    }

    func testExitCodesSayWhy() async {
        let cases: [(Int32, String)] = [(1, XrayPanelModel.refNoCorpus), (2, XrayPanelModel.refNotARef), (4, "host unreachable"),
                                        (7, "host unreachable"), (3, XrayPanelModel.refFailed), (XrayPanels.overCap, XrayPanelModel.refFailed)]
        for (status, note) in cases {
            let run = Run(), panels = XrayPanels(), p = panel(run)
            run.answer = (status, Data())
            panels.runRef("#12", for: p)
            await panels.refReading?.value
            XCTAssertEqual(p.refNote, note, "exit \(status)")
            XCTAssertTrue(p.refContext == nil)
        }
    }
}
