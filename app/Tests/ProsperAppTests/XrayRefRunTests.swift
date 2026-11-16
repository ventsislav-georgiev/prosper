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
        private var _cancelled = 0
        var answer: (status: Int32, out: Data) = (0, Data(XrayRefStreamTests.golden.joined(separator: "\n").utf8))
        var calls: [[String]] { lock.withLock { _calls } }
        var cancelled: Int { lock.withLock { _cancelled } }
        var run: XrayPanels.Run {
            { [self] _, args, _ in
                lock.withLock { _calls.append(args) }
                if args.contains("#1") {
                    let end = Date().addingTimeInterval(5)
                    while !Task.isCancelled, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
                    if Task.isCancelled { lock.withLock { _cancelled += 1 } }
                }
                return lock.withLock { answer }
            }
        }
    }

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
        XCTAssertEqual(run.calls, [["--xray", "api", "--ref", "#12", "--scope", "project", "--full", "--json"]])
        XCTAssertEqual(p.refContext?.ref, "#12")
        XCTAssertEqual(p.refContext?.heading, "Definition")
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
