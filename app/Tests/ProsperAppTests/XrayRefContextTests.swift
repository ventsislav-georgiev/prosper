import XCTest
@testable import ProsperApp

/// #1416 (#1356 step 2): XrayRefContext, the ref card's data, from literal fake NDJSON and the panel's cached Tasks and
/// Memory; Open, Search and a mention's jump through seams. No dch, no window, no pasteboard, no URL opened.
@MainActor
final class XrayRefContextTests: XCTestCase {
    override func setUp() { XrayPanels.probed = DchCommand.Binary(path: "/fake/dch", version: [1, 84, 0]) }   // #1443: stdin needs 1.84.0
    override func tearDown() { XrayPanels.probed = nil }
    typealias T = XrayRefStreamTests

    static func def(_ title: String, at: Int, session: String = "api") -> String {
        #"{"schema":1,"definition":{"session":""# + session + #"","live":false,"project":"-Users-example-acme","at":"# + "\(at)"
            + #","title":""# + title + #"","passage":"p","rule":"D1","offset":1,"chapter":null}}"#
    }

    static func mention(_ session: String, at: Int, offset: Int, chapter: String? = nil) -> String {
        #"{"schema":1,"mention":{"session":""# + session + #"","chapter":"# + (chapter.map { "\"\($0)\"" } ?? "null")
            + #","at":"# + "\(at),\"line\":\"\(session) \(at)\",\"offset\":\(offset),\"live\":false}}"
    }

    static func task(_ id: String, title: String, note: String? = nil, label: String = "pending") -> XrayTasks.Task {
        XrayTasks.Task(id: id, title: title, status: .pending, label: label, active: nil, note: note, created: nil, updated: nil,
                       chapter: nil, createdChapter: nil, blockedBy: [], url: nil, rawURL: nil, group: nil)
    }

    static func item(_ id: String, title: String, note: String? = nil, body: String? = nil) -> XrayMemory.Item {
        XrayMemory.Item(id: id, title: title, note: note, kind: .project, kindWord: "project", scope: .user, scopeWord: "user",
                        updated: nil, path: "/Users/example/\(id).md", session: nil, sessionWord: nil, chapter: nil, body: body, cut: false)
    }

    func testDefinitionsNewestFirstWithTheDistinctTitleCount() {
        let s = T.parse([T.first, Self.def("Old name", at: 100), Self.def("Login retries", at: 300), Self.def("Old name", at: 200), T.done])
        let c = XrayRefContext(s, ref: "#12", tasks: nil, memory: nil)
        XCTAssertEqual(c.definitions.map(\.at), [300.0, 200, 100].map { Optional(Date(timeIntervalSince1970: $0)) })
        XCTAssertEqual(c.heading, "2 definitions")
        XCTAssertEqual(XrayRefContext(T.parse([T.first, Self.def("A", at: 1), Self.def("A", at: 2), T.done]), ref: "#12",
                                      tasks: nil, memory: nil).heading, "Definition")
    }

    func testNoDefinitionSaysDefineWarnElseTheFirstMention() {
        let warn = #"{"schema":1,"done":true,"partial":false,"counts":{"session":1,"project":0,"project_sessions":0},"why":null,"define_warn":"define_command: exit 3: no such entry"}"#
        let w = XrayRefContext(T.parse([T.first, T.mention0, warn]), ref: "#12", tasks: nil, memory: nil)
        XCTAssertEqual(w.heading, "No definition found: define_command: exit 3: no such entry")
        XCTAssertTrue(w.firstMention == nil)
        let m = XrayRefContext(T.parse([T.first, T.mention1, T.mention0, T.done]), ref: "#12", tasks: nil, memory: nil)
        XCTAssertEqual(m.heading, "First mention")
        XCTAssertEqual(m.firstMention?.line, "Work on #12 please")
        XCTAssertEqual(XrayRefContext(T.parse([T.first, T.done]), ref: "#12", tasks: nil, memory: nil).heading, "No definition found")
    }

    /// Red with M2d (memory filter ignores body): a ref in a memory's body alone matches; another ref's text does not.
    func testTasksAndMemoryCrossFilter() {
        let tasks = XrayTasks(schema: 1, source: "claude", sessionTitle: nil, partial: false, headerWarn: nil, doneWarn: nil,
                              droppedCount: 0, skippedLines: 0,
                              tasks: [Self.task("1", title: "Fix login", note: "see #12 for the retries"),
                                      Self.task("2", title: "Ship PROJ-7"), Self.task("3", title: "Docs", label: "#12 follow-up")])
        let memory = XrayMemory(source: "claude", title: nil, partial: false, headerWarn: nil, doneWarn: nil, droppedCount: 0,
                                skippedLines: 0,
                                items: [Self.item("m1", title: "Retries", body: "Login retries twice (#12)."),
                                        Self.item("m2", title: "PROJ-7 notes", note: "about PROJ-7"),
                                        Self.item("m3", title: "Login", note: "Tracked in #12")])
        let c = XrayRefContext(T.parse(T.golden), ref: "#12", tasks: tasks, memory: memory)
        XCTAssertEqual(c.tasks.map(\.id), ["1", "3"])
        XCTAssertEqual(c.memory.map(\.id), ["m1", "m3"])
        let lower = XrayRefContext(T.parse(T.golden), ref: "proj-7", tasks: tasks, memory: memory)
        XCTAssertEqual(lower.tasks.map(\.id), ["2"], "case-insensitive")
        XCTAssertEqual(lower.memory.map(\.id), ["m2"])
    }

    func testMentionsThisSessionInFileOrderThenOtherSessionsNewestFirst() {
        let lines = [T.first, Self.mention("api", at: 50, offset: 900, chapter: "f12:900"), Self.mention("api-qa", at: 10, offset: 1),
                     Self.mention("api", at: 40, offset: 100, chapter: "f12:100"), Self.mention("web", at: 30, offset: 1),
                     Self.mention("api-qa", at: 60, offset: 2), T.done]
        let c = XrayRefContext(T.parse(lines), ref: "#12", tasks: nil, memory: nil)
        XCTAssertEqual(c.groups.map(\.session), ["api", "api-qa", "web"])
        XCTAssertEqual(c.groups.first?.mentions.map(\.offset), [100, 900])
        XCTAssertEqual(c.groups.dropFirst().first?.mentions.map(\.at), [60.0, 10].map { Optional(Date(timeIntervalSince1970: $0)) })
    }

    func testOpenOnlyForAnHttpUrlRef() {
        XCTAssertEqual(XrayRefContext.openable("https://example.com/acme/api/pull/12", shape: .url)?.host, "example.com")
        XCTAssertTrue(XrayRefContext.openable("javascript:void(0)", shape: .url) == nil)
        XCTAssertTrue(XrayRefContext.openable("file:///Users/example/acme/a.swift", shape: .url) == nil)
        XCTAssertTrue(XrayRefContext.openable("https://example.com/x", shape: .file) == nil)
        XCTAssertTrue(XrayRefContext.openable("/Users/example/acme/a.swift", shape: .file) == nil, "OQ-164 Q3: Copy only")
        XCTAssertTrue(XrayRefContext(T.parse(T.golden), ref: "#12", tasks: nil, memory: nil).openURL == nil)
    }

    func testSearchNotRunForAOneByteOrBadText() async {
        let run = XrayRefRunTests.Run()
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .search)
        (p.dch, p.run) = ("/fake/dch", run.run)
        p.query = "kept"
        p.searchRef("#")
        p.searchRef("a\u{202E}b")
        XCTAssertTrue(p.reading == nil)
        XCTAssertEqual(p.query, "kept")
        p.searchRef("#12")
        await p.reading?.value
        XCTAssertEqual(p.query, "#12")
        XCTAssertEqual(run.calls, [["--xray", "api", "--search", "-", "--json"]])
        XCTAssertEqual(run.stdins, ["#12\n"], "#1410: the query on stdin")
    }

    /// Red with M2f (the session check dropped): another session's mention never jumps, even with a chapter.
    func testOnlyThisSessionsMentionJumps() {
        let lines = [T.first, Self.mention("api", at: 40, offset: 100, chapter: "f12:100"),
                     Self.mention("api-qa", at: 60, offset: 2, chapter: "f9:10"), Self.mention("api-qa", at: 61, offset: 3), T.done]
        let c = XrayRefContext(T.parse(lines), ref: "#12", tasks: nil, memory: nil)
        let p = XrayPanelModel(target: XrayRefRunTests.local, tab: .search)
        let other = c.groups.dropFirst().first?.mentions ?? []
        XCTAssertEqual(other.count, 2)
        for m in other { XCTAssertFalse(p.jumpRef(m, in: c)) }
        if let mine = c.groups.first?.mentions.first { XCTAssertTrue(p.jumpRef(mine, in: c)) } else { XCTFail("no own mention") }
    }
}
