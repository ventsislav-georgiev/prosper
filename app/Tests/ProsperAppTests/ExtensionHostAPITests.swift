import XCTest
import LuaRuntime
@testable import ProsperApp

/// In-memory fake of the native host capabilities.
private final class FakeServices: ExtensionHostServices, @unchecked Sendable {
    var clip: String?
    var written: [String] = []
    var prefs: [String: String] = [:]
    var notifications: [(String, String)] = []
    var llmDelay: TimeInterval = 0
    /// Canned HTTP responses keyed by URL; absent key → transport failure (nil).
    var httpResponses: [String: HTTPResponse] = [:]
    /// If non-empty, responses are dequeued in order (for retry tests), taking
    /// precedence over `httpResponses`. A `nil` entry simulates a transport error.
    var httpSequence: [HTTPResponse?] = []
    /// Records every request the extension made (method, url, body).
    var httpRequests: [(method: String, url: String, body: String?)] = []
    var fixedEpoch: Double = 1_700_000_000
    /// Canned focused-window frame for window-management tests.
    var windowFrame: WindowFrame?
    /// Records every setFocusedWindowFrame call (x, y, w, h).
    var windowSets: [(x: Double, y: Double, w: Double, h: Double)] = []

    func clipboardRead() -> String? { clip }
    func clipboardWrite(_ text: String) { written.append(text); clip = text }
    func clipboardHistory(limit: Int) -> [String] { Array(["a", "b", "c", "d"].prefix(limit)) }
    func llmComplete(_ prompt: String) async -> String {
        if llmDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(llmDelay * 1_000_000_000)) }
        return "completed:\(prompt)"
    }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String {
        // Mirrors the live service: a JSON object the host.llm.translate Lua
        // wrapper decodes into { primary, detected, candidates }.
        "{\"primary\":\"[\(target)]\(text)\",\"detected\":\"\",\"candidates\":[]}"
    }
    func shellRun(_ command: String) async -> String { "ran:\(command)" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? {
        httpRequests.append((method, url, body))
        if !httpSequence.isEmpty { return httpSequence.removeFirst() }
        return httpResponses[url]
    }
    func currentEpochSeconds() -> Double { fixedEpoch }
    func focusedWindowFrame() -> WindowFrame? { windowFrame }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool {
        windowSets.append((x, y, width, height))
        return true
    }
    func prefGet(extensionID: String, key: String) -> String? { prefs[key] }
    func prefSet(extensionID: String, key: String, value: String) { prefs[key] = value }
    func notify(title: String, body: String) { notifications.append((title, body)) }
    /// Canned subdirectory listing keyed by tilde-expanded/raw path.
    var directories: [String: [String]] = [:]
    func listDirectories(_ path: String) -> [String] { directories[path] ?? [] }
    /// Canned JSON array string returned by the app-launcher search.
    var appsResult = "[]"
    func appsSearch(_ query: String) -> String { appsResult }
    /// Records the marshalled file-search options and returns canned JSON. When
    /// `filesSearchHandler` is set it backs the result (e.g. the real engine over a
    /// mock file index), so integration tests exercise the full search path.
    var fileSearches: [String] = []
    var filesResult = "[]"
    var filesSearchHandler: (@Sendable (String) async -> String)?
    func filesSearch(_ optsJSON: String) async -> String {
        fileSearches.append(optsJSON)
        if let h = filesSearchHandler { return await h(optsJSON) }
        return filesResult
    }
    /// Records every built-in file action the extension fired.
    var fileActs: [(id: String, path: String)] = []
    func filesAct(id: String, path: String) { fileActs.append((id, path)) }
    /// Records agent runs (goal + marshalled opts) and returns canned JSON.
    var agentRuns: [(goal: String, optsJSON: String?)] = []
    var agentRunResult = #"{"runId":"r1"}"#
    var agentStatusResult = #"{"phase":"running","active":true}"#
    var agentResultResult = #"{"done":true,"text":"fixed it"}"#
    func agentRun(goal: String, cwd: String?, optsJSON: String?) -> String {
        agentRuns.append((goal, optsJSON)); return agentRunResult
    }
    func agentStatus(_ runID: String) -> String { agentStatusResult }
    func agentResult(_ runID: String) -> String { agentResultResult }
}

final class ExtensionHostAPITests: XCTestCase {

    /// Run a closure off the main thread (host async bridge blocks its thread).
    private func offMain(timeout: TimeInterval = 10, _ body: @escaping () throws -> Void) {
        let exp = expectation(description: "offMain")
        var thrown: Error?
        DispatchQueue.global().async {
            do { try body() } catch { thrown = error }
            exp.fulfill()
        }
        wait(for: [exp], timeout: timeout)
        if let thrown { XCTFail("threw: \(thrown)") }
    }

    func testHostNamespaceAssembledAndRawHidden() throws {
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: "com.test", services: FakeServices()).install(into: lua)
        try lua.run("""
        function probe()
            return tostring(type(host)) .. ',' .. tostring(__h_clip_read) .. ',' ..
                   tostring(type(host.clipboard.read)) .. ',' .. tostring(type(host.llm.complete))
        end
        """)
        XCTAssertEqual(try lua.callGlobal("probe"), "table,nil,function,function")
    }

    func testAgentBridgeMarshalsAndDecodes() throws {
        let lua = try LuaRuntime()
        let svc = FakeServices()
        try ExtensionHost(extensionID: "com.test", services: svc).install(into: lua)
        try lua.run("""
        function probe()
            local r = host.agent.run("fix the bug", { cwd = "/tmp/repo" })
            local s = host.agent.status(r.runId)
            local res = host.agent.result(r.runId)
            return r.runId .. ',' .. tostring(s.active) .. ',' .. tostring(res.done) .. ',' .. res.text
        end
        """)
        XCTAssertEqual(try lua.callGlobal("probe"), "r1,true,true,fixed it")
        XCTAssertEqual(svc.agentRuns.count, 1)
        XCTAssertEqual(svc.agentRuns[0].goal, "fix the bug")
        // opts table is marshalled to JSON containing the cwd.
        XCTAssertTrue(svc.agentRuns[0].optsJSON?.contains("/tmp/repo") == true)
    }

    func testClipboardPrefsNotify() throws {
        let lua = try LuaRuntime()
        let svc = FakeServices()
        try ExtensionHost(extensionID: "com.test", services: svc).install(into: lua)
        offMain {
            try lua.run("""
            function t_clip() host.clipboard.write('hello'); return host.clipboard.read() end
            function t_pref() host.prefs.set('k', 'v'); return host.prefs.get('k') end
            function t_notify() host.notify('Title', 'Body'); return 'ok' end
            function t_hist() return host.clipboard.history(2) end
            """)
            XCTAssertEqual(try lua.callGlobal("t_clip"), "hello")
            XCTAssertEqual(try lua.callGlobal("t_pref"), "v")
            XCTAssertEqual(try lua.callGlobal("t_notify"), "ok")
            XCTAssertEqual(try lua.callGlobal("t_hist"), "a\nb")
        }
        XCTAssertEqual(svc.written, ["hello"])
        XCTAssertEqual(svc.prefs["k"], "v")
        XCTAssertEqual(svc.notifications.first?.0, "Title")
    }

    func testAsyncLLMAndShellBridge() throws {
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: "com.test", services: FakeServices()).install(into: lua)
        offMain {
            try lua.run("""
            function t_llm() return host.llm.complete('hi') end
            function t_tr() local r = host.llm.translate('x', 'French'); return r and r.primary or '' end
            function t_sh() return host.shell.run('date') end
            """)
            XCTAssertEqual(try lua.callGlobal("t_llm"), "completed:hi")
            XCTAssertEqual(try lua.callGlobal("t_tr"), "[French]x")
            XCTAssertEqual(try lua.callGlobal("t_sh"), "ran:date")
        }
    }

    func testAsyncCallTimeoutReturnsEmpty() throws {
        let lua = try LuaRuntime()
        let svc = FakeServices()
        svc.llmDelay = 2.0  // longer than the 0.2s call timeout below
        try ExtensionHost(extensionID: "com.test", services: svc, callTimeout: 0.2).install(into: lua)
        offMain {
            try lua.run("function t_slow() return host.llm.complete('hi') end")
            // bridge times out → empty string, never wedges the runtime
            XCTAssertEqual(try lua.callGlobal("t_slow"), "")
        }
    }

    func testAppsSearchDecodesIntoTable() throws {
        let lua = try LuaRuntime()
        let svc = FakeServices()
        svc.appsResult = "[{\"name\":\"Safari\",\"path\":\"/Applications/Safari.app\"}," +
                         "{\"name\":\"Mail\",\"path\":\"/Applications/Mail.app\"}]"
        try ExtensionHost(extensionID: "com.test", services: svc).install(into: lua)
        offMain {
            try lua.run("""
            function t_apps()
                local a = host.apps.search('a')
                return tostring(#a) .. '|' .. a[1].name .. '|' .. a[1].path .. '|' .. a[2].name
            end
            """)
            XCTAssertEqual(try lua.callGlobal("t_apps"),
                           "2|Safari|/Applications/Safari.app|Mail")
        }
    }

    func testAppsSearchEmptyYieldsEmptyTable() throws {
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: "com.test", services: FakeServices()).install(into: lua)
        offMain {
            try lua.run("""
            function t_empty()
                local a = host.apps.search('zzz')
                return tostring(type(a)) .. ',' .. tostring(#a)
            end
            """)
            XCTAssertEqual(try lua.callGlobal("t_empty"), "table,0")
        }
    }

    // MARK: - host.files (search options marshalling + decode, act)

    func testFilesSearchMarshalsOptionsAndDecodesHits() throws {
        let lua = try LuaRuntime()
        let svc = FakeServices()
        svc.filesResult = "[{\"name\":\"notes.txt\",\"path\":\"/Users/me/notes.txt\"," +
                          "\"display\":\"~/notes.txt\",\"isDir\":false,\"kind\":\"Plain Text\"}," +
                          "{\"name\":\"Projects\",\"path\":\"/Users/me/Projects\"," +
                          "\"display\":\"~/Projects\",\"isDir\":true,\"kind\":\"Folder\"}]"
        try ExtensionHost(extensionID: "com.test", services: svc).install(into: lua)
        offMain {
            try lua.run("""
            function t_files()
                local f = host.files.search{ name = "note", kind = { "pdf" }, ["in"] = "~/Documents" }
                return tostring(#f) .. '|' .. f[1].name .. '|' .. f[1].display .. '|' ..
                       tostring(f[1].isDir) .. '|' .. f[2].name .. '|' .. tostring(f[2].isDir) ..
                       '|' .. f[2].kind
            end
            """)
            XCTAssertEqual(try lua.callGlobal("t_files"),
                           "2|notes.txt|~/notes.txt|false|Projects|true|Folder")
        }
        // The options table was marshalled to JSON the host can decode.
        XCTAssertEqual(svc.fileSearches.count, 1)
        let opts = svc.fileSearches[0]
        XCTAssertTrue(opts.contains("\"name\""))
        XCTAssertTrue(opts.contains("note"))
        XCTAssertTrue(opts.contains("pdf"))
        XCTAssertTrue(opts.contains("Documents"))
    }

    func testFilesSearchEmptyYieldsEmptyTable() throws {
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: "com.test", services: FakeServices()).install(into: lua)
        offMain {
            try lua.run("""
            function t_empty()
                local f = host.files.search{ name = "zzz" }
                return tostring(type(f)) .. ',' .. tostring(#f)
            end
            """)
            XCTAssertEqual(try lua.callGlobal("t_empty"), "table,0")
        }
    }

    func testFilesActForwardsIdAndPath() throws {
        let lua = try LuaRuntime()
        let svc = FakeServices()
        try ExtensionHost(extensionID: "com.test", services: svc).install(into: lua)
        offMain {
            try lua.run("""
            function t_act()
                host.files.act("file.reveal", "/Users/me/notes.txt")
                return "ok"
            end
            """)
            XCTAssertEqual(try lua.callGlobal("t_act"), "ok")
        }
        XCTAssertEqual(svc.fileActs.count, 1)
        XCTAssertEqual(svc.fileActs[0].id, "file.reveal")
        XCTAssertEqual(svc.fileActs[0].path, "/Users/me/notes.txt")
    }

    // MARK: - host.http (retry, decode, convenience verbs)

    func testHttpSuccessDecodesBodyJSON() throws {
        let lua = try LuaRuntime()
        let svc = FakeServices()
        svc.httpResponses["https://x/api"] =
            HTTPResponse(status: 200, body: #"{"ok":true,"n":7}"#, headers: ["X-Test": "1"])
        try ExtensionHost(extensionID: "com.test", services: svc).install(into: lua)
        offMain {
            try lua.run("""
            function t() local r = host.http.get('https://x/api')
              if r == nil then return 'nil' end
              return tostring(r.status)..','..tostring(r.ok)..','..tostring(r.json.n)..','..tostring(r.headers['X-Test'])
            end
            """)
            XCTAssertEqual(try lua.callGlobal("t"), "200,true,7,1")
        }
        XCTAssertEqual(svc.httpRequests.count, 1)
        XCTAssertEqual(svc.httpRequests.first?.method, "GET")
    }

    func testHttpRetriesTransientThenSucceeds() throws {
        let lua = try LuaRuntime()
        let svc = FakeServices()
        // First a 500 (retryable), then a transport failure (nil), then 200.
        svc.httpSequence = [
            HTTPResponse(status: 500, body: "", headers: [:]),
            nil,
            HTTPResponse(status: 200, body: #"{"ok":true}"#, headers: [:]),
        ]
        try ExtensionHost(extensionID: "com.test", services: svc).install(into: lua)
        offMain {
            // retries=3 → up to 4 attempts; backoff tiny so the test is fast.
            try lua.run("""
            function t() local r = host.http.request{ url='https://x/api', retries=3, backoff=0.01 }
              if r == nil then return 'nil' end
              return tostring(r.status)..','..tostring(r.ok)
            end
            """)
            XCTAssertEqual(try lua.callGlobal("t"), "200,true")
        }
        XCTAssertEqual(svc.httpRequests.count, 3)  // 500, nil, 200
    }

    func testHttpExhaustsRetriesReturnsNilAndError() throws {
        let lua = try LuaRuntime()
        let svc = FakeServices()
        svc.httpResponses["https://x/api"] = HTTPResponse(status: 503, body: "", headers: [:])
        try ExtensionHost(extensionID: "com.test", services: svc).install(into: lua)
        offMain {
            try lua.run("""
            function t() local r, err = host.http.request{ url='https://x/api', retries=1, backoff=0.01 }
              return tostring(r ~= nil)..','..tostring(err)
            end
            """)
            // 503 stays 503 every attempt → resp returned with error string.
            XCTAssertEqual(try lua.callGlobal("t"), "true,http 503")
        }
        XCTAssertEqual(svc.httpRequests.count, 2)  // retries=1 → 2 attempts
    }

    func testHttpRejectsMissingURL() throws {
        let lua = try LuaRuntime()
        try ExtensionHost(extensionID: "com.test", services: FakeServices()).install(into: lua)
        offMain {
            try lua.run("function t() local r, e = host.http.request{} return tostring(r)..','..tostring(e) end")
            XCTAssertEqual(try lua.callGlobal("t"), "nil,missing url")
        }
    }

    // MARK: - currency system extension (async lane, host.http + host.prefs)

    /// In-repo system-extensions dir (…/app/Sources/ProsperApp/Resources/extensions).
    private func extensionsDir() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
    }

    @MainActor
    func testCurrencyExtensionConverts() async throws {
        let dir = extensionsDir()
        try XCTSkipIf(!FileManager.default.fileExists(atPath: dir.path), "extensions dir missing")

        let svc = FakeServices()
        svc.httpResponses["https://open.er-api.com/v6/latest/USD"] = HTTPResponse(
            status: 200,
            body: #"{"result":"success","rates":{"USD":1,"EUR":0.92,"GBP":0.8}}"#,
            headers: [:]
        )
        // Isolated defaults so the host.prefs cache doesn't leak across runs.
        let defaults = UserDefaults(suiteName: "currency-test-\(Int(svc.fixedEpoch))")!
        defaults.removePersistentDomain(forName: "currency-test-\(Int(svc.fixedEpoch))")

        let registry = ExtensionRegistry(
            systemDir: dir,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true),
            defaults: defaults,
            services: svc
        )
        registry.discover()
        try XCTSkipIf(registry.command(id: "currency.convert") == nil, "currency.convert not discovered")

        let raw = await registry.invokeAsync(commandID: "currency.convert", query: "32 usd to eur")
        XCTAssertEqual(raw, "29.44 EUR\t32 USD → EUR (rate 0.9200)")

        // Second conversion reuses the cached rates (one HTTP call total).
        let raw2 = await registry.invokeAsync(commandID: "currency.convert", query: "10 gbp to usd")
        XCTAssertEqual(raw2, "12.5 USD\t10 GBP → USD (rate 1.2500)")
        XCTAssertEqual(svc.httpRequests.count, 1, "rates must be fetched once and cached")

        // Declines: bad parse, unknown code.
        let bad = await registry.invokeAsync(commandID: "currency.convert", query: "hello world")
        XCTAssertNil(bad)
        let unknown = await registry.invokeAsync(commandID: "currency.convert", query: "5 xyz to eur")
        XCTAssertNil(unknown)
    }

    // MARK: - quicklinks system extension (async lane, host.shell + host.prefs)

    @MainActor
    func testQuicklinksAddListOpenRemove() async throws {
        let dir = extensionsDir()
        try XCTSkipIf(!FileManager.default.fileExists(atPath: dir.path), "extensions dir missing")

        let svc = FakeServices()
        let suite = "ql-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let registry = ExtensionRegistry(
            systemDir: dir,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true),
            defaults: defaults,
            services: svc
        )
        registry.discover()
        try XCTSkipIf(registry.command(id: "quicklinks.run") == nil, "quicklinks.run not discovered")

        // Add a URL quicklink with a {query} placeholder.
        let added = await registry.invokeAsync(commandID: "quicklinks.run",
                                               query: "ql add gh https://github.com/{query}")
        XCTAssertEqual(added, "Saved 'gh' → https://github.com/{query}")

        // List reflects the stored link.
        let listed = await registry.invokeAsync(commandID: "quicklinks.run", query: "ql list")
        XCTAssertEqual(listed, "gh → https://github.com/{query}")

        // Open substitutes + percent-encodes the argument into the URL target.
        // '/' stays literal so path-style targets (owner/repo) keep working.
        let opened = await registry.invokeAsync(commandID: "quicklinks.run",
                                                query: "ql gh anthropics/claude")
        XCTAssertEqual(opened, "Opening gh\thttps://github.com/anthropics/claude")

        // Unknown name reports rather than silently opening.
        let missing = await registry.invokeAsync(commandID: "quicklinks.run", query: "ql nope")
        XCTAssertEqual(missing, "No quicklink 'nope'. Add it: ql add nope <target>")

        // Remove deletes it; list is empty afterwards.
        let removed = await registry.invokeAsync(commandID: "quicklinks.run", query: "ql rm gh")
        XCTAssertEqual(removed, "Removed 'gh'")
        let emptyList = await registry.invokeAsync(commandID: "quicklinks.run", query: "ql list")
        XCTAssertEqual(emptyList, "No quicklinks yet. Add one: ql add <name> <target>")
    }

    // MARK: - window management system extension (host.window)

    @MainActor
    func testWindowManagementSnapsLayouts() async throws {
        let dir = extensionsDir()
        try XCTSkipIf(!FileManager.default.fileExists(atPath: dir.path), "extensions dir missing")

        let svc = FakeServices()
        // Visible frame {0,25,1440,875}; current window {100,100,600,400}.
        svc.windowFrame = WindowFrame(x: 100, y: 100, w: 600, h: 400,
                                      visibleX: 0, visibleY: 25, visibleW: 1440, visibleH: 875)
        let defaults = UserDefaults(suiteName: "win-test-\(UUID().uuidString)")!
        let registry = ExtensionRegistry(
            systemDir: dir,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true),
            defaults: defaults,
            services: svc
        )
        registry.discover()
        try XCTSkipIf(registry.command(id: "window.move") == nil, "window.move not discovered")

        func snap(_ q: String) async -> (Double, Double, Double, Double)? {
            _ = await registry.invokeAsync(commandID: "window.move", query: q)
            guard let last = svc.windowSets.last else { return nil }
            return (last.x, last.y, last.w, last.h)
        }

        // Left half.
        var r = await snap("win left")
        XCTAssertEqual(r?.0, 0); XCTAssertEqual(r?.1, 25)
        XCTAssertEqual(r?.2, 720); XCTAssertEqual(r?.3, 875)

        // Top-right quarter (h/2 = 437.5 rounds to 438).
        r = await snap("win top-right")
        XCTAssertEqual(r?.0, 720); XCTAssertEqual(r?.1, 25)
        XCTAssertEqual(r?.2, 720); XCTAssertEqual(r?.3, 438)

        // Maximize fills the visible frame.
        r = await snap("win max")
        XCTAssertEqual(r?.0, 0); XCTAssertEqual(r?.1, 25)
        XCTAssertEqual(r?.2, 1440); XCTAssertEqual(r?.3, 875)

        // Center preserves the window size (600×400), centred in the visible frame.
        r = await snap("win center")
        XCTAssertEqual(r?.0, 420); XCTAssertEqual(r?.1, 263)
        XCTAssertEqual(r?.2, 600); XCTAssertEqual(r?.3, 400)

        // Unknown layout reports without calling set.
        let before = svc.windowSets.count
        let unknown = await registry.invokeAsync(commandID: "window.move", query: "win wat")
        XCTAssertEqual(svc.windowSets.count, before, "unknown layout must not move the window")
        XCTAssertTrue(unknown?.hasPrefix("Unknown layout 'wat'") ?? false)
    }

    // MARK: - files system extension (Spotlight finder, declarative actions)

    @MainActor
    func testFilesExtensionRendersRowsWithActions() async throws {
        let dir = extensionsDir()
        try XCTSkipIf(!FileManager.default.fileExists(atPath: dir.path), "extensions dir missing")

        let svc = FakeServices()
        svc.filesResult = "[{\"name\":\"budget.pdf\",\"path\":\"/Users/me/budget.pdf\"," +
                          "\"display\":\"~/budget.pdf\",\"isDir\":false,\"kind\":\"PDF document\"}]"
        let registry = ExtensionRegistry(
            systemDir: dir,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true),
            defaults: UserDefaults(suiteName: "files-test-\(UUID().uuidString)")!,
            services: svc
        )
        registry.discover()
        try XCTSkipIf(registry.command(id: "files.run") == nil, "files.run not discovered")

        // The runner restores the "f " prefix before invoking the handler.
        let raw = await registry.invokeAsync(commandID: "files.run", query: "f kind:pdf budget")
        let out = try XCTUnwrap(raw)

        // Rendered as a rows-style list with the hit + its file actions.
        XCTAssertTrue(out.contains("\"type\":\"list\""))
        XCTAssertTrue(out.contains("\"style\":\"rows\""))
        XCTAssertTrue(out.contains("budget.pdf"))
        // host.ui.render is the native (JSONSerialization) encoder, which escapes
        // forward slashes — `~/budget.pdf` serialises as `~\/budget.pdf`. Valid
        // JSON; the runner decodes it back. Assert the rendered (escaped) form.
        XCTAssertTrue(out.contains("~\\/budget.pdf"))
        XCTAssertTrue(out.contains("PDF document"))
        for id in ["file.open", "file.reveal", "file.quicklook", "file.copyPath",
                   "file.copyFile", "file.trash"] {
            XCTAssertTrue(out.contains(id), "missing action \(id)")
        }
        // The Lua layer parsed the kind: filter and forwarded it structured.
        XCTAssertEqual(svc.fileSearches.count, 1)
        XCTAssertTrue(svc.fileSearches[0].contains("pdf"))
        XCTAssertTrue(svc.fileSearches[0].contains("budget"))
    }

    @MainActor
    func testFilesExtensionEmptyResultShowsNoMatchRow() async throws {
        let dir = extensionsDir()
        try XCTSkipIf(!FileManager.default.fileExists(atPath: dir.path), "extensions dir missing")

        let svc = FakeServices()  // filesResult defaults to "[]"
        let registry = ExtensionRegistry(
            systemDir: dir,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true),
            defaults: UserDefaults(suiteName: "files-test-\(UUID().uuidString)")!,
            services: svc
        )
        registry.discover()
        try XCTSkipIf(registry.command(id: "files.run") == nil, "files.run not discovered")

        let raw = await registry.invokeAsync(commandID: "files.run", query: "f zzzznope")
        let out = try XCTUnwrap(raw)
        XCTAssertTrue(out.contains("No files matching"))
        XCTAssertFalse(out.contains("file.open"))  // no action rows when empty
    }

    /// End-to-end over a mocked file system AND mocked UI interaction: the real
    /// `files` Lua extension parses `kind:` filters → `host.files.search` → the real
    /// engine over a `MockFileIndex`, the rendered rows are decoded, and the row's
    /// declared actions are dispatched through `FileActionDispatcher` with a mock
    /// performer (simulating the user pressing ⏎ / ⌘⏎). No live Spotlight, no window.
    @MainActor
    func testFilesExtensionFiltersByFormatAndDispatchesActions() async throws {
        let dir = extensionsDir()
        try XCTSkipIf(!FileManager.default.fileExists(atPath: dir.path), "extensions dir missing")

        let home = NSHomeDirectory()
        let now: TimeInterval = 1_700_000_000
        let mockIndex = MockFileIndex([
            FileSearchEngine.IndexedFile(path: "\(home)/Documents/Q3 Report.pdf",
                contentTypeTree: ["com.adobe.pdf", "public.data"], kind: "PDF document", modified: 300),
            FileSearchEngine.IndexedFile(path: "\(home)/Documents/Q3 chart.png",
                contentTypeTree: ["public.png", "public.image"], kind: "PNG image", modified: 250),
            FileSearchEngine.IndexedFile(path: "\(home)/Projects",
                contentTypeTree: ["public.folder"], isDir: true, kind: "Folder", modified: 150),
        ])
        let frecencyDefaults = UserDefaults(suiteName: "files-frecency-\(UUID().uuidString)")!
        let frecency = FrecencyStore(defaults: frecencyDefaults, storageKey: "k")

        let svc = FakeServices()
        svc.filesSearchHandler = { json in
            await FileSearchEngine.searchJSON(.decode(json: json),
                                              index: mockIndex, frecency: frecency, now: now)
        }
        let registry = ExtensionRegistry(
            systemDir: dir,
            userDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosper-ext-test-\(UUID().uuidString)", isDirectory: true),
            defaults: UserDefaults(suiteName: "files-test-\(UUID().uuidString)")!,
            services: svc
        )
        registry.discover()
        try XCTSkipIf(registry.command(id: "files.run") == nil, "files.run not discovered")

        // Lua parses `kind:pdf` and forwards it; the engine filters to the PDF only.
        let raw = await registry.invokeAsync(commandID: "files.run", query: "f kind:pdf Q3")
        let out = try XCTUnwrap(raw)
        XCTAssertTrue(out.contains("Q3 Report.pdf"))
        XCTAssertFalse(out.contains("Q3 chart.png"), "png filtered out by kind:pdf")
        XCTAssertFalse(out.contains("Projects"), "folder filtered out by kind:pdf")
        XCTAssertTrue(svc.fileSearches.first?.contains("pdf") == true)

        // Decode the rendered list and inspect the first row's declared actions.
        guard case .list(let list) = try ExtensionViewNode.decode(json: out) else {
            return XCTFail("expected a list node")
        }
        let first = try XCTUnwrap(list.items.first)
        XCTAssertEqual(first.title, "Q3 Report.pdf")
        XCTAssertEqual(first.launch, "\(home)/Documents/Q3 Report.pdf")  // path payload for actions
        let actions = first.allActions
        XCTAssertEqual(actions.first?.id, FileActions.ID.open)
        XCTAssertTrue(actions.contains { $0.id == FileActions.ID.reveal })

        // Mocked UI interaction: user hits ⏎ (primary = Open), then ⌘⏎ (secondary
        // = Reveal). Dispatch through the shared dispatcher with a mock performer.
        let performer = MockFileActionPerformer()
        let dispatcher = FileActionDispatcher(performer: performer, frecency: frecency)
        let path = try XCTUnwrap(first.launch)
        dispatcher.run(id: actions[0].id, path: path, now: now)  // ⏎ Open
        dispatcher.run(id: actions[1].id, path: path, now: now)  // ⌘⏎ Reveal

        XCTAssertEqual(performer.calls.map(\.id), [FileActions.ID.open, FileActions.ID.reveal])
        XCTAssertEqual(performer.calls.first?.path, "\(home)/Documents/Q3 Report.pdf")
        XCTAssertGreaterThan(frecency.boost(path: path, now: now), 0)  // engagements recorded
    }
}
