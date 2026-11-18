import XCTest
import LuaRuntime
@testable import ProsperApp

/// Records every host service that acts, holds, shows or writes. Nothing here runs a command, opens a URL,
/// launches an app, sends a key, writes a preference or touches the pasteboard: each one only appends its name.
private final class RetiredCallRecorder: ExtensionHostServices, @unchecked Sendable {
    private let lock = NSLock()
    private var _acted: [String] = []
    var acted: [String] { lock.lock(); defer { lock.unlock() }; return _acted }
    private func act(_ name: String) { lock.lock(); _acted.append(name); lock.unlock() }

    func clipboardRead() -> String? { "clip" }
    func clipboardWrite(_ text: String) { act("clipboardWrite") }
    func clipboardHistory(limit: Int) -> [String] { [] }
    func llmComplete(_ prompt: String) async -> String { act("llmComplete"); return "" }
    func llmTranslate(_ text: String, target: String, source: String?) async -> String { act("llmTranslate"); return "" }
    func llmChat(_ prompt: String) async -> String { act("llmChat"); return "" }
    func shellRun(_ command: String) async -> String { act("shellRun"); return "" }
    func shellRunCapped(_ command: String) async -> (text: String, truncated: Bool, exit: ShellRunner.Exit?) { act("shellRun"); return ("", false, .exit(0)) }
    func httpRequest(method: String, url: String, headers: [String: String],
                     body: String?, timeout: TimeInterval) async -> HTTPResponse? { act("httpRequest"); return nil }
    func currentEpochSeconds() -> Double { 0 }
    func focusedWindowFrame() -> WindowFrame? { nil }
    func setFocusedWindowFrame(x: Double, y: Double, width: Double, height: Double) -> Bool { act("windowSet"); return false }
    func prefGet(extensionID: String, key: String) -> String? { nil }
    func prefSet(extensionID: String, key: String, value: String) { act("prefSet") }
    func notify(title: String, body: String) { act("notify") }
    func listDirectories(_ path: String) -> [String] { [] }
    func processKill(pid: Int32, force: Bool) -> String? { act("processKill"); return "fake" }
    func snippetSave(json: String) { act("snippetSave") }
    func snippetRemove(name: String) { act("snippetRemove") }
    func snippetRemovePhone(deviceID: String) { act("snippetRemovePhone") }
    func snippetSetConfig(json: String) { act("snippetSetConfig") }
    func snippetSetCollections(json: String) { act("snippetSetCollections") }
    func snippetSetIgnored(json: String) { act("snippetSetIgnored") }
    func snippetImportFile() -> String { act("snippetImportFile"); return "" }
    func quicklinkSave(json: String) { act("quicklinkSave") }
    func filesAct(id: String, path: String) { act("filesAct") }
    func openWindow(extensionID: String, nodeJSON: String) { act("openWindow") }
    func closeWindow() { act("closeWindow") }
    func openSettings(extensionID: String, sectionID: String?, anchor: String?) { act("openSettings") }
    func timerSchedule(extensionID: String, id: String, every: Bool, seconds: Double, handler: String) { act("timerSchedule") }
    func timerCancel(extensionID: String, id: String) { act("timerCancel") }
    func caffeinatePreventIdleSleep(extensionID: String, kind: String, on: Bool) { act("idleSleep") }
    func caffeinateSetDisableLidSleep(extensionID: String, on: Bool) async { act("lidSleep") }
    func caffeinateSetRemoteWake(extensionID: String, enabled: Bool, deviceID: String, intervalAC: Double,
                                 intervalBatt: Double, batteryFloor: Int) async { act("remoteWake") }
    func caffeinateLockScreen() { act("lock") }
    func caffeinateStartScreensaver() { act("screensaver") }
    func caffeinateSleepNow() { act("sleepNow") }
    func menubarSet(extensionID: String, id: String, json: String) { act("menubarSet") }
    func menubarRemove(extensionID: String, id: String) { act("menubarRemove") }
    func dialogPrompt(json: String) async -> String? { act("dialogPrompt"); return nil }
    func dialogConfirm(json: String) async -> Bool { act("dialogConfirm"); return false }
    func alertShow(text: String, seconds: Double) { act("alertShow") }
    func managedConfigCall(_ op: String, owner: ManagedConfigOwner, json: String) async -> String { act("config"); return "{}" }
    func appLaunchOrFocus(_ nameOrBundleID: String) { act("appLaunch") }
    func appHide(bundleID: String) { act("appHide") }
    func runAppleScript(_ source: String) -> String { act("osascript"); return "{}" }
    func keyboardSetSource(_ id: String) -> Bool { act("kbdSet"); return false }
    func chooseApp() -> String { act("chooseApp"); return "" }
    func keysSetRules(extensionID: String, json: String) { act("keysRules") }
    func keysStroke(_ spec: String) { act("keysStroke") }
    func keysSystem(_ name: String) { act("keysSystem") }
    func urlOpen(_ url: String, bundleID: String?) -> Bool { act("urlOpen"); return false }
    func urlSetDefaultBrowser(_ bundleID: String) -> Bool { act("urlSetDefault"); return false }
    func fallbackSave(_ json: String) { act("fallbackSave") }
    func fallbackSetMode(_ on: Bool) { act("fallbackSetMode") }
    func fallbackImport() -> Int { act("fallbackImport"); return 0 }
    func fsWatch(extensionID: String, path: String, handler: String, hideSecrets: Bool) { act("fsWatch") }
    func fsUnwatch(extensionID: String, path: String) { act("fsUnwatch") }
    func menusPress(_ id: String) -> Bool { act("menusPress"); return false }
}

/// #1238 (N1238-a, A2): a call that a teardown (disable, untrust, reset, reinstall, uninstall) retired may still read, but every host
/// function that acts, holds, releases, shows or writes refuses it and gives what it gives when it declines.
final class ExtensionRetiredCallTests: XCTestCase {

    /// Every refused host function and what Lua sees from it for a retired call (`tostring` of the first result).
    /// A host function added to install(into:) fails testEveryHostFunctionIsClassed until it is placed here or
    /// among ExtensionHost.retiredReads.
    private static let gated: [String: String] = [
        "__h_clip_write": "nil", "__h_pref_set": "nil", "__h_notify": "nil", "__h_snippets_save": "nil",
        "__h_snippets_remove": "nil", "__h_snippets_remove_phone": "nil", "__h_snippets_set_config": "nil",
        "__h_snippets_set_collections": "nil", "__h_snippets_set_ignored": "nil", "__h_quicklink_save": "nil",
        "__h_files_act": "nil", "__h_window_open": "nil", "__h_window_close": "nil", "__h_settings_open": "nil",
        "__h_timer_schedule": "nil", "__h_timer_cancel": "nil", "__h_caf_idle": "nil", "__h_caf_lidsleep": "nil",
        "__h_caf_remotewake": "nil", "__h_caf_lock": "nil", "__h_caf_screensaver": "nil", "__h_caf_sleepnow": "nil",
        "__h_menubar_set": "nil", "__h_menubar_remove": "nil", "__h_alert_show": "nil", "__h_fallback_save": "nil",
        "__h_fallback_mode_set": "nil", "__h_app_launch": "nil", "__h_app_hide": "nil", "__h_keys_rules": "nil",
        "__h_keys_stroke": "nil", "__h_keys_system": "nil", "__h_fs_watch": "nil", "__h_fs_unwatch": "nil",
        "__h_shell_run": "", "__h_snippets_import_file": "", "__h_choose_app": "",
        "__h_llm_complete": "", "__h_llm_translate": "", "__h_llm_chat": "",
        "__h_window_set": "false", "__h_dialog_confirm": "false", "__h_url_open": "false", "__h_kbd_set": "false",
        "__h_url_set_default": "false", "__h_menus_press": "false",
        "__h_http_request": "nil", "__h_dialog_prompt": "nil", "__h_fallback_import": "0.0",
        "__h_proc_kill": "host.process: this call was stopped (the extension was turned off, untrusted, reset, reinstalled or removed)",
        "__h_osascript": #"{"ok":false,"error":"not permitted"}"#,
        "__h_config": ManagedConfigLua.inert("a"),
    ]

    /// #1242 (QA 998 R1238b-1): every host function a retired call may still make, as a literal: a function moved
    /// into ExtensionHost.retiredReads (or out of it) fails testEveryHostFunctionIsClassed until it is named here.
    private static let reads: Set<String> = [
        "__h_clip_read", "__h_clip_history", "__h_proc_refusal", "__h_window_frame", "__h_time", "__h_date",
        "__h_sleep", "__h_pref_get", "__h_perms_has", "__h_json_decode", "__h_json_encode", "__h_fs_list_dirs",
        "__h_apps_search", "__h_snippets_all", "__h_snippets_get", "__h_snippets_expand", "__h_snippets_phone",
        "__h_snippets_replacements", "__h_snippets_config", "__h_snippets_collections", "__h_snippets_ignored",
        "__h_quicklinks_all", "__h_files_search", "__h_timer_scheduled", "__h_log", "__h_env_get",
        "__h_battery_source", "__h_battery_pct", "__h_network_reachable", "__h_network_addresses",
        "__h_screen_all", "__h_screen_lid", "__h_dch_sessions", "__h_ccpool_status", "__h_app_frontmost",
        "__h_app_windows", "__h_kbd_current", "__h_kbd_layouts", "__h_url_default", "__h_fs_exists",
        "__h_fs_attrs", "__h_fallback_list", "__h_fallback_mode_get", "__h_fs_read", "__h_menus_list",
    ]

    /// The releasing host functions (A2): a retired call's release after a revive would drop the live take.
    private static let releases = ["__h_timer_cancel", "__h_caf_idle", "__h_caf_lidsleep", "__h_caf_remotewake",
                                   "__h_menubar_remove", "__h_keys_rules", "__h_fs_unwatch", "__h_window_close"]

    /// Installs the host into a fresh VM and re-exposes each registered closure as `t<name>` (the bootstrap hides
    /// the raw names). Returns the VM and every name install(into:) registered.
    private func installed(_ svc: RetiredCallRecorder, current: Bool, privileged: Bool = true,
                           trusted: Bool = true) throws -> (LuaRuntime, [String]) {
        let lua = try LuaRuntime()
        var registered: [(String, (LuaRuntime) -> Int32)] = []
        try ExtensionHost(extensionID: "com.test.retired", services: svc, privileged: privileged, trusted: trusted,
                          isCurrent: { current }).install(into: lua) { name, fn in registered.append((name, fn)) }
        for (name, fn) in registered { lua.register("t" + name, fn) }
        return (lua, registered.map { $0.0 })
    }

    private func call(_ lua: LuaRuntime, _ name: String) throws -> String {
        try lua.run("function probe() return tostring((t\(name)(\"a\", \"b\"))) end")
        return try lua.callGlobal("probe") ?? "<none>"
    }

    /// Every registered host function is either a read or refused for a retired call, on every tier, and the
    /// production table matches the literal list above (a function added later fails here until it is classed).
    func testEveryHostFunctionIsClassed() throws {
        XCTAssertEqual(Set(ExtensionHost.retiredRefusals.keys), Set(Self.gated.keys))
        XCTAssertEqual(ExtensionHost.retiredReads, Self.reads, "the read set moved")
        XCTAssertEqual(Self.reads.count, 45)
        XCTAssertTrue(ExtensionHost.retiredReads.isDisjoint(with: Self.gated.keys), "a function is both read and refused")
        XCTAssertTrue(Set(Self.releases).isSubset(of: Self.gated.keys), "a releasing function is not refused")
        for (privileged, trusted) in [(true, true), (false, true), (false, false)] {
            let (_, names) = try installed(RetiredCallRecorder(), current: false, privileged: privileged, trusted: trusted)
            XCTAssertEqual(Set(names).subtracting(ExtensionHost.retiredReads), Set(Self.gated.keys),
                           "unclassed or stale host functions (privileged \(privileged), trusted \(trusted))")
        }
    }

    /// A retired call reaches no service through any refused function and sees each one's decline value; a read
    /// still answers.
    func testRetiredCallActsOnNothing() throws {
        let svc = RetiredCallRecorder()
        let (lua, _) = try installed(svc, current: false)
        for name in Self.gated.keys.sorted() {
            XCTAssertEqual(try call(lua, name), Self.gated[name], name)
        }
        XCTAssertEqual(svc.acted, [], "a retired call acted")
        XCTAssertEqual(try call(lua, "__h_clip_read"), "clip", "a read was refused")
    }

    /// A current call still acts.
    func testCurrentCallStillActs() throws {
        let svc = RetiredCallRecorder()
        let (lua, _) = try installed(svc, current: true)
        XCTAssertEqual(try call(lua, "__h_pref_set"), "nil")
        XCTAssertEqual(svc.acted, ["prefSet"])
    }

    /// #1242 (N1238-c): a retired call starts no model job (CoreBridge keeps one job slot per kind and a new job
    /// cancels the live caller's); a current call still reaches each llm service.
    func testRetiredCallStartsNoModelJob() throws {
        let retired = RetiredCallRecorder()
        let (old, _) = try installed(retired, current: false)
        for name in ["__h_llm_complete", "__h_llm_translate", "__h_llm_chat"] {
            XCTAssertEqual(try call(old, name), "", name)
        }
        XCTAssertEqual(retired.acted, [], "a retired call started a model job")
        let live = RetiredCallRecorder()
        let (lua, _) = try installed(live, current: true)
        for name in ["__h_llm_complete", "__h_llm_translate", "__h_llm_chat"] { _ = try call(lua, name) }
        XCTAssertEqual(live.acted, ["llmComplete", "llmTranslate", "llmChat"])
    }

    /// #1242 (item 4): a teardown's resetResources asks the event tap to re-probe, so a switched-off extension stops
    /// being its active id. Only the recorder seam sees it: the shared EventTapHost's registry stays nil (no probe,
    /// no VM, no tap), the id holds no lid flag or assertion (no helper call), and the defaults are a scratch suite.
    @MainActor
    func testResetResourcesRefreshesTheEventTap() async {
        let tap = EventTapHost.shared
        XCTAssertTrue(tap.registry == nil, "a row left a registry on the shared EventTapHost")
        let seen = expectation(description: "refresh requested")
        var ids: [String] = []
        tap.onRefreshRequest = { ids.append($0); seen.fulfill() }
        defer { tap.onRefreshRequest = nil }
        LiveExtensionHostServices(defaults: scratchDefaults("retiredtap")).resetResources(extensionID: "com.test.tapreset")
        await fulfillment(of: [seen], timeout: 5)
        XCTAssertEqual(ids, ["com.test.tapreset"])
        XCTAssertFalse(tap.isActive)
    }
}
