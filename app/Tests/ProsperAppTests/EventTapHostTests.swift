import XCTest
import Foundation
import LuaRuntime
@testable import ProsperApp

/// Contract tests for the resident-VM eventtap path: the REAL hammerspoon-compat
/// `init.lua` is loaded into a Lua runtime and its `hs_eventtap_probe` /
/// `hs_eventtap_dispatch` globals are driven exactly as `EventTapHost` drives them.
///
/// `host.*` is a minimal Lua stub wired to a few native shims (prefs/fs/json/log/
/// keys) — enough for the eventtap code path without standing up the full host. The
/// synthetic user config mirrors the common Hammerspoon idioms: dictation-swallow
/// (F5 / fn+D) on keyDown and a media remap on systemDefined.
final class EventTapHostTests: XCTestCase {

    /// A user `~/.hammerspoon/init.lua` exercising both tap event types.
    private static let userConfig = """
    local tap = hs.eventtap.new(
        { hs.eventtap.event.types.keyDown, hs.eventtap.event.types.systemDefined },
        function(e)
            local t = e:getType()
            if t == hs.eventtap.event.types.keyDown then
                local name = hs.keycodes.map[e:getKeyCode()]
                if name == "f5" then return true end                 -- swallow dictation
                if name == "d" and e:getFlags().fn then return true end -- fn+D dictation
                return false
            else
                local sk = e:systemKey()
                if sk.down and sk.key == "PLAY" then
                    hs.eventtap.event.newSystemKeyEvent("FAST", true):post()
                    return true
                end
                return false
            end
        end)
    tap:start()
    """

    /// Build a runtime with the real facade loaded + a stub `host`. `config` is what
    /// `host.fs.read` returns; `enabled` backs `host.prefs.get("enabled")`.
    private func makeRuntime(config: String?, enabled: Bool = true) throws -> (LuaRuntime, () -> [String]) {
        let lua = try LuaRuntime(allowLoad: true)
        var injected: [String] = []   // media keys injected via host.keys.system

        lua.register("__t_pref") { rt in rt.push(enabled ? "true" : "false"); return 1 }
        lua.register("__t_read") { rt in
            if let config { rt.push(config) } else { rt.pushNil() }; return 1
        }
        lua.register("__t_jdec") { rt in
            let s = rt.stringArgument(1) ?? ""
            if let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                rt.pushJSON(obj)
            } else { rt.pushNil() }
            return 1
        }
        lua.register("__t_sys") { rt in injected.append(rt.stringArgument(1) ?? ""); return 0 }
        lua.register("__t_noop") { _ in 0 }

        // Minimal `host` covering everything the eventtap path touches; unknown keys
        // fall back to a callable no-op table so a stray reference never aborts.
        try lua.run(#"""
        local noop = function() end
        _warns = {}
        function __get_warns() return table.concat(_warns, "\n") end
        host = {
            prefs = { get = function(k) return __t_pref(k) end, set = noop },
            fs = { read = function(p) return __t_read(p) end },
            json = { decode = function(s) return __t_jdec(s) end, encode = function() return "{}" end },
            log = { info = noop, warn = function(m) _warns[#_warns + 1] = m end, error = noop },
            time = function() return 0 end,
            env = { get = function() return nil end },
            keys = { set_rules = noop, stroke = noop, system = function(n) __t_sys(n) end },
            alert = { show = noop }, notify = noop,
            clipboard = { read = function() return "" end, write = noop },
        }
        setmetatable(host, { __index = function()
            return setmetatable({}, { __index = function(t) return t end, __call = function(t) return t end })
        end })
        """#, name: "=hoststub")

        let facade = Self.facadeSource()
        try lua.run(facade, name: "@hammerspoon-compat")
        return (lua, { injected })
    }

    /// Load the shipped facade init.lua from the repo (relative to this test file).
    private static func facadeSource() -> String {
        let here = URL(fileURLWithPath: #filePath)
        let appRoot = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = appRoot.appendingPathComponent("Examples/extensions/hammerspoon-compat/init.lua")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func keyDownJSON(code: Int, fn: Bool = false) -> String {
        "{\"type\":\"keyDown\",\"keyCode\":\(code),\"flags\":{\"cmd\":false,\"alt\":false,\"ctrl\":false,\"shift\":false,\"fn\":\(fn)}}"
    }
    private func mediaJSON(key: String, down: Bool) -> String {
        "{\"type\":\"systemDefined\",\"sys\":{\"key\":\"\(key)\",\"down\":\(down)},\"flags\":{\"cmd\":false,\"alt\":false,\"ctrl\":false,\"shift\":false,\"fn\":false}}"
    }

    // MARK: - probe

    func testProbeReportsRunningTapTypes() throws {
        let (lua, _) = try makeRuntime(config: Self.userConfig)
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "keyDown,systemDefined")
    }

    func testProbeEmptyWhenNoTap() throws {
        let (lua, _) = try makeRuntime(config: "local x = 1")  // no eventtap
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "")
    }

    func testProbeEmptyWhenTapNotStarted() throws {
        // Created but never :start()ed → not running → not reported.
        let cfg = "hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function() return true end)"
        let (lua, _) = try makeRuntime(config: cfg)
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "")
    }

    func testProbeEmptyWhenDisabled() throws {
        let (lua, _) = try makeRuntime(config: Self.userConfig, enabled: false)
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "")
    }

    func testProbeEmptyWhenConfigMissing() throws {
        let (lua, _) = try makeRuntime(config: nil)
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "")
    }

    func testSettingsRenderSummarizesLoadedConfig() throws {
        // The diagnostics section runs the real config-summary path (run_user_config
        // + ipairs over binds/native/eventtaps/timers). Must not throw and must
        // produce output for a config that registers a running eventtap.
        let (lua, _) = try makeRuntime(config: Self.userConfig)
        XCTAssertNoThrow(try lua.callGlobal("settings_render", ["hammerspoon-compat", "{}"]))
    }

    func testProbeWarnsOnUnsupportedTapType() throws {
        // keyUp/flagsChanged taps are never delivered by the native tap → probe
        // must warn (not silently drop) and still report nothing.
        let cfg = "hs.eventtap.new({ hs.eventtap.event.types.keyUp }, function() return true end):start()"
        let (lua, _) = try makeRuntime(config: cfg)
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "")
        let warns = try lua.callGlobal("__get_warns") ?? ""
        XCTAssertTrue(warns.contains("keyUp/flagsChanged"), "expected unsupported-type warning, got: \(warns)")
    }

    // MARK: - dispatch (keyDown)

    func testDispatchSwallowsF5() throws {
        let (lua, _) = try makeRuntime(config: Self.userConfig)
        _ = try lua.callGlobal("hs_eventtap_probe")  // warm
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_dispatch", [keyDownJSON(code: 96)]), "true")
    }

    func testDispatchPassesPlainKey() throws {
        let (lua, _) = try makeRuntime(config: Self.userConfig)
        _ = try lua.callGlobal("hs_eventtap_probe")
        // keyCode 0 == "a": no rule → pass.
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_dispatch", [keyDownJSON(code: 0)]), "false")
    }

    func testDispatchFnModifierGatesSwallow() throws {
        let (lua, _) = try makeRuntime(config: Self.userConfig)
        _ = try lua.callGlobal("hs_eventtap_probe")
        // keyCode 2 == "d": swallow only WITH fn (proves fn plumbs through to Lua).
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_dispatch", [keyDownJSON(code: 2, fn: true)]), "true")
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_dispatch", [keyDownJSON(code: 2, fn: false)]), "false")
    }

    // MARK: - dispatch (systemDefined)

    func testDispatchSystemKeyRemapsAndSwallows() throws {
        let (lua, injected) = try makeRuntime(config: Self.userConfig)
        _ = try lua.callGlobal("hs_eventtap_probe")
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_dispatch", [mediaJSON(key: "PLAY", down: true)]), "true")
        XCTAssertEqual(injected(), ["FAST"], "PLAY-down should inject FAST via host.keys.system once")
    }

    func testDispatchSystemKeyReleasePasses() throws {
        let (lua, injected) = try makeRuntime(config: Self.userConfig)
        _ = try lua.callGlobal("hs_eventtap_probe")
        // down=false → callback returns false → pass, and no injection.
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_dispatch", [mediaJSON(key: "PLAY", down: false)]), "false")
        XCTAssertEqual(injected(), [])
    }

    // MARK: - robustness

    func testDispatchFailsOpenOnCallbackError() throws {
        let cfg = """
        local tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function() error("boom") end)
        tap:start()
        """
        let (lua, _) = try makeRuntime(config: cfg)
        _ = try lua.callGlobal("hs_eventtap_probe")
        // A throwing callback must NOT swallow (fail-open → typing never blocked).
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_dispatch", [keyDownJSON(code: 96)]), "false")
    }

    func testDispatchDisabledReturnsFalse() throws {
        let (lua, _) = try makeRuntime(config: Self.userConfig, enabled: false)
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_dispatch", [keyDownJSON(code: 96)]), "false")
    }

    // MARK: - instruction budget (main-thread freeze guard)

    /// A wedged callback (infinite loop) must fail OPEN and abort within the tight
    /// dispatch budget, not run to the 10M default — typing is never blocked.
    func testDispatchBudgetAbortsRunawayCallback() throws {
        let cfg = """
        local tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown },
            function() while true do end end)
        tap:start()
        """
        let (lua, _) = try makeRuntime(config: cfg)
        _ = try lua.callGlobal("hs_eventtap_probe")
        let budget = EventTapHost.dispatchInstructionBudget
        let start = DispatchTime.now().uptimeNanoseconds
        let r = try lua.callGlobal("hs_eventtap_dispatch", [keyDownJSON(code: 96)], budget: budget)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertEqual(r, "false", "runaway callback must fail open (not swallow)")
        XCTAssertLessThan(ms, 100, "budget did not bound the runaway callback — main thread would stall")
    }

    /// The tight live budget must still leave ample headroom for a real callback.
    func testRealCallbackSucceedsUnderDispatchBudget() throws {
        let (lua, _) = try makeRuntime(config: Self.userConfig)
        _ = try lua.callGlobal("hs_eventtap_probe")
        let budget = EventTapHost.dispatchInstructionBudget
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_dispatch", [keyDownJSON(code: 96)], budget: budget), "true")
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_dispatch", [keyDownJSON(code: 0)], budget: budget), "false")
    }

    // MARK: - hot path

    /// Warm-VM dispatch is the per-keystroke cost when a tap is active. It must stay
    /// well under a frame — the gate (a single Bool on EventTapHost) means the VM is
    /// never touched at all unless a tap is running, so this is the worst case.
    func testDispatchHotPathBudget() throws {
        let (lua, _) = try makeRuntime(config: Self.userConfig)
        _ = try lua.callGlobal("hs_eventtap_probe")  // warm: rebuild happens once
        let payload = keyDownJSON(code: 0)            // plain key → full callback body runs
        // warmup
        for _ in 0..<200 { _ = try lua.callGlobal("hs_eventtap_dispatch", [payload]) }
        let n = 5_000
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<n { _ = try lua.callGlobal("hs_eventtap_dispatch", [payload]) }
        let perMs = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n) / 1_000_000
        XCTAssertLessThan(perMs, 1.0, "warm eventtap dispatch >1ms — VM re-parsing per press?")
    }

    // MARK: - key-tap lifecycle decision

    /// Regression guard for the "every shortcut dead" bug: the shared CGEvent tap must
    /// run if ANY of its three consumers needs it. The bug was a dropped `eventTaps`
    /// term, so a pure-`hs.eventtap` config (autocomplete off, no native key rules)
    /// left the tap down. Each consumer alone must keep it up; all-off keeps it down.
    @MainActor
    func testNeedKeyTapIsOrOfAllConsumers() {
        XCTAssertFalse(AppDelegate.needKeyTap(autocomplete: false, extRules: false, eventTaps: false),
                       "tap must be DOWN when no consumer needs it")
        XCTAssertTrue(AppDelegate.needKeyTap(autocomplete: true,  extRules: false, eventTaps: false))
        XCTAssertTrue(AppDelegate.needKeyTap(autocomplete: false, extRules: true,  eventTaps: false))
        XCTAssertTrue(AppDelegate.needKeyTap(autocomplete: false, extRules: false, eventTaps: true),
                      "the eventTaps term is the one that regressed — must keep the tap up alone")
    }
}
