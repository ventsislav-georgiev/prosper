import XCTest
@testable import ProsperApp

/// #847: the Agent Sessions window's New session form and quick shell, on the model. No dch runs: the spawn is
/// a recorder (`spawnSession`), the folder chooser a seam, folders a fake `folderExists` under /Users/example.
/// Preferences are the XCTest in-memory store, saved and restored per test.
extension AgentWindowD1Tests {

    final class SpawnCalls {
        var calls: [(folder: String, argv: [String], name: String?)] = []
        var done: [@MainActor @Sendable (AgentSessionKey?, String?) -> Void] = []
        /// nil: the runner refuses (busy).
        var accept = true
    }

    static let newSessionPrefs = ["agentWindowNewSessionFolder", "agentIslandNewSessionCommand", modePref]

    @MainActor
    func withNewSessionPrefs(_ body: () throws -> Void) rethrows {
        let saved = Self.newSessionPrefs.map { Preferences.defaults.object(forKey: $0) }
        defer { for (k, v) in zip(Self.newSessionPrefs, saved) { Preferences.defaults.set(v, forKey: k) } }
        for k in Self.newSessionPrefs { Preferences.defaults.removeObject(forKey: k) }
        try body()
    }

    /// A visible model on a store whose gate is open, with every #847 seam faked.
    @MainActor
    func newSessionModel(_ st: AgentIslandStore, _ spawns: SpawnCalls) -> AgentWindowModel {
        st.controlDch = DchCommand.Binary(path: "/fake/dch", version: [1, 46, 1])
        let m = windowModel(st)
        let island = AgentIslandController()
        island.historyDirs = { ["/tmp/dch-test"] }
        island.chooseFolder = { _ in XCTFail("no chooser here") }
        m.island = { island }
        m.home = "/Users/example"
        m.shell = "/bin/fish"
        m.folderExists = { $0 == "/Users/example" || ($0.hasPrefix("/Users/example/") && !$0.hasSuffix("missing")) }
        m.spawnSession = { folder, argv, name, done in
            spawns.calls.append((folder, argv, name))
            spawns.done.append(done)
            return spawns.accept ? AgentSessionKey(dir: "/tmp/dch-test", name: name ?? "?") : nil
        }
        _ = fakeTerminal(m)
        m.setVisible(true)
        return m
    }

    // MARK: Open and prefill

    @MainActor
    func testAgentWindowNewSessionOpenPrefillsFolderNameAndCommand() throws {
        try withNewSessionPrefs {
            Preferences.agentIslandNewSessionCommand = "claude --chrome"
            let url = tempDir().appendingPathComponent("0b7c2f3e-1111-2222-3333-444455556666.jsonl")
            try write(url, [entry("user", ["cwd": "/Users/example/proj", "message": ["role": "user", "content": "hi"]])])
            let live = session("PROJ", .idle, path: url.path)
            let spawns = SpawnCalls(), m = newSessionModel(store([live]), spawns)
            defer { m.close() }
            // Nothing selected: ~.
            m.select(nil)
            m.openNewSession()
            XCTAssertEqual(m.newSession?.folder, "~")
            XCTAssertEqual(m.newSessionName, "example")
            XCTAssertEqual(m.newSession?.nameEdited, false)
            XCTAssertEqual(m.newSession?.command, "claude --chrome", "the island's setting (OQ-3)")
            XCTAssertNil(m.newSessionErrors.folder)
            XCTAssertNil(m.newSessionErrors.name)
            XCTAssertTrue(m.canStartNewSession)
            // ⌘N again: the open form keeps its fields; its Name field is asked for the keys.
            let focus = m.newSessionFocus
            m.setNewSessionCommand("typed")
            m.openNewSession()
            XCTAssertEqual(m.newSession?.command, "typed")
            XCTAssertEqual(m.newSessionFocus, focus + 1)
            m.cancelNewSession()
            XCTAssertNil(m.newSession)
            // The selected live session's cwd; its name is taken (case-folded), so the free name is next.
            m.select(.live(live.key))
            XCTAssertEqual(m.transcript.cwd, "/Users/example/proj")
            m.openNewSession()
            XCTAssertEqual(m.newSession?.folder, "~/proj")
            XCTAssertEqual(m.newSessionName, "proj-2")
            m.cancelNewSession()
            // The last folder wins while it exists.
            Preferences.agentWindowNewSessionFolder = "/Users/example/last"
            m.openNewSession()
            XCTAssertEqual(m.newSession?.folder, "~/last")
            m.cancelNewSession()
            Preferences.agentWindowNewSessionFolder = "/Users/example/missing"
            m.openNewSession()
            XCTAssertEqual(m.newSession?.folder, "~/proj", "a last folder that went: the next choice")
            m.cancelNewSession()
            // Unset setting: claude until the island's inference answers.
            Preferences.agentIslandNewSessionCommand = ""
            m.openNewSession(folder: "/Users/example/x")
            XCTAssertEqual(m.newSession?.command, "claude")
            XCTAssertEqual(m.newSession?.folder, "~/x")
            XCTAssertEqual(spawns.calls.count, 0)
        }
    }

    @MainActor
    func testAgentWindowNewSessionTypedNamePinsAndClearingReturnsToAuto() throws {
        try withNewSessionPrefs {
            let m = newSessionModel(store([]), SpawnCalls())
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertEqual(m.newSessionName, "api")
            m.setNewSessionFolder("~/web")
            XCTAssertEqual(m.newSessionName, "web", "untouched: the name follows the folder")
            m.setNewSessionName("mine")
            m.setNewSessionFolder("~/other")
            XCTAssertEqual(m.newSessionName, "mine", "typed: pinned")
            XCTAssertEqual(m.newSession?.nameEdited, true)
            m.setNewSessionName("  ")
            XCTAssertEqual(m.newSession?.nameEdited, false)
            XCTAssertEqual(m.newSessionName, "other", "cleared: the automatic name again")
            m.setNewSessionName(" spaced ")
            XCTAssertEqual(m.newSessionName, "spaced", "trimmed")
            XCTAssertEqual(m.newSessionRuns, "claude --name spaced", "#847 D7.4: the named argv")
            m.setNewSessionCommand("")
            XCTAssertEqual(m.newSessionRuns, "/bin/fish -l (your login shell)")
        }
    }

    // MARK: Start

    @MainActor
    func testAgentWindowNewSessionStartValidatesThenCallsTheSeamOnce() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = newSessionModel(store([]), spawns)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            m.setNewSessionCommand("claude --chrome 'my x'")
            m.setNewSessionName("a:b")
            XCTAssertEqual(m.newSessionErrors.name, "Use ASCII letters, digits, . _ and - only")
            XCTAssertFalse(m.startNewSession())
            m.setNewSessionName("m0123456789ABCDEF")
            XCTAssertFalse(m.startNewSession())
            m.setNewSessionName("ok")
            m.setNewSessionFolder("~/missing")
            XCTAssertEqual(m.newSessionErrors.folder, "No such folder")
            XCTAssertFalse(m.startNewSession())
            m.setNewSessionFolder("")
            XCTAssertEqual(m.newSessionErrors.folder, "Choose a folder")
            XCTAssertFalse(m.startNewSession())
            XCTAssertEqual(spawns.calls.count, 0, "an invalid Start runs nothing")
            m.setNewSessionFolder("~/api")
            XCTAssertTrue(m.startNewSession())
            XCTAssertEqual(spawns.calls.count, 1)
            XCTAssertEqual(spawns.calls.first?.folder, "/Users/example/api")
            XCTAssertEqual(spawns.calls.first?.argv, ["claude", "--chrome", "my x"])
            XCTAssertEqual(spawns.calls.first?.name, "ok")
            XCTAssertEqual(m.newSession?.starting, AgentSessionKey(dir: "/tmp/dch-test", name: "ok"))
            XCTAssertEqual(m.newSessionStatus, "Starting ok…")
            XCTAssertFalse(m.canStartNewSession)
            XCTAssertFalse(m.startNewSession(), "a second Start while starting")
            XCTAssertFalse(m.startShell())
            XCTAssertEqual(spawns.calls.count, 1)
        }
    }

    /// Every check runs again at Start against the store as it is then (M5).
    @MainActor
    func testAgentWindowNewSessionStartRechecksTheNameTakenSinceOpen() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), st = store([]), m = newSessionModel(st, spawns)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            m.setNewSessionName("web")
            XCTAssertTrue(m.canStartNewSession)
            st.sessions = [session("WEB", .idle), session("api", .idle)]
            XCTAssertFalse(m.startNewSession(), "typed, and taken since (case-folded): refused")
            XCTAssertEqual(m.newSessionErrors.name, "WEB is taken", "QA #713 INFO-7: the session as it is spelled")
            XCTAssertEqual(spawns.calls.count, 0)
            m.setNewSessionName("")
            XCTAssertTrue(m.startNewSession(), "the automatic name, taken since: quietly re-picked")
            XCTAssertEqual(spawns.calls.map(\.name), ["api-2"])
        }
    }

    @MainActor
    func testAgentWindowNewSessionFailureReenablesAndSuccessClosesAndPersists() throws {
        try withNewSessionPrefs {
            Preferences.agentIslandNewSessionCommand = "claude"
            let st = store([]), spawns = SpawnCalls(), m = newSessionModel(st, spawns)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            m.setNewSessionCommand("claude --x")
            XCTAssertTrue(m.startNewSession())
            let failed = "New session failed: dch: api: claude: No such file or directory"
            spawns.done[0](nil, failed)
            XCTAssertNil(m.newSession?.starting, "the form re-enables")
            XCTAssertEqual(m.newSessionStatus, failed)
            XCTAssertNil(Preferences.agentWindowNewSessionFolder, "nothing kept from a failure")
            XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude")
            // The runner busy on the key.
            spawns.accept = false
            XCTAssertFalse(m.startNewSession())
            XCTAssertEqual(m.newSessionStatus, "api is busy: try again")
            XCTAssertNotNil(m.newSession, "the form stays")
            spawns.accept = true
            XCTAssertTrue(m.startNewSession())
            spawns.done[2](AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            XCTAssertEqual(m.newSessionStatus, "Starting api…", "R2 F5: success waits for the row over the pane")
            XCTAssertEqual(m.pendingSpawn?.key, AgentSessionKey(dir: "/tmp/dch-test", name: "api"))
            XCTAssertEqual(Preferences.agentWindowNewSessionFolder, "/Users/example/api", "the expanded folder")
            XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude --x", "OQ-3: the one shared command")
            XCTAssertFalse(SyncedKeys.isSynced("agentWindowNewSessionFolder"), "per Mac")
            st.sessions = [mapped("api")]
            XCTAssertNil(m.newSession, "the row lands: the form closes")
        }
    }

    /// #847 T8 (D7.2, D7.4): Runs shows the named argv; the shared command never keeps a typed name, and a
    /// command with none is stored byte-identical (no requoting).
    @MainActor
    func testAgentWindowNewSessionStoresTheCommandWithoutItsName() throws {
        try withNewSessionPrefs {
            let st = store([]), spawns = SpawnCalls(), m = newSessionModel(st, spawns)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            m.setNewSessionCommand("claude --name x --chrome")
            XCTAssertEqual(m.newSessionRuns, "claude --name api --chrome", "the typed name replaced by the session's")
            XCTAssertEqual(m.newSession?.command, "claude --name x --chrome", "the field keeps what was typed")
            XCTAssertTrue(m.startNewSession())
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude --chrome")
            st.sessions = [mapped("api")]   // its row lands: the form closes
            m.openNewSession(folder: "/Users/example/api")
            m.setNewSessionCommand("claude  \"--chrome\"  'my x'")
            XCTAssertTrue(m.startNewSession())
            spawns.done[1](AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude  \"--chrome\"  'my x'", "byte-identical")
            XCTAssertNil(m.newSession, "listed already: it lands at the answer")
            m.openNewSession(folder: "/Users/example/api")
            m.setNewSessionCommand("claude -p 'one shot' -n x")
            XCTAssertEqual(m.newSessionRuns, "claude -p 'one shot' -n x", "a batch run is not named")
        }
    }

    /// An empty command is the login shell, and writes nothing over the shared command (M11).
    @MainActor
    func testAgentWindowNewSessionEmptyCommandWritesNothing() throws {
        try withNewSessionPrefs {
            Preferences.agentIslandNewSessionCommand = "headroom wrap claude"
            let spawns = SpawnCalls(), m = newSessionModel(store([]), spawns)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            m.setNewSessionCommand("  ")
            XCTAssertTrue(m.startNewSession())
            XCTAssertEqual(spawns.calls.first?.argv, ["/bin/fish", "-l"])
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "headroom wrap claude")
            XCTAssertEqual(Preferences.agentWindowNewSessionFolder, "/Users/example/api")
        }
    }

    // MARK: After the spawn

    /// The new row: selected, Terminal even when a reused name chose Transcript (M6), the keys asked for (M7).
    @MainActor
    func testAgentWindowNewSessionPendingSpawnSelectsInTerminalAndFocuses() throws {
        try withNewSessionPrefs {
            Preferences.agentWindowTranscriptSessions = ["/tmp/dch-test\tapi"]
            let other = mapped("other"), st = store([other]), spawns = SpawnCalls(), m = newSessionModel(st, spawns)
            defer { m.close() }
            m.select(.live(other.key))
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertTrue(m.startNewSession())
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            m.refresh()
            XCTAssertEqual(m.selection, .live(other.key), "no row yet: nothing moves")
            XCTAssertNotNil(m.pendingSpawn)
            let api = mapped("api")
            st.sessions = [other, api]
            XCTAssertEqual(m.selection, .live(api.key))
            XCTAssertEqual(m.paneMode, .terminal)
            XCTAssertFalse(m.transcriptKeys.contains("/tmp/dch-test\tapi"), "the reused name's Transcript choice dropped")
            XCTAssertTrue(m.terminal.focusPending, "the keys go to the terminal once its client is live")
            XCTAssertNil(m.pendingSpawn, "one-shot")
        }
    }

    @MainActor
    func testAgentWindowNewSessionPendingSpawnDroppedByAManualPickOrTheSlack() throws {
        try withNewSessionPrefs {
            let other = mapped("other"), st = store([other]), spawns = SpawnCalls(), m = newSessionModel(st, spawns)
            defer { m.close() }
            final class Clock { var t = AgentWindowD1Tests.now }
            let clock = Clock()
            m.now = { clock.t }
            m.select(nil)
            XCTAssertTrue(m.startShell())
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "example"), nil)
            XCTAssertNotNil(m.pendingSpawn)
            m.select(.live(other.key))
            XCTAssertNil(m.pendingSpawn, "a manual pick drops it")
            st.sessions = [other, mapped("example")]
            XCTAssertEqual(m.selection, .live(other.key))
            // The slack: a row later than 15 s selects nothing.
            st.sessions = [other]
            XCTAssertTrue(m.startShell())
            spawns.done[1](AgentSessionKey(dir: "/tmp/dch-test", name: "example"), nil)
            XCTAssertNotNil(m.pendingSpawn)
            clock.t += AgentWindowModel.spawnSlack + 1
            st.sessions = [other, mapped("example")]
            XCTAssertEqual(m.selection, .live(other.key))
            XCTAssertNil(m.pendingSpawn)
            // Reopening the form drops it too.
            st.sessions = [other]
            XCTAssertTrue(m.startShell())
            spawns.done[2](AgentSessionKey(dir: "/tmp/dch-test", name: "example"), nil)
            m.openNewSession()
            XCTAssertNil(m.pendingSpawn)
        }
    }

    /// A row pick (click, arrows) closes the form (M8); the model's own selection changes do not.
    @MainActor
    func testAgentWindowNewSessionRowSelectClosesTheForm() throws {
        try withNewSessionPrefs {
            let a = mapped("a"), b = mapped("b"), st = store([a, b]), m = newSessionModel(st, SpawnCalls())
            defer { m.close() }
            m.select(.live(a.key))
            m.openNewSession()
            m.select(.live(b.key))
            XCTAssertNil(m.newSession, "another row")
            m.openNewSession()
            m.click(.live(b.key))
            XCTAssertNil(m.newSession, "the selected row's click")
            m.openNewSession()
            m.move(-1)
            XCTAssertNil(m.newSession, "arrows")
            m.openNewSession()
            st.sessions = [b]
            XCTAssertNil(m.selection, "the selected session ended")
            XCTAssertNotNil(m.newSession, "a form being typed in stays")
        }
    }

    /// Review F1: the form closed (Esc) while its spawn starts, then the spawn succeeds: the human moved on, so
    /// nothing is selected or focused later; the folder and the command are still kept.
    @MainActor
    func testAgentWindowNewSessionSuccessAfterTheFormClosedSelectsNothing() throws {
        try withNewSessionPrefs {
            let other = mapped("other"), st = store([other]), spawns = SpawnCalls(), m = newSessionModel(st, spawns)
            defer { m.close() }
            m.select(.live(other.key))
            m.openNewSession(folder: "/Users/example/api")
            m.setNewSessionCommand("claude --y")
            XCTAssertTrue(m.startNewSession())
            m.cancelNewSession()
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            XCTAssertNil(m.pendingSpawn, "closed meanwhile: no pending selection")
            XCTAssertNil(m.newSession)
            XCTAssertEqual(Preferences.agentWindowNewSessionFolder, "/Users/example/api", "still kept")
            XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude --y", "still kept")
            st.sessions = [other, mapped("api")]
            XCTAssertEqual(m.selection, .live(other.key), "the row shows: nothing moves")
            XCTAssertFalse(m.terminal.focusPending, "no focus asked")
        }
    }

    /// Review F2: the island's command inference answers late. It fills the field only while the field still reads
    /// "claude" and nothing is starting: an edited command, or one already started, stays as it is.
    @MainActor
    func testAgentWindowNewSessionLateInferenceNeverOverwritesAnEditedOrStartedCommand() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = newSessionModel(store([]), spawns)
            defer { m.close() }
            let island = m.island()
            let asked = DispatchSemaphore(value: 0), answer = DispatchSemaphore(value: 0)
            var rec = DchHistoryRecord(key: AgentSessionKey(dir: "/tmp/dch-test", name: "r"))
            rec.agent = .init(kind: "claude", cwd: "/Users/example/r", launch: ["claude", "--inferred"])
            let held = rec
            island.readLiveRecords = { _ in asked.signal(); answer.wait(); return [held] }
            /// Opens the form with the setting unset, runs `meanwhile`, then lets the inference answer and waits for it.
            @MainActor func inferLate(_ meanwhile: @MainActor () -> Void) {
                Preferences.agentIslandNewSessionCommand = ""
                m.cancelNewSession()
                m.openNewSession(folder: "/Users/example/api")
                XCTAssertEqual(m.newSession?.command, "claude", "claude until the inference answers")
                XCTAssertEqual(asked.wait(timeout: .now() + 5), .success)
                meanwhile()
                answer.signal()
                let end = Date().addingTimeInterval(5)
                while Preferences.agentIslandNewSessionCommand.isEmpty && Date() < end {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude --inferred", "the inference answered")
            }
            inferLate {}
            XCTAssertEqual(m.newSession?.command, "claude --inferred", "untouched: the inferred command")
            inferLate { m.setNewSessionCommand("mine") }
            XCTAssertEqual(m.newSession?.command, "mine", "(a) edited: kept")
            inferLate { XCTAssertTrue(m.startNewSession()) }
            XCTAssertEqual(m.newSession?.command, "claude", "(b) started: kept")
            XCTAssertEqual(spawns.calls.last?.argv, ["claude"])
        }
    }

    /// Review F3: a held (ended) row is selected and its cwd exists: the default folder is home, never the ended
    /// session's (only a live selection's cwd counts).
    @MainActor
    func testAgentWindowNewSessionHeldRowCwdIsNotTheDefaultFolder() throws {
        try withNewSessionPrefs {
            let url = tempDir().appendingPathComponent("0b7c2f3e-1111-2222-3333-444455556666.jsonl")
            try write(url, [entry("user", ["cwd": "/Users/example/proj", "message": ["role": "user", "content": "hi"]])])
            let a = session("a", .idle, path: url.path), st = store([a, session("b", .idle)])
            let m = newSessionModel(st, SpawnCalls())
            defer { m.close() }
            m.stopSession = { _ in true }
            m.select(.live(a.key))
            m.openNewSession()
            XCTAssertEqual(m.newSession?.folder, "~/proj", "live: its cwd")
            m.cancelNewSession()
            m.ask(.stop, a)
            m.confirm(true)
            st.sessions = [session("b", .idle)]
            XCTAssertTrue(m.selectionIsHeld)
            XCTAssertEqual(m.transcript.cwd, "/Users/example/proj", "the ended session's cwd is still known")
            m.openNewSession()
            XCTAssertEqual(m.newSession?.folder, "~", "held: home")
        }
    }

    // MARK: Quick shell and the gate

    @MainActor
    func testAgentWindowNewSessionStartShellRunsTheLoginShellWithNoForm() throws {
        try withNewSessionPrefs {
            Preferences.agentIslandNewSessionCommand = "claude --x"
            Preferences.agentWindowNewSessionFolder = "/Users/example/last"
            let last = session("last", .idle), st = store([last]), spawns = SpawnCalls(), m = newSessionModel(st, spawns)
            defer { m.close() }
            XCTAssertTrue(m.startShell())
            XCTAssertNil(m.newSession, "no form")
            XCTAssertEqual(spawns.calls.count, 1)
            XCTAssertEqual(spawns.calls.first?.folder, "/Users/example/last")
            XCTAssertEqual(spawns.calls.first?.argv, ["/bin/fish", "-l"])
            XCTAssertEqual(spawns.calls.first?.name, "last-2")
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "last-2"), nil)
            XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude --x", "a shell writes no command")
            // The form's New shell: its folder and name, the shell's argv.
            m.openNewSession(folder: "/Users/example/web")
            m.setNewSessionName("sh")
            XCTAssertTrue(m.startShell())
            XCTAssertEqual(spawns.calls.last?.folder, "/Users/example/web")
            XCTAssertEqual(spawns.calls.last?.argv, ["/bin/fish", "-l"])
            XCTAssertEqual(spawns.calls.last?.name, "sh")
            spawns.done[1](AgentSessionKey(dir: "/tmp/dch-test", name: "sh"), nil)
            st.sessions = [last, mapped("sh")]
            XCTAssertNil(m.newSession)
            XCTAssertEqual(Preferences.agentIslandNewSessionCommand, "claude --x")
            XCTAssertEqual(Preferences.agentWindowNewSessionFolder, "/Users/example/web")
        }
    }

    @MainActor
    func testAgentWindowNewSessionGateRefusalStartsNothing() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), st = store([session("a", .idle)]), m = newSessionModel(st, spawns)
            defer { m.close() }
            // R2 F2: the gate closes while the form is open: it stays, says why, Start and New shell refuse.
            m.openNewSession(folder: "/Users/example/api")
            st.controlDch = nil
            let why = try XCTUnwrap(st.resumeGate.refusal)
            XCTAssertNotNil(m.newSession)
            XCTAssertEqual(m.newSessionStatus, "Controls \(why)")
            XCTAssertFalse(m.canStartNewSession)
            XCTAssertFalse(m.startNewSession())
            XCTAssertFalse(m.startShell())
            m.cancelNewSession()
            XCTAssertFalse(m.startShell())
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertNil(m.newSession, "R2 F2: refused, ⌘N, + and the pill open nothing")
            XCTAssertEqual(spawns.calls.count, 0)
        }
    }

    // MARK: QA #713 INFO-3: dch's room for a name

    /// The form's limit is dch's room in the socket dir the island spawns into, and the automatic name fits it.
    @MainActor
    func testAgentWindowNewSessionNameLimitFollowsTheSpawnDir() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = newSessionModel(store([]), spawns)
            defer { m.close() }
            m.island().historyDirs = { ["/Users/example-user/.config/prosper/dch-isolated-00001"] }   // 54 bytes: 43 left
            m.openNewSession(folder: "/Users/example/" + String(repeating: "b", count: 60))
            XCTAssertEqual(m.newSessionName, String(repeating: "b", count: 39), "room for a -N under 43")
            m.setNewSessionName(String(repeating: "a", count: 44))
            XCTAssertEqual(m.newSessionErrors.name, "43 characters at most")
            XCTAssertFalse(m.startNewSession())
            m.setNewSessionName(String(repeating: "a", count: 43))
            XCTAssertNil(m.newSessionErrors.name)
            XCTAssertTrue(m.startNewSession())
            XCTAssertEqual(spawns.calls.map(\.name), [String(repeating: "a", count: 43)])
        }
    }

    // MARK: QA #713 INFO-4: whose answer arrived

    /// (a) A quick shell started before the form fails while the form's own spawn runs: the form keeps
    /// "Starting…" and shows nothing of the shell's; its own answer still closes it.
    @MainActor
    func testAgentWindowNewSessionQuickShellFailureLeavesTheFormAlone() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = newSessionModel(store([]), spawns)
            defer { m.close() }
            XCTAssertTrue(m.startShell())
            XCTAssertNil(m.newSession)
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertTrue(m.startNewSession())
            spawns.done[0](nil, "New session failed: dch: example: nope")
            XCTAssertEqual(m.newSession?.starting, AgentSessionKey(dir: "/tmp/dch-test", name: "api"))
            XCTAssertEqual(m.newSessionStatus, "Starting api…")
            spawns.done[1](AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            XCTAssertEqual(m.newSessionStatus, "Starting api…", "its own answer: it waits for its row (R2 F5)")
            XCTAssertEqual(m.pendingSpawn?.key, AgentSessionKey(dir: "/tmp/dch-test", name: "api"))
        }
    }

    /// (b) A quick shell that succeeds after the form opened: the form stays open, nothing is selected later.
    @MainActor
    func testAgentWindowNewSessionQuickShellSuccessKeepsAFormOpenedSince() throws {
        try withNewSessionPrefs {
            let other = mapped("other"), st = store([other]), spawns = SpawnCalls(), m = newSessionModel(st, spawns)
            defer { m.close() }
            m.select(.live(other.key))
            XCTAssertTrue(m.startShell())
            let shell = try XCTUnwrap(spawns.calls.first?.name)
            m.openNewSession(folder: "/Users/example/api")
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: shell), nil)
            XCTAssertNotNil(m.newSession, "the form stays")
            XCTAssertNil(m.pendingSpawn)
            st.sessions = [other, mapped(shell)]
            XCTAssertNotNil(m.newSession, "the shell's row shows: the form still stays")
            XCTAssertEqual(m.selection, .live(other.key))
        }
    }

    /// (c) The store goes (the island's runner then drops every answer): the form leaves "Starting…" with a short
    /// failure text; a late answer changes nothing.
    @MainActor
    func testAgentWindowNewSessionStoreGoneEndsStarting() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = newSessionModel(store([]), spawns)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertTrue(m.startNewSession())
            m.bind(nil)
            XCTAssertNil(m.newSession?.starting)
            XCTAssertEqual(m.newSessionStatus, "No answer for api: Agent Island is off")
            XCTAssertFalse(m.canStartNewSession, "no store: no Start")
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            XCTAssertNotNil(m.newSession, "a late answer is not the form's any more")
            XCTAssertNil(m.pendingSpawn)
        }
    }

    /// (d) A second quick shell before the next poll lists the first: started under the next free name (in flight,
    /// answered, failed). A busy runner on a name the window did not claim says so on the dir-wide line.
    @MainActor
    func testAgentWindowNewSessionSecondQuickShellBeforeThePollIsStarted() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), st = store([]), m = newSessionModel(st, spawns)
            defer { m.close() }
            XCTAssertTrue(m.startShell())
            XCTAssertTrue(m.startShell(), "the first in flight")
            XCTAssertEqual(spawns.calls.map(\.name), ["example", "example-2"])
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "example"), nil)
            XCTAssertTrue(m.startShell(), "answered, not yet listed")
            XCTAssertEqual(spawns.calls.last?.name, "example-3")
            spawns.done[1](nil, "New session failed: dch: example-2: nope")
            XCTAssertTrue(m.startShell(), "a failed name is free again")
            XCTAssertEqual(spawns.calls.last?.name, "example-2")
            spawns.accept = false
            XCTAssertFalse(m.startShell())
            XCTAssertEqual(st.actions[AgentSessionKey(dir: "/tmp/dch-test", name: "")], "example-4 is busy: try again")
        }
    }

    /// A stale answer: the form closed, reopened and started again; the first spawn's answer touches nothing.
    @MainActor
    func testAgentWindowNewSessionStaleFormAnswerDoesNotTouchANewerRequest() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), m = newSessionModel(store([]), spawns)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertTrue(m.startNewSession())
            m.cancelNewSession()
            m.openNewSession(folder: "/Users/example/web")
            XCTAssertTrue(m.startNewSession())
            spawns.done[0](nil, "New session failed: dch: api: nope")
            XCTAssertEqual(m.newSessionStatus, "Starting web…", "the old failure is not this form's")
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            XCTAssertNotNil(m.newSession, "nor the old success")
            XCTAssertNil(m.pendingSpawn)
            spawns.done[1](AgentSessionKey(dir: "/tmp/dch-test", name: "web"), nil)
            XCTAssertEqual(m.newSessionStatus, "Starting web…", "its own answer: it waits for its row (R2 F5)")
            XCTAssertEqual(m.pendingSpawn?.key, AgentSessionKey(dir: "/tmp/dch-test", name: "web"))
        }
    }

    /// R2-1: from Start to the answer a typed name is not taken for its own form (its claim, or a poll listing it
    /// early): no error, the same name and Runs line. A failure frees it (no stale claim).
    @MainActor
    func testAgentWindowNewSessionStartingTypedNameIsNotTakenForItsOwnForm() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), st = store([]), m = newSessionModel(st, spawns)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/web")
            m.setNewSessionName("api")
            let runs = m.newSessionRuns
            XCTAssertTrue(m.startNewSession())
            XCTAssertNil(m.newSessionErrors.name, "its own claim")
            XCTAssertEqual(m.newSessionName, "api")
            XCTAssertEqual(m.newSessionRuns, runs)
            st.sessions = [session("api", .idle)]
            XCTAssertNil(m.newSessionErrors.name, "listed before the answer")
            XCTAssertEqual(m.newSessionName, "api")
            XCTAssertEqual(m.newSessionRuns, runs)
            st.sessions = []
            spawns.done[0](nil, "New session failed: dch: api: nope")
            XCTAssertNil(m.newSession?.starting)
            XCTAssertNil(m.newSessionErrors.name, "a failure frees the name")
            XCTAssertTrue(m.canStartNewSession)
        }
    }

    /// R2-1: the automatic name stays the one being started (not "-2") until the answer; after the form's success
    /// the claim still counts for the next form within spawnSlack.
    @MainActor
    func testAgentWindowNewSessionStartingAutoNameIsNotTakenForItsOwnForm() throws {
        try withNewSessionPrefs {
            let spawns = SpawnCalls(), st = store([]), m = newSessionModel(st, spawns)
            defer { m.close() }
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertEqual(m.newSessionName, "api")
            let runs = m.newSessionRuns
            XCTAssertTrue(m.startNewSession())
            XCTAssertNil(m.newSessionErrors.name)
            XCTAssertEqual(m.newSessionName, "api", "not api-2")
            XCTAssertEqual(m.newSessionRuns, runs)
            st.sessions = [session("api", .idle)]
            XCTAssertNil(m.newSessionErrors.name, "listed before the answer")
            XCTAssertEqual(m.newSessionName, "api")
            XCTAssertEqual(m.newSessionRuns, runs)
            st.sessions = []
            spawns.done[0](AgentSessionKey(dir: "/tmp/dch-test", name: "api"), nil)
            m.cancelNewSession()   // R2 F5: the form waits for its row; Cancel closes it and drops the pending pick
            XCTAssertNil(m.newSession)
            XCTAssertNil(m.pendingSpawn)
            m.openNewSession(folder: "/Users/example/api")
            XCTAssertEqual(m.newSessionName, "api-2", "the claim counts for the next form")
        }
    }
}
