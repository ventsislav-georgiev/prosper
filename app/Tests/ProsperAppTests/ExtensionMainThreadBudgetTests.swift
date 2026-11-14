import AppKit
import XCTest
import Foundation
import LuaRuntime
@testable import ProsperApp

/// Host services for the rows: inert, except `snippetExpand`, which resolves the keyword as a placeholder
/// name through the registry the way LiveExtensionHostServices.snippetExpand resolves a template's custom
/// tokens (the snippet store itself is not used). Every `resolvePlaceholder` answer is recorded.
private final class BudgetServices: ExtensionHostServices, @unchecked Sendable {
    weak var registry: ExtensionRegistry?
    var resolved: [String?] = []   // written on the main thread only (inside the MainActor VM's call)
    func clipboardRead() -> String? { nil }
    func clipboardWrite(_ text: String) {}
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { "" }
    func llmChat(_ prompt: String) async -> String { "" }
    func shellRun(_ command: String) async -> String { "" }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { nil }
    func currentEpochSeconds() -> Double { 0 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { false }
    func prefGet(extensionID: String, key: String) -> String? { nil }
    func prefSet(extensionID: String, key: String, value: String) {}
    func notify(title: String, body: String) {}
    func listDirectories(_ path: String) -> [String] { [] }
    func envGet(_ name: String) -> String? { nil }   // #1170: no environment reaches the extensions under count
    /// Called by the Lua host function on the thread running the call: the main thread for the MainActor VM
    /// (the only VM these rows use), so the main actor is asserted, as the live host's mainSync does inline.
    /// Off main (a lane VM) it answers "" instead of trapping.
    func snippetExpand(keyword: String, argsJSON: String?) -> String {
        guard Thread.isMainThread else { return "" }
        return MainActor.assumeIsolated {
            let value = registry?.resolvePlaceholder(name: keyword, raw: keyword)
            resolved.append(value)
            return value ?? ""
        }
    }
}

/// #1146 round 2, #1170 (F899-1): a converter transform the row answers by hand. Main actor: ConverterPanes calls it
/// there, and the row answers it there. No await in it can wait for ever: `answer` checks every call so far before it
/// answers and on a mismatch fails and releases; `settle` waits for an edit's task by turns and releases past the
/// ceiling. Released, every held call and every later one answers "" at once, so the pane's task ends.
@MainActor
private final class HeldTransform {
    /// Ceiling of main-actor turns for each wait; a count of turns, not a timer.
    private static let turns = 10_000
    private(set) var calls: [String] = []   // "fn:input", in call order
    private var waiting: [CheckedContinuation<String, Never>] = []
    private var released = false

    var transform: ConverterPanes.Transform {
        { fn, input in await self.call(fn, input) }   // main actor (the Transform type's isolation)
    }

    private func call(_ fn: String, _ input: String) async -> String {
        calls.append("\(fn):\(input)")
        if released { return "" }
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// Yields the main actor until `n` calls came, or the ceiling.
    func waitForCalls(_ n: Int) async {
        var turns = 0
        while calls.count < n && turns < Self.turns { turns += 1; await Task.yield() }
    }

    /// Answers the held call once exactly `expected` came, in that order, and exactly one is held. Anything else
    /// (a call added, missing or reordered, two held at once) fails here and releases every held call.
    func answer(_ expected: [String], _ out: String, file: StaticString = #filePath, line: UInt = #line) async {
        var turns = 0
        while (calls.count < expected.count || waiting.isEmpty) && turns < Self.turns { turns += 1; await Task.yield() }
        guard calls == expected, waiting.count == 1 else {
            XCTFail("calls \(calls) with \(waiting.count) held; expected \(expected) with 1 held", file: file, line: line)
            return release()
        }
        waiting.removeFirst().resume(returning: out)
    }

    /// Waits for an edit's task by turns. Past the ceiling it fails and releases, and then the task ends: its calls
    /// answer "" at once and the pane's loop takes one more turn only for an edit made during a call.
    func settle(_ task: Task<Void, Never>?, file: StaticString = #filePath, line: UInt = #line) async {
        guard let task else { return }
        let done = Done()
        Task { @MainActor in await task.value; done.flag = true }   // main actor, like the row
        var turns = 0
        while !done.flag && turns < Self.turns { turns += 1; await Task.yield() }
        if !done.flag {
            XCTFail("the edit's task never ended: a transform call was not answered (\(calls))", file: file, line: line)
            release()
        }
        await task.value
    }

    /// Answers "" to every held call and to every later one. Each row's teardown calls it.
    func release() {
        released = true
        let held = waiting
        waiting = []
        for c in held { c.resume(returning: "") }
    }
}

@MainActor
private final class Done { var flag = false }

/// #1146: every call the registry makes into an extension on the main thread runs on an explicit instruction
/// budget, so one runaway call holds the UI only for that budget. One row per path: a handler that runs
/// `spin` instructions (more than the path's budget, less than the 10,000,000 default) must be cut, and a
/// cheap one must not. Each loop is bounded (`spin` empty iterations), so with a budget back at the default
/// the call ends on its own. The registry and the extension live in the row's own temp dir.
@MainActor
final class ExtensionMainThreadBudgetTests: XCTestCase {

    private static let extID = "com.example.budget"
    /// Instructions a "spinning" handler runs: above every main-thread budget, below the default.
    private static let spin = 4_000_000
    private static let cheap = 1_000

    private static let manifest = """
    [extension]
    id = "\(extID)"
    name = "budget"
    title = "Budget"
    description = "A test extension"
    version = "1.0.0"
    author = "tester"

    [extension.host]
    min_version = "2.0.0"
    api_level = 1
    event_taps = true

    [extension.entry]
    main = "init.lua"

    [[contributes.commands]]
    id = "budget.run"
    title = "Run Budget"
    mode = "no-view"
    match = "^budget"

    [[contributes.placeholders]]
    name = "budgetph"
    handler = "budget_ph"
    """

    /// `spin(n)` runs about n instructions (one per empty loop iteration). `cfg` holds the spins the
    /// placeholder and the event-tap globals run, set through budget_set("name=n").
    private static let script = """
    local cfg = { ph = 0, probe = 0, dispatch = 0 }
    local function spin(n) for i = 1, n do end end
    function budget_set(kv)
        local k, v = kv:match("^(%a+)=(%d+)$")
        cfg[k] = tonumber(v)
        return "ok"
    end
    function budget_run(q)
        local mode, n = q:match("^(%a+) (%d+)$")
        n = tonumber(n)
        if mode == "spin" then spin(n); return "done" end
        if mode == "chain" then
            cfg.ph = n
            spin(n)
            return "outer:" .. host.snippets.expand("budgetph")
        end
        return nil
    end
    function budget_spin(arg) spin(tonumber(arg)); return "done" end
    function budget_ph(raw) spin(cfg.ph); return "ph" end
    function hs_eventtap_probe() spin(cfg.probe); return "keyDown" end
    function hs_eventtap_dispatch(payload) spin(cfg.dispatch); return "true" end
    """

    private func makeRegistry(_ label: String, script: String = ExtensionMainThreadBudgetTests.script)
        throws -> (ExtensionRegistry, BudgetServices) {
        let user = tempDir(label).appendingPathComponent("user")
        let dir = user.appendingPathComponent(Self.extID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.manifest.write(to: dir.appendingPathComponent("extension.toml"), atomically: true, encoding: .utf8)
        try script.write(to: dir.appendingPathComponent("init.lua"), atomically: true, encoding: .utf8)
        let services = BudgetServices()
        let registry = ExtensionRegistry(systemDir: nil, userDir: user, hostVersion: "2.0.0",
                                         defaults: scratchDefaults("main-budget"), services: services)
        services.registry = registry
        registry.discover()
        try registry.trust(id: Self.extID)
        return (registry, services)
    }

    private func set(_ registry: ExtensionRegistry, _ kv: String) {
        XCTAssertEqual(registry.callExtensionString(extensionID: Self.extID, function: "budget_set", arg: kv), "ok")
    }

    /// The spin sits between the budget under test and the default, so the row tells the two apart.
    private func assertBetween(_ budget: Int32, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(Int(budget), Self.spin, "budget no longer below the row's spin", file: file, line: line)
        XCTAssertLessThan(Self.spin, Int(LuaRuntime.defaultInstructionBudget) - 100_000, file: file, line: line)
    }

    // MARK: - activate (host bootstraps + entry chunk)

    func testActivationRunsOnTheLoadBudget() throws {
        assertBetween(ExtensionRegistry.MainThreadBudget.load)
        let spinning = Self.script + "\nfor i = 1, \(Self.spin) do end\n"
        let (registry, _) = try makeRegistry("activate-spin", script: spinning)
        XCTAssertTrue(registry.invokeSync(commandID: "budget.run", query: "spin \(Self.cheap)") == nil,
                      "an entry chunk past the load budget must not activate")
        XCTAssertTrue(registry.record(id: Self.extID)?.runtime == nil, "no VM is kept for a cut activation")

        let (fine, _) = try makeRegistry("activate-cheap")
        XCTAssertEqual(fine.invokeSync(commandID: "budget.run", query: "spin \(Self.cheap)"), "done")
    }

    // MARK: - invokeSync (launcher calc / units)

    func testInvokeSyncRunsOnTheCommandBudget() throws {
        assertBetween(ExtensionRegistry.MainThreadBudget.command)
        let (registry, _) = try makeRegistry("invoke")
        XCTAssertEqual(registry.invokeSync(commandID: "budget.run", query: "spin \(Self.cheap)"), "done")
        XCTAssertTrue(registry.invokeSync(commandID: "budget.run", query: "spin \(Self.spin)") == nil,
                      "a command past its budget must be cut")
        // The VM survives a cut call; the next one starts with a full budget.
        XCTAssertEqual(registry.invokeSync(commandID: "budget.run", query: "spin \(Self.cheap)"), "done")
    }

    // MARK: - callExtensionString with no budget given (converter pane transforms)

    func testCallExtensionStringDefaultsToTheCallBudget() throws {
        assertBetween(ExtensionRegistry.MainThreadBudget.call)
        let (registry, _) = try makeRegistry("transform")
        XCTAssertEqual(registry.callExtensionString(extensionID: Self.extID, function: "budget_spin",
                                                    arg: "\(Self.cheap)"), "done")
        XCTAssertTrue(registry.callExtensionString(extensionID: Self.extID, function: "budget_spin",
                                                   arg: "\(Self.spin)") == nil,
                      "a transform past its budget must be cut")
    }

    // MARK: - resolvePlaceholder (snippet expansion), as the outermost call

    func testPlaceholderRunsOnTheCallBudget() throws {
        assertBetween(ExtensionRegistry.MainThreadBudget.call)
        let (registry, _) = try makeRegistry("placeholder")
        set(registry, "ph=\(Self.cheap)")
        XCTAssertEqual(registry.resolvePlaceholder(name: "budgetph", raw: "budgetph"), "ph")
        set(registry, "ph=\(Self.spin)")
        XCTAssertTrue(registry.resolvePlaceholder(name: "budgetph", raw: "budgetph") == nil,
                      "a placeholder handler past its budget must be cut")
    }

    // MARK: - EventTapHost (called as functions; no tap is installed and no event is posted)

    /// Points the shared EventTapHost at `registry` for `body`, then leaves it as found: an empty registry's
    /// refresh clears the gates and the active id, and the previous registry and hook are put back.
    private func withTapHost(_ registry: ExtensionRegistry, _ body: (EventTapHost) -> Void) {
        let host = EventTapHost.shared
        let previousRegistry = host.registry, previousHook = host.onActiveChanged
        let empty = ExtensionRegistry(systemDir: nil, userDir: tempDir("tap-empty"), hostVersion: "2.0.0",
                                      defaults: scratchDefaults("main-budget-empty"), services: BudgetServices())
        host.onActiveChanged = nil
        host.registry = registry
        body(host)
        host.registry = empty
        host.refresh()
        host.registry = previousRegistry
        host.onActiveChanged = previousHook
        XCTAssertFalse(host.isActive)
    }

    /// The probe passes no budget: callExtensionString's default, the call budget.
    func testEventTapProbeRunsOnTheCallBudget() throws {
        assertBetween(ExtensionRegistry.MainThreadBudget.call)
        let (registry, _) = try makeRegistry("tap-probe")
        withTapHost(registry) { host in
            set(registry, "probe=\(Self.spin)")
            host.refresh()
            XCTAssertFalse(host.wantsKeyDown, "a probe past its budget must be cut and leave the tap off")
            set(registry, "probe=\(Self.cheap)")
            host.refresh()
            XCTAssertTrue(host.wantsKeyDown, "a cheap probe turns the keyDown gate on")
        }
    }

    func testEventTapDispatchRunsOnTheDispatchBudget() throws {
        assertBetween(EventTapHost.dispatchInstructionBudget)
        let (registry, _) = try makeRegistry("tap-dispatch")
        withTapHost(registry) { host in
            host.refresh()
            XCTAssertTrue(host.wantsKeyDown)
            set(registry, "dispatch=\(Self.cheap)")
            XCTAssertTrue(host.handleKeyDown(keyCode: 0, cmd: false, alt: false, ctrl: false, shift: false, fn: false))
            set(registry, "dispatch=\(Self.spin)")
            XCTAssertFalse(host.handleKeyDown(keyCode: 0, cmd: false, alt: false, ctrl: false, shift: false, fn: false),
                           "a dispatch past its budget must be cut and fail open")
        }
    }

    // MARK: - R1146-1: host.snippets.expand back into the same VM

    /// The command spins n, calls host.snippets.expand, whose placeholder handler (this same extension, same
    /// VM) spins n again. Under one budget for the whole call, 2 x 0.3 of the command budget fits and
    /// 2 x 0.6 does not, although each half alone fits: the inner call ran on what the outer call had left.
    func testSnippetExpandBackIntoTheSameVMEndsOnOneBudget() throws {
        let budget = Int(ExtensionRegistry.MainThreadBudget.command)
        // 1.2 x the budget must still be below the default, or the default would cut the chain too.
        XCTAssertLessThan(budget * 12 / 10, Int(LuaRuntime.defaultInstructionBudget) - 100_000)
        let (registry, services) = try makeRegistry("chain")

        XCTAssertEqual(registry.invokeSync(commandID: "budget.run", query: "chain \(budget * 3 / 10)"), "outer:ph")
        XCTAssertEqual(services.resolved, ["ph"])

        services.resolved = []
        XCTAssertTrue(registry.invokeSync(commandID: "budget.run", query: "chain \(budget * 6 / 10)") == nil,
                      "the chain must end on the command's one budget")
        XCTAssertEqual(services.resolved, [nil], "the placeholder call ran on what was left and was cut")
        // Each half alone fits the budget: the cut came from sharing it.
        XCTAssertEqual(registry.invokeSync(commandID: "budget.run", query: "spin \(budget * 6 / 10)"), "done")
    }

    // MARK: - Round 2: the converter pane's transform runs on the extension's background lane

    private func converter(left: String?, right: String?) throws -> ConverterNode {
        let pane = { (v: String?) in v.map { "{\"value\":\"\($0)\"}" } ?? "{}" }
        let json = "{\"left\":\(pane(left)),\"right\":\(pane(right)),\"forward\":\"fwd\",\"backward\":\"back\"}"
        return try JSONDecoder().decode(ConverterNode.self, from: Data(json.utf8))
    }

    /// A held transform whose held calls are released at teardown, so a row that fails early leaves nothing waiting.
    private func makeHeld() -> HeldTransform {
        let held = HeldTransform()
        addTeardownBlock { @MainActor in held.release() }
        return held
    }

    /// Edits typed while one transform call runs, in the converter's live shape.
    private static let burst = 20

    /// #1170 item 4: a burst of edits made while one call runs costs two transform calls (the running one and the
    /// newest text), not one per edit, and the newest edit's answer stands.
    func testConverterBurstOfEditsRunsTwoTransformCalls() async throws {
        let held = makeHeld()
        let panes = ConverterPanes(node: try converter(left: nil, right: nil), transform: held.transform)
        let first = try XCTUnwrap(panes.edit(left: true, "a"))
        await held.waitForCalls(1)
        var text = "a"
        for _ in 0..<Self.burst {
            text += "b"
            XCTAssertTrue(panes.edit(left: true, text) != nil)
        }
        await held.answer(["fwd:a"], "stale")
        await held.answer(["fwd:a", "fwd:\(text)"], text.uppercased())
        await held.settle(first)
        XCTAssertEqual(panes.right, text.uppercased(), "the newest edit's answer stands")
        XCTAssertEqual(held.calls.count, 2, "\(Self.burst + 1) edits, two transform calls")
    }

    /// Across sides: a left edit's answer that comes back after a right edit is dropped (it would overwrite the pane
    /// being typed in) and the right edit is converted next. Edits made before the call starts cost one call.
    func testConverterLatestEditWins() async throws {
        let held = makeHeld()
        let panes = ConverterPanes(node: try converter(left: nil, right: nil), transform: held.transform)
        let left = try XCTUnwrap(panes.edit(left: true, "abc"))
        await held.waitForCalls(1)
        XCTAssertTrue(panes.edit(left: false, "xyz") != nil)
        await held.answer(["fwd:abc"], "ABC")
        await held.answer(["fwd:abc", "back:xyz"], "decoded")
        await held.settle(left)
        XCTAssertEqual(panes.left, "decoded")
        XCTAssertEqual(panes.right, "xyz", "a stale answer never overwrites the other side's newer edit")

        let quick = try XCTUnwrap(panes.edit(left: true, "q"))
        XCTAssertTrue(panes.edit(left: true, "qr") != nil)
        await held.answer(["fwd:abc", "back:xyz", "fwd:qr"], "QR")
        await held.settle(quick)
        XCTAssertEqual(panes.right, "QR")
    }

    /// The seed converts once; the answer written into the other pane, set back through the pane's binding,
    /// is no edit (no echo); a cut or failed transform ("") leaves the other pane empty. F899-1: a call added or
    /// reordered here (the echo guard or the once-guard dropped) fails as an assertion, never a hang.
    func testConverterSeedsOnceAndDoesNotEcho() async throws {
        let held = makeHeld()
        let panes = ConverterPanes(node: try converter(left: "hi", right: nil), transform: held.transform)
        let seed = try XCTUnwrap(panes.seed())
        XCTAssertTrue(panes.seed() == nil, "the seed runs once")
        await held.answer(["fwd:hi"], "aGk=")
        await held.settle(seed)
        XCTAssertEqual(panes.left, "hi")
        XCTAssertEqual(panes.right, "aGk=")

        XCTAssertTrue(panes.edit(left: false, "aGk=") == nil, "the answer coming back is no edit")
        XCTAssertTrue(panes.edit(left: true, "hi") == nil)
        await held.waitForCalls(2)   // the turn ceiling: room for an echo call to show
        XCTAssertEqual(held.calls, ["fwd:hi"], "no echo transform")

        let bad = try XCTUnwrap(panes.edit(left: false, "not base64"))
        await held.answer(["fwd:hi", "back:not base64"], "")
        await held.settle(bad)
        XCTAssertEqual(panes.left, "", "a cut or failed transform empties the other pane")

        let given = ConverterPanes(node: try converter(left: "hi", right: "given"), transform: held.transform)
        XCTAssertTrue(given.seed() == nil, "a declared right pane is not converted")
        XCTAssertEqual(given.right, "given")
    }

    /// The shipped base64 extension converts 100 KB through the transform the presenter hands the window
    /// (AppDelegate.presentExtensionView): about 2.1M instructions to encode, above the main-thread call
    /// budget, inside the background lane's. Offscreen: the panel's on-screen calls are a counter and the
    /// window is never shown.
    func testBase64PaneConverts100KBOnTheBackgroundLane() async throws {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ProsperApp/Resources/extensions/base64", isDirectory: true)
        try XCTSkipIf(!FileManager.default.fileExists(atPath: src.path), "no in-repo base64 extension")
        let root = tempDir("base64-lane")
        let system = root.appendingPathComponent("system")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: system.appendingPathComponent("base64"))
        let registry = ExtensionRegistry(systemDir: system, userDir: root.appendingPathComponent("user"),
                                         hostVersion: "2.0.0", defaults: scratchDefaults("main-budget-b64"),
                                         services: BudgetServices())
        registry.discover()

        DockPolicy.resetForTesting(setPolicy: { _ in })
        let panel = ExtensionViewPanel()
        var shows = 0
        panel.onScreen = { _ in shows += 1 }   // main actor (the panel calls it from present)
        addTeardownBlock { @MainActor in
            panel.window?.close()
            panel.window?.contentViewController = nil
            DockPolicy.resetForTesting()
        }
        let ext = "com.prosper.base64"
        AppDelegate.presentExtensionView(extID: ext, node: .spinner("Base64"), registry: registry, panel: panel)
        XCTAssertEqual(shows, 1, "on screen through the seam only")
        XCTAssertFalse(panel.window?.isVisible ?? true, "never on screen")
        let host = try XCTUnwrap(panel.window?.contentViewController as? ExtensionViewHostController)
        let transform = try XCTUnwrap(host.transform)

        let input = String(repeating: "abcdefghij", count: 10_240)   // 102,400 bytes
        let encoded = Data(input.utf8).base64EncodedString()
        XCTAssertGreaterThan(input.utf8.count * 20, Int(ExtensionRegistry.MainThreadBudget.call),
                             "the input no longer costs more than the main-thread call budget")
        let panes = ConverterPanes(node: try converterBase64(), transform: transform)
        let edit = try XCTUnwrap(panes.edit(left: true, input))
        await edit.value
        XCTAssertEqual(panes.right.count, encoded.count, "100 KB must convert, not come back cut (empty)")
        XCTAssertTrue(panes.right == encoded)
        let decoded = await transform("b64_decode", encoded)
        XCTAssertTrue(decoded == input, "and back")
    }

    private func converterBase64() throws -> ConverterNode {
        let json = "{\"left\":{},\"right\":{},\"forward\":\"b64_encode\",\"backward\":\"b64_decode\"}"
        return try JSONDecoder().decode(ConverterNode.self, from: Data(json.utf8))
    }

    // MARK: - #1170 items 1 and 5: what the shipped extensions cost on the main thread, in instructions

    /// Smallest budget under which `attempt` ends (returns or throws anything but a spent budget), to 0.5 %, and the
    /// error it ended with at the default budget; nil when the default budget is spent. Bisection between 0 and the
    /// default: at most 24 attempts.
    private func minimumBudget(_ attempt: (Int32) throws -> Void) -> (count: Int, error: String?)? {
        let spent = LuaRuntime.LuaError.runtime("execution budget exceeded")
        func end(_ budget: Int32) -> (fits: Bool, error: String?) {
            do { try attempt(budget); return (true, nil) }
            catch let error as LuaRuntime.LuaError where error == spent { return (false, nil) }
            catch { return (true, String(describing: error)) }
        }
        var lo: Int32 = 0, hi = LuaRuntime.defaultInstructionBudget
        let full = end(hi)
        guard full.fits else { return nil }
        while hi - lo > max(16, lo / 200) {
            let mid = lo + (hi - lo) / 2
            if end(mid).fits { hi = mid } else { lo = mid }
        }
        return (Int(hi), full.error)
    }

    /// A runtime of the row's own with `record`'s host installed as ExtensionRegistry.activate installs it (the two
    /// host bootstraps run, each its own call on `budget`), inert services.
    private func installed(_ record: ExtensionRecord, budget: Int32 = LuaRuntime.defaultInstructionBudget) throws
        -> LuaRuntime {
        let rt = try LuaRuntime(maxInstructions: budget, allowLoad: true)
        try ExtensionHost(extensionID: record.id, services: BudgetServices(), privileged: record.privileged,
                          trusted: true, configOwner: record.loaded.managedConfigOwner).install(into: rt)
        return rt
    }

    /// `record`'s entry chunk compiled as the body of a global function (same locals, upvalues and `...`), so one
    /// call on `budget` runs exactly the chunk. Returns the loaded runtime, for the command counts.
    @discardableResult
    private func runEntry(_ record: ExtensionRecord, budget: Int32) throws -> LuaRuntime {
        let rt = try installed(record)
        let source = try String(contentsOf: record.loaded.entryURL, encoding: .utf8)
        try rt.run("function __entry1170(...) " + source + "\nend", name: "@\(record.id)")
        try rt.callGlobal("__entry1170", [], budget: budget)
        return rt
    }

    /// Counts, in a registry and runtimes of the row's own (the shipped extensions of this checkout, the Marketplace
    /// example from a copy; inert services, no network, nothing shown): the instructions each entry chunk needs, the
    /// host bootstraps, and one launcher keystroke (calc, then units: the only main-thread Lua CommandRouter runs).
    /// Asserts each load fits the load budget and one keystroke, first activations included, fits one command budget:
    /// the numbers that decide no cap per pass is needed (report of #1170). The counts are printed as BUDGET1170 lines.
    func testShippedExtensionsLoadAndKeystrokeCounts() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let system = app.appendingPathComponent("Sources/ProsperApp/Resources/extensions", isDirectory: true)
        let example = app.appendingPathComponent("Examples/extensions/hammerspoon-compat", isDirectory: true)
        try XCTSkipIf(!FileManager.default.fileExists(atPath: system.path), "no in-repo extensions")
        let user = tempDir("counts").appendingPathComponent("user")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: example, to: user.appendingPathComponent("hammerspoon-compat"))
        let registry = ExtensionRegistry(systemDir: system, userDir: user, hostVersion: "2.0.0",
                                         defaults: scratchDefaults("main-budget-counts"), services: BudgetServices())
        registry.discover()
        XCTAssertGreaterThan(registry.records.count, 50, "the shipped extensions and the example were discovered")
        let loadBudget = Int(ExtensionRegistry.MainThreadBudget.load)

        let anyRecord = try XCTUnwrap(registry.records.first)
        let boot = try XCTUnwrap(minimumBudget { _ = try self.installed(anyRecord, budget: $0) })
        let bootstrap = boot.count
        XCTAssertTrue(boot.error == nil, "the host bootstraps end with \(boot.error ?? "")")
        print("BUDGET1170 bootstrap (larger of the two host chunks) \(bootstrap)")
        XCTAssertLessThan(bootstrap, loadBudget)

        var entries: [String: Int] = [:]
        for record in registry.records {
            let measured = minimumBudget { _ = try self.runEntry(record, budget: $0) }
            XCTAssertTrue(measured != nil, "\(record.id)'s entry chunk spends the default budget")
            guard let m = measured else { continue }
            entries[record.id] = m.count
            print("BUDGET1170 entry \(record.id) \(m.count)" + (m.error.map { " (ended with \($0))" } ?? ""))
            XCTAssertLessThan(m.count, loadBudget, "\(record.id)'s entry chunk no longer fits the main-thread load budget")
        }
        let largest = entries.max { $0.value < $1.value }
        print("BUDGET1170 entries measured \(entries.count) of \(registry.records.count), sum \(entries.values.reduce(0, +)),"
              + " largest \(largest?.key ?? "-") \(largest?.value ?? 0)")

        // One launcher keystroke: calc.eval, and unit.convert when calc declines (CommandRouter.swift, steps 1 and 2).
        let commandBudget = Int(ExtensionRegistry.MainThreadBudget.command)
        var keystroke: [(LuaRuntime, String, Int)] = []
        for id in ["calc.eval", "unit.convert"] {
            let (record, command) = try XCTUnwrap(registry.command(id: id))
            keystroke.append((try runEntry(record, budget: LuaRuntime.defaultInstructionBudget),
                              ExtensionRegistry.handlerName(for: command.id), entries[record.id] ?? loadBudget))
        }
        let queries = ["128*24", "5 km to mi", String(repeating: "12+", count: 85) + "1",
                       "5 km to mi " + String(repeating: "x", count: 245)]
        for q in queries {
            var calls = 0, loads = 0
            for (rt, handler, entry) in keystroke {
                let call = try XCTUnwrap(minimumBudget { _ = try rt.callGlobal(handler, [q], budget: $0) })
                XCTAssertTrue(call.error == nil, "\(handler)(\(q.prefix(16))) ends with \(call.error ?? "")")
                calls += call.count
                loads += entry + 2 * bootstrap   // an upper bound for the two host chunks
            }
            print("BUDGET1170 keystroke \(q.count) chars: calls \(calls), with both first activations \(calls + loads)")
            XCTAssertLessThan(calls + loads, commandBudget,
                              "one keystroke over calc and units no longer fits one command budget")
        }
    }
}
