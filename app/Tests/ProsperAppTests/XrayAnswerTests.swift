import XCTest
@testable import ProsperApp

/// #2024 (operator 2026-11-27; rulings OQ-210, OQ-211, OQ-214, OQ-215): the Questions tab answers an Open question
/// through `dch --xray <n> --answer <qid> - --json --notify <target>` (dch 1.189.0), the ruling on stdin, then re-reads
/// --questions at once. A fake runner (XrayPanels.Run) answers; no dch, no process, no window.
@MainActor
final class XrayAnswerTests: XCTestCase {

    nonisolated static let header = #"{"schema":1,"session":"api","source":"command","partial":false,"answer":true}"#
    nonisolated static let open = #"{"question":{"id":"OQ-7","title":"Which port?","status":"pending","label":"OPEN","options":["8080","9090"],"recommended":"9090","asker":"api-qa"}}"#
    nonisolated static let answered = #"{"question":{"id":"OQ-1","title":"Keep the flag?","status":"done","label":"ANSWERED","note":"Yes"}}"#
    nonisolated static let done = #"{"done":true,"count":2,"dropped":0}"#
    nonisolated static func out(header: String = header, rows: [String] = [open, answered]) -> Data {
        XrayPanelTasksTests.ndjson([header] + rows + [done])
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(args: [String], stdin: Data?)] = []
        let answer: (status: Int32, out: Data)
        init(_ answer: (status: Int32, out: Data)) { self.answer = answer }
        var calls: [(args: [String], stdin: Data?)] { lock.withLock { _calls } }
        func count(_ flag: String) -> Int { calls.filter { $0.args.contains(flag) }.count }
        var run: XrayPanels.Run {
            { [self] _, a, _ in
                let input = XrayPanels.stdin.get()
                lock.withLock { _calls.append((a, input)) }
                return a.contains("--answer") ? answer : (0, XrayAnswerTests.out())
            }
        }
    }

    override func setUp() {
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: XrayPanelModel.answerDch)
    }
    override func tearDown() { XrayPanels.probed = nil }

    func panel(_ target: XrayTarget = XrayChaptersTests.local, rec: Recorder? = nil, live: Set<String> = []) -> XrayPanelModel {
        let p = XrayPanelModel(target: target, tab: .questions)
        p.now = { XrayChaptersTests.base }
        p.takeQuestions((0, Self.out()))
        p.dch = "/fake/dch"
        p.run = rec?.run
        p.liveNames = { live }
        return p
    }

    func send(_ p: XrayPanelModel, _ text: String = "9090, as the proxy expects") async {
        guard let q = p.questions?.tasks.first(where: { $0.id == "OQ-7" }) else { return XCTFail("no open row") }
        p.openAnswer(q)
        p.answerText = text
        p.sendAnswer()
        await p.answerTask?.value
        await p.reading?.value
    }

    // MARK: parse

    /// Red at base: Row.T had no options / recommended / asker and Header no answer (XrayTasks.swift:95-110).
    func testAnswerFieldsParse() {
        let q = XrayTasks.parse(Self.out())
        XCTAssertTrue(q.answerable)
        let o = q.tasks.first { $0.id == "OQ-7" }
        XCTAssertEqual(o?.options, ["8080", "9090"])
        XCTAssertEqual(o?.recommended, "9090")
        XCTAssertEqual(o?.asker, "api-qa")
        let a = q.tasks.first { $0.id == "OQ-1" }
        XCTAssertEqual(a?.options, [], "an older dch sends none")
        XCTAssertTrue(a?.recommended == nil && a?.asker == nil)
        XCTAssertFalse(XrayTasks.parse(Self.out(header: #"{"schema":1,"source":"command","answer":false}"#)).answerable)
        XCTAssertFalse(XrayTasks.parse(Self.out(header: #"{"schema":1,"source":"command"}"#)).answerable, "absent: off")
    }

    func testOversizedFieldsAreBounded() {
        let ten = (0..<10).map { "\"o\($0)\"" }.joined(separator: ",")
        let long = String(repeating: "x", count: 400), asker = String(repeating: "a", count: 65)
        let row = #"{"question":{"id":"OQ-9","title":"t","status":"pending","options":[\#(ten)],"recommended":"\#(long)","asker":"\#(asker)"}}"#
        let t = XrayTasks.parse(Self.out(rows: [row])).tasks.first
        XCTAssertEqual(t?.options.count, 8, "at most 8")
        XCTAssertEqual(t?.recommended?.count, 300, "cut at 300 visible characters")
        XCTAssertTrue(t?.asker == nil, "an asker over 64 bytes is dropped, never cut into another name")
    }

    // MARK: the gate

    /// The button needs both the header's answer:true and a dch at 1.189.0, and only on Open rows.
    func testTheButtonNeedsTheHeaderAndTheDch() {
        let p = panel()
        XCTAssertTrue(p.answerShown)
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 188, 9])
        XCTAssertFalse(p.answerShown, "an older dch does not know --answer")
        XrayPanels.probed = nil
        XCTAssertFalse(p.answerShown, "no probe yet")
        XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: XrayPanelModel.answerDch)
        p.takeQuestions((0, Self.out(header: #"{"schema":1,"source":"command"}"#)))
        XCTAssertFalse(p.answerShown, "no answer_command where the read ran")
        p.takeQuestions((0, Self.out()))
        let rows = p.questions?.tasks ?? []
        XCTAssertEqual(rows.filter(XrayPanelModel.isOpen).map(\.id), ["OQ-7"])
        if let answered = rows.first(where: { $0.id == "OQ-1" }) { p.openAnswer(answered) }
        XCTAssertTrue(p.answerQuestion == nil, "no editor on an Answered row")
    }

    // MARK: the run

    /// The argv exactly, the ruling (trimmed) on stdin, never in argv.
    func testSendRunsTheAnswerFormWithTheRulingOnStdin() async {
        let rec = Recorder((0, Data(#"{"answered":true,"id":"OQ-7","told":{"session":"api-qa","via":"native","ok":true}}"#.utf8)))
        let p = panel(rec: rec, live: ["api", "api-qa"])
        await send(p, "  9090, as the proxy expects\n")
        let call = rec.calls.first { $0.args.contains("--answer") }
        XCTAssertEqual(call?.args, ["--xray", "api", "--answer", "OQ-7", "-", "--json", "--notify", "api-qa"])
        XCTAssertEqual(call?.stdin, Data("9090, as the proxy expects".utf8))
        XCTAssertEqual(rec.count("--answer"), 1, "one dch per Send")
    }

    /// Design 3 "Who": the asker when live next to the drawer, else the drawer's own session; host:asker on a remote host.
    func testTheNotifyTarget() {
        let local = XrayChaptersTests.local, remote = XrayTarget(name: "box:api", dir: nil)
        XCTAssertEqual(XrayPanelModel.notifyTarget(asker: "api-qa", drawer: local, live: ["api", "api-qa"]), "api-qa")
        XCTAssertEqual(XrayPanelModel.notifyTarget(asker: "api-qa", drawer: local, live: ["api"]), "api", "the asker ended")
        XCTAssertEqual(XrayPanelModel.notifyTarget(asker: nil, drawer: local, live: ["api"]), "api")
        XCTAssertEqual(XrayPanelModel.notifyTarget(asker: "-k", drawer: local, live: ["-k"]), "api", "never a flag")
        XCTAssertEqual(XrayPanelModel.notifyTarget(asker: "api-qa", drawer: remote, live: ["api", "api-qa"]), "box:api-qa")
        XCTAssertEqual(XrayPanelModel.notifyTarget(asker: "api-qa", drawer: remote, live: []), "box:api")
    }

    /// The asker gone: the drawer's session is told; on a remote drawer the argv names the host's sessions.
    func testSendFallsBackToTheDrawerAndKeepsTheHost() async {
        let ok = Data(#"{"answered":true,"id":"OQ-7"}"#.utf8)
        let rec = Recorder((0, ok)), p = panel(rec: rec, live: ["api"])
        await send(p)
        XCTAssertEqual(rec.calls.first { $0.args.contains("--answer") }?.args.last, "api")
        let rrec = Recorder((0, ok)), r = panel(XrayTarget(name: "box:api", dir: nil), rec: rrec, live: ["api-qa"])
        await send(r)
        XCTAssertEqual(rrec.calls.first { $0.args.contains("--answer") }?.args,
                       ["--xray", "box:api", "--answer", "OQ-7", "-", "--json", "--notify", "box:api-qa"])
    }

    /// Success: the editor closes, the told line shows for 6 s (the poller's ticker clears it), --questions is read at once.
    func testSuccessTellsAndRereadsAtOnce() async {
        let rec = Recorder((0, Data(#"{"answered":true,"id":"OQ-7","told":{"session":"api-qa","via":"native","ok":true}}"#.utf8)))
        let p = panel(rec: rec, live: ["api-qa"])
        await send(p)
        XCTAssertEqual(rec.count("--questions"), 1, "the re-read, at once")
        XCTAssertEqual(p.lastRead, XrayChaptersTests.base, "it stands in for the next poll")
        XCTAssertTrue(p.answerQuestion == nil)
        XCTAssertEqual(p.answerText, "")
        XCTAssertEqual(p.answerLine, "Told api-qa")
        XCTAssertEqual(p.answerLineUntil, XrayChaptersTests.base + 6)
        p.paneState = { (true, true) }
        p.now = { XrayChaptersTests.base + 6 }
        p.tick()
        XCTAssertTrue(p.answerLine == nil, "gone after 6 s")
        p.stop()
    }

    func testToldLines() {
        typealias T = XrayAnswerResult.Told
        XCTAssertEqual(XrayPanelModel.toldLine(T(session: "api-qa", via: "say", ok: true, why: nil), notify: "api-qa"), "Told api-qa")
        XCTAssertEqual(XrayPanelModel.toldLine(T(session: "api-qa", via: "say", ok: false, why: "skipped prompt"), notify: "api-qa"),
                       "Ruled; api-qa not told (skipped prompt): it reads the ledger on its next heartbeat")
        XCTAssertEqual(XrayPanelModel.toldLine(nil, notify: "api"),
                       "Ruled; api not told (dch said nothing): it reads the ledger on its next heartbeat")
    }

    /// Design 1.3: each exit's line; the editor keeps its text on every failure.
    func testEachExitsLine() async {
        func line(_ status: Int32, _ out: String = "", remote: Bool = false) async -> (String?, String, Bool) {
            let rec = Recorder((status, Data(out.utf8)))
            let p = panel(remote ? XrayTarget(name: "box:api", dir: nil) : XrayChaptersTests.local, rec: rec)
            await send(p, "keep me")
            return (p.answerLine, p.answerText, p.questions?.answerable ?? false)
        }
        var r = await line(5, #"{"answered":false,"id":"OQ-7","why":"not_open"}"#)
        XCTAssertEqual(r.0, "Already answered elsewhere: not sent")
        XCTAssertEqual(r.1, "keep me")
        r = await line(5, #"{"answered":false,"id":"OQ-7","why":"no_question"}"#)
        XCTAssertEqual(r.0, "No such question any more")
        r = await line(1, #"{"answered":false,"why":"no_command"}"#)
        XCTAssertEqual(r.0, "Answering is off: no answer_command on this Mac")
        XCTAssertFalse(r.2, "the Answer buttons go")
        r = await line(1, #"{"answered":false,"why":"no_command"}"#, remote: true)
        XCTAssertEqual(r.0, "Answering is off: no answer_command on box")
        r = await line(1, remote: true)
        XCTAssertEqual(r.0, "The host's dch cannot answer (too old or --allow-answer off)")
        r = await line(3, #"{"answered":false,"why":"failed","detail":"todo.py: locked"}"#)
        XCTAssertEqual(r.0, "Not answered: todo.py: locked")
        r = await line(4, remote: true)
        XCTAssertEqual(r.0, "Host unreachable: not answered")
        r = await line(7, remote: true)
        XCTAssertEqual(r.0, "Host unreachable: not answered")
        r = await line(2)
        XCTAssertEqual(r.0, "Not answered: dch refused the text")
        XCTAssertEqual(r.1, "keep me")
    }

    /// Exit 5 re-reads too: the row moves to Answered and Send stays off on it.
    func testNotOpenRereadsAndSendGoesOff() async {
        let p = panel()
        p.run = { _, a, _ in a.contains("--answer") ? (5, Data(#"{"answered":false,"why":"not_open"}"#.utf8))
            : (0, XrayAnswerTests.out(rows: [XrayAnswerTests.open.replacingOccurrences(of: #""status":"pending""#, with: #""status":"done""#)])) }
        await send(p, "keep me")
        XCTAssertEqual(p.answerQuestion?.id, "OQ-7", "the editor stays on the moved row")
        XCTAssertEqual(p.answerRow?.status, .done)
        XCTAssertFalse(p.canSend)
    }

    // MARK: the editor

    func testChipsPutTheRecommendationFirstAndAClickReplacesTheText() {
        let p = panel()
        guard let q = p.questions?.tasks.first(where: { $0.id == "OQ-7" }) else { return XCTFail("no row") }
        let chips = XrayAnswerChip.of(q)
        XCTAssertEqual(chips.map(\.text), ["9090", "8080"], "the recommendation first, not repeated")
        XCTAssertEqual(chips.map(\.recommended), [true, false])
        p.openAnswer(q)
        p.answerText = "something else"
        if let c = chips.last { p.pick(c) }
        XCTAssertEqual(p.answerText, "8080")
        let long = XrayAnswerChip(id: 0, text: String(repeating: "y", count: 90), recommended: false)
        XCTAssertEqual(long.shown.count, 60, "60 visible characters; the whole text is its value")
    }

    /// Design 4: 1 to 4000 bytes after trimming, LF and tab kept, any other unseen scalar (NUL) refused.
    func testTheFieldCheck() {
        XCTAssertEqual(XrayPanelModel.answerCheck("  \n "), "")
        XCTAssertTrue(XrayPanelModel.answerCheck("one\n\ttwo") == nil)
        XCTAssertEqual(XrayPanelModel.answerCheck("a\u{0}b"), "The answer has a hidden character")
        XCTAssertTrue(XrayPanelModel.answerCheck(String(repeating: "z", count: 4000)) == nil)
        XCTAssertEqual(XrayPanelModel.answerCheck(String(repeating: "z", count: 4001)), "The answer is 4001 bytes: at most 4000")
        let p = panel()
        if let q = p.questions?.tasks.first(where: { $0.id == "OQ-7" }) { p.openAnswer(q) }
        p.answerText = "   "
        XCTAssertFalse(p.canSend, "trimmed empty: Send off")
        p.answerText = "9090"
        XCTAssertTrue(p.canSend)
        XCTAssertFalse(XrayPanelModel.qidOK("-k"))
        XCTAssertFalse(XrayPanelModel.qidOK("OQ 7"))
        XCTAssertTrue(XrayPanelModel.qidOK("OQ-7"))
    }

    /// Design 4.1: agents cannot drive this through Prosper: no ctl command answers.
    func testNoCtlCommandAnswers() {
        let names = ControlRegistry.standard().commands.keys
        XCTAssertFalse(names.isEmpty)
        XCTAssertEqual(names.filter { $0.lowercased().contains("answer") }, [])
    }
}
