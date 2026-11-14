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
    /// Called by the Lua host function on the thread running the call: the main thread for the MainActor VM
    /// (the only VM these rows use), so the main actor is asserted, as the live host's mainSync does inline.
    func snippetExpand(keyword: String, argsJSON: String?) -> String {
        MainActor.assumeIsolated {
            let value = registry?.resolvePlaceholder(name: keyword, raw: keyword)
            resolved.append(value)
            return value ?? ""
        }
    }
}

/// #1146 round 2: a converter transform whose answers the row hands back by hand, in any order. Main actor:
/// ConverterPanes calls it there, and the row resolves it there.
@MainActor
private final class HeldTransform {
    private(set) var calls: [String] = []   // "fn:input"
    private var waiting: [CheckedContinuation<String, Never>] = []

    var transform: ConverterPanes.Transform {
        { fn, input in await self.call(fn, input) }   // main actor (the Transform type's isolation)
    }

    private func call(_ fn: String, _ input: String) async -> String {
        calls.append("\(fn):\(input)")
        return await withCheckedContinuation { waiting.append($0) }
    }

    /// Yields the main actor until `n` calls wait; a ceiling, not a timer.
    func waitForCalls(_ n: Int) async {
        var turns = 0
        while waiting.count < n && turns < 10_000 { turns += 1; await Task.yield() }
    }

    func answer(_ i: Int, _ out: String, file: StaticString = #filePath, line: UInt = #line) {
        guard i < waiting.count else { return XCTFail("call \(i) never came", file: file, line: line) }
        waiting[i].resume(returning: out)
    }
}

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
    function budget_run_action(actionID, value, formJSON)
        spin(tonumber(value))
        return '{"type":"list","title":"done","items":[]}'
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

    // MARK: - dispatchAction (view actions on the MainActor VM)

    func testDispatchActionRunsOnTheCommandBudget() throws {
        assertBetween(ExtensionRegistry.MainThreadBudget.command)
        let (registry, _) = try makeRegistry("action")
        XCTAssertTrue(registry.dispatchAction(commandID: "budget.run", actionID: "go", value: "\(Self.cheap)",
                                              formValues: [:]) != nil)
        XCTAssertTrue(registry.dispatchAction(commandID: "budget.run", actionID: "go", value: "\(Self.spin)",
                                              formValues: [:]) == nil, "an action past its budget must be cut")
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

    /// Answers arriving out of order, on one side and across sides: the newest edit's answer stands.
    func testConverterLatestEditWins() async throws {
        let held = HeldTransform()
        let panes = ConverterPanes(node: try converter(left: nil, right: nil), transform: held.transform)
        let first = try XCTUnwrap(panes.edit(left: true, "a"))
        let second = try XCTUnwrap(panes.edit(left: true, "ab"))
        await held.waitForCalls(2)
        held.answer(1, "AB")
        await second.value
        XCTAssertEqual(panes.right, "AB")
        held.answer(0, "A")
        await first.value
        XCTAssertEqual(panes.right, "AB", "a stale answer never overwrites a newer one")

        // A left edit, then a right edit: the left one's answer would overwrite the pane being typed in.
        let left = try XCTUnwrap(panes.edit(left: true, "abc"))
        let right = try XCTUnwrap(panes.edit(left: false, "xyz"))
        await held.waitForCalls(4)
        held.answer(2, "ABC")
        await left.value
        XCTAssertEqual(panes.right, "xyz", "a stale answer never overwrites the other side's newer edit")
        held.answer(3, "decoded")
        await right.value
        XCTAssertEqual(panes.left, "decoded")
        XCTAssertEqual(panes.right, "xyz")
        XCTAssertEqual(held.calls, ["fwd:a", "fwd:ab", "fwd:abc", "back:xyz"])
    }

    /// The seed converts once; the answer written into the other pane, set back through the pane's binding,
    /// is no edit (no echo); a cut or failed transform ("") leaves the other pane empty.
    func testConverterSeedsOnceAndDoesNotEcho() async throws {
        let held = HeldTransform()
        let panes = ConverterPanes(node: try converter(left: "hi", right: nil), transform: held.transform)
        let seed = try XCTUnwrap(panes.seed())
        XCTAssertTrue(panes.seed() == nil, "the seed runs once")
        await held.waitForCalls(1)
        held.answer(0, "aGk=")
        await seed.value
        XCTAssertEqual(panes.left, "hi")
        XCTAssertEqual(panes.right, "aGk=")

        XCTAssertTrue(panes.edit(left: false, "aGk=") == nil, "the answer coming back is no edit")
        XCTAssertTrue(panes.edit(left: true, "hi") == nil)
        XCTAssertEqual(held.calls, ["fwd:hi"], "no echo transform")

        let bad = try XCTUnwrap(panes.edit(left: false, "not base64"))
        await held.waitForCalls(2)
        held.answer(1, "")
        await bad.value
        XCTAssertEqual(panes.left, "", "a cut or failed transform empties the other pane")
        XCTAssertEqual(held.calls, ["fwd:hi", "back:not base64"])

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
}
