import AppKit
import XCTest
@testable import ProsperApp

/// #1109 (design #1105 D13, D14; riders R7, R8, R9; OQ-118 Q2, Q3). Offscreen only: no login shell is run (the
/// probe is a closure), no dch is run (the gate, the spawn and the session's end are seams), windows are built
/// through the `build` seam and never shown; files are fakes in a tempDir().
@MainActor
final class TerminalEditorTests: XCTestCase {

    // MARK: Fakes

    /// A login shell and a dch that only count and answer.
    final class FakeShell: @unchecked Sendable {
        private let lock = NSLock()
        private var _probes: [String] = [], _gates = 0
        var vars: [String: String?] = ["VISUAL": "", "EDITOR": "nvim"]
        var gateAnswer = DchCommand.Gate.ok("/opt/example/bin/dch")
        var onPATH: Set<String> = ["/opt/example/bin/nvim", "/usr/bin/vi"]
        var loginPATH: String? = "/opt/example/bin:/usr/bin"
        var socketDir = "/Users/example/.dch-test"
        /// Holds the gate until signalled (a row orders a close before the plan lands).
        var hold: DispatchSemaphore?
        var probes: [String] { lock.withLock { _probes } }
        var gates: Int { lock.withLock { _gates } }

        var io: TerminalEditorIO {
            TerminalEditorIO(
                probe: { [self] name in lock.withLock { _probes.append(name); return vars[name] ?? "" } },
                loginPath: { [self] in loginPATH },
                gate: { [self] in
                    hold?.wait()
                    return lock.withLock { _gates += 1; return gateAnswer }
                },
                isExecutable: { [self] in onPATH.contains($0) },
                env: { [self] in ["HOME": "/Users/example", "PATH": "/usr/bin", "DCH_SOCKET_DIR": socketDir] })
        }
    }

    /// The window's seams: a recorded controller per Edit, a recorded end per close.
    @MainActor
    final class Rig {
        let shell = FakeShell()
        var settings = TerminalEditor.Settings(terminal: true, command: "")
        let cache = TerminalEditor.Cache()
        var controllers: [AgentTerminalController] = []
        var children: [AgentTerminalTests.FakeChild] = []
        var ios: [AgentTerminalIO] = []
        var requests: [AgentTerminalSpawn] = []
        var ended: [TerminalEditor.Spawn] = []

        var seams: TerminalEditorSeams {
            TerminalEditorSeams(settings: { [unowned self] in settings }, io: shell.io, cache: cache,
                                makeController: { [unowned self] in controller() },
                                end: { [unowned self] in ended.append($0) })
        }

        /// A controller that spawns a fake child at once: the grid is known before the attach, the screen reports it.
        private func controller() -> AgentTerminalController {
            let c = AgentTerminalController()
            c.spawn = { [unowned self] req, io in
                requests.append(req)
                ios.append(io)
                let child = AgentTerminalTests.FakeChild()
                children.append(child)
                return child
            }
            c.makeScreen = { [unowned c] events in
                let s = AgentTerminalTests.FakeScreen(events)
                if let g = c.grid { c.gridChanged(cols: g.cols, rows: g.rows, generation: c.generation) }
                return s
            }
            c.after = { _, _ in }
            c.clientVersion = { _ in nil }
            c.socketExists = { _ in false }
            c.gridChanged(cols: 80, rows: 24)
            controllers.append(c)
            return c
        }
    }

    private func waitUntil(_ what: String, _ done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(done(), "not within 5 s: \(what)", file: file, line: line)
    }

    private func plan(_ shell: FakeShell, command: String = "", path: String = "/Users/example/notes.md",
                      cache: TerminalEditor.Cache = TerminalEditor.Cache()) -> TerminalEditor.Plan {
        TerminalEditor.plan(command: command, path: path, io: shell.io, cache: cache)
    }

    private func spawned(_ p: TerminalEditor.Plan, file: StaticString = #filePath, line: UInt = #line) -> TerminalEditor.Spawn? {
        guard case .spawn(let s) = p else { XCTFail("refused: \(p)", file: file, line: line); return nil }
        return s
    }

    private func windows(_ rig: Rig) -> TextViewerWindows {
        let w = TextViewerWindows()
        w.build = { TextViewerWindows.makeWindow($0, autosave: nil) }
        w.present = { _ in }
        w.dismissed = { _ in }
        w.actions = {
            TextViewerActions(defaultApp: { _ in nil }, openWith: { _, _ in }, reveal: { _ in }, openURL: { _ in }, view: { _ in })
        }
        w.imageLoader = { _, _, _ in nil }
        w.isRemote = { _ in false }
        w.editorSeams = { rig.seams }
        return w
    }

    private func file(_ label: String, _ name: String = "notes.md") throws -> URL {
        let url = tempDir(label).appendingPathComponent(name)
        try Data("# notes\n".utf8).write(to: url)
        return url
    }

    /// Opens `url` in a window of `w` and waits for its first load.
    private func open(_ w: TextViewerWindows, _ url: URL) -> TextViewerModel? {
        w.open(url)
        guard let model = w.entries.last?.model else { XCTFail("no window"); return nil }
        waitUntil("loaded", { model.state != nil })
        return model
    }

    // MARK: argv (N9)

    /// The path is ONE argv element after the editor's words, never interpreted; argv[0] is absolute on the login PATH.
    func testArgv() throws {
        let shell = FakeShell()
        let path = "/Users/example/a b 'q' \"d\" $HOME; `x` -n.md"
        let s = try XCTUnwrap(spawned(plan(shell, command: "nvim -u 'my init.vim'", path: path)))
        XCTAssertEqual(s.argv, ["/opt/example/bin/nvim", "-u", "my init.vim", path])
        XCTAssertEqual(s.argv.last, path, "the path is the last element, as is")
        XCTAssertEqual(s.dch, "/opt/example/bin/dch", "the gate's dch")
        let r = s.request(cols: 80, rows: 24)
        XCTAssertEqual(r.exe, "/opt/example/bin/dch")
        XCTAssertEqual(r.args, ["-E", "-n", s.key.name, "--"] + s.argv, "dch -E -n <name> -- <argv…>")
        XCTAssertEqual(r.env["PATH"], "/opt/example/bin:/usr/bin:" + LoginPath.wellKnown(home: NSHomeDirectory()).joined(separator: ":"),
                       "the login PATH")
        XCTAssertEqual(r.env["DCH_SOCKET_DIR"], "/Users/example/.dch-test")
        XCTAssertEqual(s.key, AgentSessionKey(dir: "/Users/example/.dch-test", name: s.key.name))
    }

    func testRelativePathIsRefusedBeforeAnyProbe() {
        let shell = FakeShell()
        XCTAssertEqual(plan(shell, path: "-n.md"), .refused(TerminalEditor.notAbsolute))
        XCTAssertEqual(plan(shell, path: "notes.md"), .refused(TerminalEditor.notAbsolute))
        XCTAssertEqual(shell.gates, 0)
        XCTAssertTrue(shell.probes.isEmpty)
    }

    func testControlCharactersInThePathAreRefused() {
        let shell = FakeShell()
        for c in ["\n", "\u{7}", "\u{7F}", "\u{85}", "\u{2028}", "\u{2029}", "\u{202E}", "\u{2067}", "\u{200F}", "\u{61C}"] {
            XCTAssertEqual(plan(shell, path: "/Users/example/a\(c)b.md"), .refused(TerminalEditor.controlChars),
                           "U+\(String(c.unicodeScalars.first!.value, radix: 16))")
        }
        XCTAssertEqual(shell.gates, 0, "refused before the gate")
        XCTAssertTrue(shell.probes.isEmpty, "and before the login shell")
        XCTAssertNotNil(spawned(plan(shell, path: "/Users/example/caf\u{E9} \u{1F600}.md")), "other Unicode is fine")
    }

    func testTooManyWordsAreRefused() {
        let shell = FakeShell()
        let words = ["nvim"] + Array(repeating: "-x", count: TerminalEditor.maxWords - 1)
        XCTAssertNotNil(spawned(plan(shell, command: words.joined(separator: " "))), "255 words and the path fit")
        XCTAssertEqual(plan(shell, command: (words + ["-x"]).joined(separator: " ")), .refused(TerminalEditor.tooManyWords))
    }

    func testEditorNotOnTheLoginPathSaysSo() {
        let shell = FakeShell()
        XCTAssertEqual(plan(shell, command: "hx"), .refused("hx was not found on your login PATH"))
        XCTAssertEqual(plan(shell, command: "bin/nvim"), .refused("bin/nvim was not found on your login PATH"), "relative")
        XCTAssertEqual(spawned(plan(shell, command: "/usr/bin/vi"))?.argv.first, "/usr/bin/vi", "absolute and executable")
        shell.loginPATH = "/usr/bin"
        XCTAssertEqual(plan(shell, command: "nvim"), .refused(TerminalEditor.notFound("nvim")), "only the login PATH is searched")
    }

    // MARK: The session name (R8)

    func testSessionName() {
        let a = TerminalEditor.sessionName(path: "/Users/example/notes.md")
        XCTAssertEqual(a, TerminalEditor.sessionName(path: "/Users/example/notes.md"), "stable per path")
        XCTAssertNotEqual(a, TerminalEditor.sessionName(path: "/Users/example/other/notes.md"), "differs between paths")
        XCTAssertTrue(a.hasPrefix("edit-notes.md-"))
        XCTAssertEqual(a.split(separator: "-").last?.count, 16, "16 hex digits (R8)")
        let long = TerminalEditor.sessionName(path: "/Users/example/" + String(repeating: "\u{E9}a", count: 500) + ".md")
        for n in [a, long, TerminalEditor.sessionName(path: "/Users/example/-\n\u{202E}.md"), TerminalEditor.sessionName(path: "/")] {
            XCTAssertTrue(DchCtl.nameOK(n), n)
            XCTAssertFalse(DchControlOps.idShaped(n), n)
            XCTAssertLessThanOrEqual(n.utf8.count, 255, n)
            XCTAssertTrue(TerminalEditor.isEditSession(n), n)
        }
        XCTAssertLessThanOrEqual(long.utf8.count, 5 + 40 + 1 + 16)
        for n in ["edit-notes", "api", "edit-notes-0123456789abcdeg", "edit-0123456789abcdef", "notes-0123456789abcdef",
                  "edit-x-0123456789ABCDEF"] {
            XCTAssertFalse(TerminalEditor.isEditSession(n), n)
        }
    }

    // MARK: The gate

    func testGateRefusedOrMissingSaysWhy() {
        let shell = FakeShell()
        shell.gateAnswer = DchCommand.gate(nil, masters: [], minimum: AgentIsland.controlMinimum)
        XCTAssertEqual(plan(shell), .refused(TerminalEditor.needsDch), "dch missing")
        shell.gateAnswer = DchCommand.gate(DchCommand.Binary(path: "/opt/example/bin/dch", version: [1, 23, 9]), masters: [],
                                           minimum: AgentIsland.controlMinimum)
        XCTAssertEqual(plan(shell), .refused(TerminalEditor.needsDch), "too old")
        XCTAssertEqual(TerminalEditor.needsDch, "Terminal editor needs dch 1.24.0")
        XCTAssertTrue(shell.probes.isEmpty, "no login shell for a refused gate")
    }

    // MARK: Detection (OQ-118 Q2: the login shell only)

    func testDetectionVisualWinsOverEditor() {
        let shell = FakeShell()
        shell.vars = ["VISUAL": "vi", "EDITOR": "nvim"]
        XCTAssertEqual(spawned(plan(shell))?.argv.first, "/usr/bin/vi")
        XCTAssertEqual(shell.probes, ["VISUAL"], "EDITOR is not read when VISUAL is set")
        XCTAssertEqual(TerminalEditor.detectedText(.found(command: "nvim", from: "EDITOR")), "Detected: nvim (from $EDITOR)")
    }

    func testDetectionEmptyMeansNone() {
        let shell = FakeShell()
        shell.vars = ["VISUAL": "", "EDITOR": "  "]
        let cache = TerminalEditor.Cache()
        XCTAssertEqual(plan(shell, cache: cache), .refused(TerminalEditor.noEditor))
        XCTAssertEqual(TerminalEditor.detect({ _ in "" }, cache: TerminalEditor.Cache()), TerminalEditor.Detection.none)
        XCTAssertTrue(TerminalEditor.detectedText(TerminalEditor.Detection.none).hasPrefix("None found."))
    }

    func testFailedProbeIsNotCachedAndASuccessIs() {
        let shell = FakeShell()
        let cache = TerminalEditor.Cache()
        shell.vars = ["VISUAL": nil, "EDITOR": "nvim"]
        XCTAssertEqual(plan(shell, cache: cache), .refused(TerminalEditor.probeFailed))
        shell.vars = ["VISUAL": "", "EDITOR": "nvim"]
        XCTAssertNotNil(spawned(plan(shell, cache: cache)), "the next use probes again")
        let probes = shell.probes.count
        XCTAssertNotNil(spawned(plan(shell, cache: cache)))
        XCTAssertEqual(shell.probes.count, probes, "a found editor is cached")
    }

    func testTheSettingWinsAndSkipsDetection() {
        let shell = FakeShell()
        XCTAssertEqual(spawned(plan(shell, command: "  vi  "))?.argv, ["/usr/bin/vi", "/Users/example/notes.md"])
        XCTAssertTrue(shell.probes.isEmpty)
    }

    // MARK: The window (N6, the lifecycle, OQ-118 Q3)

    /// N6: opening a file with Terminal chosen asks neither the login shell nor dch, and spawns nothing, until Edit.
    func testOpenNeverSpawns() throws {
        let rig = Rig()
        let w = windows(rig)
        let model = try XCTUnwrap(open(w, file("te-open")))
        XCTAssertEqual(model.mode, .read, "a window opens in Read")
        XCTAssertTrue(rig.shell.probes.isEmpty)
        XCTAssertEqual(rig.shell.gates, 0)
        XCTAssertTrue(rig.controllers.isEmpty && rig.requests.isEmpty)
        for e in w.entries { e.window.close() }
        XCTAssertTrue(rig.ended.isEmpty, "nothing to end")
    }

    func testBuiltinSettingLeavesEditOff() throws {
        let rig = Rig()
        rig.settings.terminal = false
        let w = windows(rig)
        let model = try XCTUnwrap(open(w, file("te-builtin")))
        XCTAssertFalse(model.canEdit)
        XCTAssertEqual(TextViewerModeSwitch.segments(canEdit: model.canEdit).map(\.enabled), [true, false])
        model.edit()
        XCTAssertTrue(model.planning == nil, "no plan")
        XCTAssertEqual(rig.shell.gates, 0)
        for e in w.entries { e.window.close() }
    }

    func testRefusalStaysInReadAndSaysWhy() async throws {
        let rig = Rig()
        rig.shell.gateAnswer = .refused("needs dch 1.24.0")
        let w = windows(rig)
        let model = try XCTUnwrap(open(w, file("te-refused")))
        model.edit()
        await model.planning?.value
        XCTAssertEqual(model.mode, .read)
        XCTAssertEqual(model.notice, TerminalEditor.needsDch)
        XCTAssertTrue(rig.controllers.isEmpty)
        for e in w.entries { e.window.close() }
    }

    /// The editor quits: dch unlinks the socket, the client exits 0, the controller ends, the window goes to Read and
    /// reads the file again.
    func testEditorExitReturnsToReadAndReloads() async throws {
        let rig = Rig()
        let w = windows(rig)
        let url = try file("te-exit")
        let model = try XCTUnwrap(open(w, url))
        model.edit()
        await model.planning?.value
        XCTAssertEqual(model.mode, .terminal)
        XCTAssertEqual(rig.requests.count, 1, "one spawn")
        XCTAssertEqual(rig.requests.last?.args.last, url.resolvingSymlinksInPath().path)
        XCTAssertEqual(rig.children.last?.ran, 1)
        let loads = model.loads
        try Data("# changed\n".utf8).write(to: url)
        rig.ios.last?.exit(0)
        waitUntil("back in Read", { model.mode == .read && model.loads > loads })
        XCTAssertTrue(model.terminal == nil, "the session is gone")
        XCTAssertEqual(model.document?.text, "# changed\n")
        for e in w.entries { e.window.close() }
        XCTAssertTrue(rig.ended.isEmpty, "an ended editor is not ended again")
    }

    /// Read detaches the client and keeps the session; Edit again attaches the same name; the window's close ends it.
    func testReadDetachesAndCloseEndsTheSession() async throws {
        let rig = Rig()
        let w = windows(rig)
        let model = try XCTUnwrap(open(w, file("te-close")))
        model.edit()
        await model.planning?.value
        let name = try XCTUnwrap(rig.requests.last?.args.dropFirst(2).first)
        model.showRead()
        XCTAssertEqual(model.mode, .read)
        XCTAssertEqual(rig.children.last?.terminated, 1, "the client went")
        XCTAssertTrue(rig.ended.isEmpty, "the session lives on")
        model.edit()
        await model.planning?.value
        XCTAssertEqual(rig.requests.count, 2)
        XCTAssertEqual(rig.requests.last?.args.dropFirst(2).first, name, "the same session again")
        for e in w.entries { e.window.close() }
        XCTAssertEqual(rig.children.last?.terminated, 1, "the window's close terminates the client")
        XCTAssertEqual(rig.ended.map(\.key.name), [name], "and ends its session (OQ-118 Q3), once")
    }

    /// A window closed while its Edit is being planned starts nothing.
    func testCloseWhilePlanningStartsNothing() async throws {
        let rig = Rig()
        let gate = DispatchSemaphore(value: 0)
        rig.shell.hold = gate
        let w = windows(rig)
        let model = try XCTUnwrap(open(w, file("te-race")))
        model.edit()
        let job = try XCTUnwrap(model.planning)
        for e in w.entries { e.window.close() }
        gate.signal()
        await job.value
        XCTAssertEqual(model.mode, .read)
        XCTAssertTrue(rig.controllers.isEmpty && rig.requests.isEmpty)
        XCTAssertTrue(rig.ended.isEmpty)
    }

    // MARK: R9: an editor session is not an agent

    func testEditSessionIsNeverNeedsInputClaudeOrSidekick() {
        let edit = TerminalEditor.sessionName(path: "/Users/example/notes-qa.md")
        func row(_ name: String) -> String {
            #"{"name":"\#(name)","alias":"","activity_epoch":1,"state":"blocked","version":"1.63.0","agents":1,"claude_session_id":"0b7c2f3e-aaaa-bbbb-cccc-0123456789ab","transcript_path":null,"claude_foreground":true}"#
        }
        let json = Data(("[" + row(edit) + "," + row("api-qa") + "]").utf8)
        let list = AgentIsland.list(dirs: ["/Users/example/.dch-test"], run: { args, _ in args == ["--ls-json"] ? json : nil })
        XCTAssertEqual(list.count, 2)
        let e = list.first { $0.key.name == edit }, other = list.first { $0.key.name == "api-qa" }
        XCTAssertEqual(e?.state, .idle, "never Needs input")
        XCTAssertEqual(e?.wireState, "idle", "nor to the phone")
        XCTAssertEqual(e?.claudeReading, false, "never a Claude Code: Always allow (#935) never answers it")
        XCTAssertEqual(other?.state, .blocked, "another session keeps dch's state")
        XCTAssertEqual(other?.claudeReading, true)
        let split = AgentIsland.split(list, pattern: AgentIsland.sidekickDefault)
        XCTAssertEqual(split.primary.map(\.key.name), [edit], "never a sidekick, whatever the file's name")
        XCTAssertEqual(split.sidekicks.map(\.key.name), ["api-qa"])
    }

    // MARK: R7: who can set the editor command

    /// The two keys are written by Settings › Text Viewer only: no other source assigns them (so no prosper:// link,
    /// phone message or extension does), they are not synced, and an extension's host.prefs key is always "ext.<id>.<key>".
    func testEditorSettingsHaveOneWriter() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var writers: [String] = [], keyed: [String] = []
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            if text.range(of: #"Preferences\.textViewerEdit(With|orCommand)\s*=[^=]"#, options: .regularExpression) != nil {
                writers.append(f.lastPathComponent)
            }
            if text.contains("\"textViewerEditorCommand\"") || text.contains("\"textViewerEditWith\"") { keyed.append(f.lastPathComponent) }
        }
        XCTAssertEqual(Set(writers), ["TextViewerPane.swift"], "the only writer")
        XCTAssertEqual(keyed, ["Preferences.swift"], "the key strings live in Preferences only")
        XCTAssertFalse(SyncedKeys.isSynced("textViewerEditorCommand"))
        XCTAssertFalse(SyncedKeys.isSynced("textViewerEditWith"))
    }
}
