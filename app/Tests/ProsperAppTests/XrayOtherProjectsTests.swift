import XCTest
@testable import ProsperApp

/// #1560 (X-ray plan C2): the ref card's "Other projects (N)" row. A fake XrayPanels.Run records each argv and each
/// cancel (a `--scope all` read waits until cancelled when `holdAll` is set); a fake presenter runs the card's close as
/// XrayPopoverPresenter does (XrayRefPopoverTests.Cards). A private XrayPanels; no dch, no process, no window shown.
@MainActor
final class XrayOtherProjectsTests: XCTestCase {
    override func setUp() { XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 84, 0]) }   // stdin needs 1.84.0
    override func tearDown() { XrayPanels.probed = nil }
    typealias T = XrayRefStreamTests

    /// What `--scope all` adds: one mention from "web" in another project dir, and done's all counts.
    static let webMention = #"{"schema":1,"mention":{"session":"web","chapter":null,"at":1794304900,"line":"also #12 here","offset":10,"live":false,"project":"-Users-example-web"}}"#
    static let webTally = #"{"schema":1,"tally":{"session":"web","live":false,"project":"-Users-example-web","count":1,"definitions":0,"partial":false,"mentions_dropped":0}}"#
    static let allDone = #"{"schema":1,"done":true,"partial":false,"counts":{"session":2,"project":3,"project_sessions":1,"all":1,"all_sessions":1},"why":null,"files":3,"bytes":23000,"lines_too_long":0}"#
    static var all: [String] { [T.first, T.mention0, T.definition, T.mention1, T.tally, webMention, webTally, allDone] }

    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        private var _stdins: [String?] = []
        private var _cancelled = 0
        var holdAll = false
        var answer: (status: Int32, out: Data) = (0, Data(XrayRefStreamTests.golden.joined(separator: "\n").utf8))
        var calls: [[String]] { lock.withLock { _calls } }
        var stdins: [String?] { lock.withLock { _stdins } }
        var cancelled: Int { lock.withLock { _cancelled } }
        var run: XrayPanels.Run {
            { [self] _, args, _ in
                let input = XrayPanels.stdin.get().map { String(decoding: $0, as: UTF8.self) }
                lock.withLock { _calls.append(args); _stdins.append(input) }
                if lock.withLock({ holdAll }), args.contains("all") {
                    let end = Date().addingTimeInterval(5)
                    while !Task.isCancelled, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
                    if Task.isCancelled { lock.withLock { _cancelled += 1 } }
                }
                return lock.withLock { answer }
            }
        }
    }

    func refs(other: Int) throws -> XrayRefs {
        let base = String(decoding: XrayRefsParseTests.object(refs: XrayRefPopoverTests.refs), as: UTF8.self)
        let o = base.replacingOccurrences(of: #""dropped_keys":0}"#, with: #""dropped_keys":0,"other_projects":\#(other)}"#)
        return try XCTUnwrap(XrayRefs.parse(Data(o.utf8)))
    }

    func panel(_ run: Run, _ cards: XrayRefPopoverTests.Cards, _ panels: XrayPanels, other: Int = 3) throws -> XrayPanelModel {
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .refs)
        (p.dch, p.run, p.panels, p.home) = ("/fake/dch", run.run, panels, "/Users/example")
        p.refs = try refs(other: other)
        p.presentRef = { cards.present($0, $1, $2) }
        p.dismiss = { cards.close() }
        return p
    }

    func entry(_ p: XrayPanelModel, _ text: String) throws -> XrayRefs.Entry {
        try XCTUnwrap(p.refs?.entries.first { $0.text == text })
    }

    func called(_ run: Run, _ n: Int) async {
        let end = Date().addingTimeInterval(5)
        while run.calls.count < n, Date() < end { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    /// other_projects 0 (or no snapshot) gives no row; 3 gives "Other projects (3)" (red with the > 0 check gone).
    func testRowOnlyWhenOtherProjectsIsPositive() throws {
        let run = Run(), cards = XrayRefPopoverTests.Cards(), panels = XrayPanels()
        XCTAssertTrue(XrayRefPopover.othersTitle(try panel(run, cards, panels, other: 0)) == nil)
        XCTAssertEqual(XrayRefPopover.othersTitle(try panel(run, cards, panels, other: 3)), "Other projects (3)")
        let none = try panel(run, cards, panels)
        none.refs = nil
        XCTAssertTrue(XrayRefPopover.othersTitle(none) == nil)
    }

    /// Opening the row runs `--ref - --scope all --full --json` once, the ref on stdin, after the card's own read
    /// landed; the context keeps its own groups and gains "web" and the All projects line (red with project scope sent,
    /// with the context replaced, or with a second open running again).
    func testOpeningRunsScopeAllOnceAndAddsTheOtherGroups() async throws {
        let run = Run(), cards = XrayRefPopoverTests.Cards(), panels = XrayPanels(), p = try panel(run, cards, panels)
        p.openRef(try entry(p, "#12"))
        XCTAssertFalse(p.openOthers(), "nothing runs before the card's own read lands")
        await panels.refReading?.value
        XCTAssertEqual(run.calls.count, 1)
        run.answer = (0, Data(Self.all.joined(separator: "\n").utf8))
        XCTAssertTrue(p.openOthers())
        XCTAssertEqual(p.refContext?.heading, "Definition", "the card's context stays while the read runs")
        await panels.refReading?.value
        XCTAssertEqual(run.calls.last, ["--xray", "api", "--ref", "-", "--scope", "all", "--full", "--json"])
        XCTAssertEqual(run.stdins.last, "#12\n")
        let c = try XCTUnwrap(p.refContext)
        XCTAssertEqual(c.groups.map(\.session), ["api"])
        XCTAssertEqual(c.others?.map(\.session), ["web"])
        XCTAssertEqual(c.others?.first?.mentions.map(\.line), ["also #12 here"])
        XCTAssertEqual(c.othersCount, "All projects 1 in 1 other sessions")
        XCTAssertEqual(c.definitions.count, 1)
        XCTAssertEqual(XrayRefPopover.count(.mentions, p), 2, "the tab counts this project's mentions")
        XCTAssertFalse(p.openOthers(), "once: the groups are in")
        XCTAssertEqual(run.calls.count, 2)
    }

    /// The card's close cancels the Other projects read (the product runner SIGTERMs its dch); its answer never lands
    /// (red with the close comparing the card's first read alone).
    func testCardCloseCancelsTheOtherProjectsRead() async throws {
        let run = Run(), cards = XrayRefPopoverTests.Cards(), panels = XrayPanels(), p = try panel(run, cards, panels)
        p.openRef(try entry(p, "#12"))
        await panels.refReading?.value
        run.holdAll = true
        XCTAssertTrue(p.openOthers())
        let others = panels.refReading
        await called(run, 2)
        cards.close()
        await others?.value
        XCTAssertEqual(run.cancelled, 1)
        XCTAssertTrue(panels.refReading == nil)
        XCTAssertTrue(p.refContext?.others == nil)
    }

    /// A failed `--scope all` read says so and keeps the card's own context.
    func testAFailedReadKeepsTheCard() async throws {
        let run = Run(), cards = XrayRefPopoverTests.Cards(), panels = XrayPanels(), p = try panel(run, cards, panels)
        p.openRef(try entry(p, "#12"))
        await panels.refReading?.value
        run.answer = (3, Data())
        XCTAssertTrue(p.openOthers())
        await panels.refReading?.value
        XCTAssertEqual(p.refNote, XrayPanelModel.refFailed)
        XCTAssertEqual(p.refContext?.definitions.count, 1)
        XCTAssertTrue(p.refContext?.others == nil)
    }
}
