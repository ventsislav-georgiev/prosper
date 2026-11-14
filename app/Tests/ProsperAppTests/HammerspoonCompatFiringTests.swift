import XCTest
import Foundation
import LuaRuntime

/// #1149: the shipped hammerspoon-compat `init.lua` gates `app:hide()` on the ctx the app object was made
/// under. Before, it read the global `_HS.ctx`, which a rebuild publishes only after the config's top level
/// has run, so a top-level `hide()` in a rebuild passed on the previous run's ctx: a register ctx, or one
/// whose dispatch spent its instruction budget (#1126: the shim's pcall cannot catch that, so the line
/// that turns `firing` off never runs).
///
/// Every host call is a stub: `host.apps.frontmost` returns a fixed fake app, `host.apps.hide` only records
/// the bundle id it was given, `host.apps.windows` answers 0, `host.fs.read` returns the config string of
/// the row, and everything else the paths touch is a no-op. No app is hidden, no event is posted, no tap
/// is installed, and no file is read.
final class HammerspoonCompatFiringTests: XCTestCase {

    private static let front = "com.example.front"
    private static let spent = LuaRuntime.LuaError.runtime("execution budget exceeded")
    /// Small enough that every spinning callback below spends it; each loop is bounded (5,000,000 empty
    /// iterations), so a regression ends the call on its own instead of hanging the run.
    private static let budget: Int32 = 100_000

    /// One spinning callback per dispatcher, plus a top-level hide().
    private static let spinConfig = """
    local front = hs.application.frontmostApplication()
    if front then front:hide() end
    local function spin() for i = 1, 5000000 do end end
    hs.hotkey.bind({"cmd", "alt"}, "j", spin)
    hs.timer.doAfter(60, spin)
    hs.urlevent.httpCallback = spin
    hs.application.watcher.new(spin):start()
    hs.eventtap.new({ hs.eventtap.event.types.keyDown }, spin):start()
    """

    /// The five dispatchers, each with a payload that reaches the spinning callback.
    private static let dispatches: [(String, String)] = [
        ("hs_dispatch", "1"),
        ("hs_timer_fired", #"{"id":"hst_1"}"#),
        ("hs_url_open", #"{"url":"https://example.com/"}"#),
        ("hs_app_activated", #"{"name":"Example","bundleID":"com.example.other","pid":7}"#),
        ("hs_eventtap_dispatch",
         #"{"type":"keyDown","keyCode":0,"flags":{"cmd":false,"alt":false,"ctrl":false,"shift":false,"fn":false}}"#),
    ]

    /// A runtime with the shipped init.lua and a stub `host`; returns the hide recorder.
    private func makeRuntime(config: String) throws -> (LuaRuntime, () -> [String]) {
        let lua = try LuaRuntime(allowLoad: true)
        var hidden: [String] = []
        lua.register("__t_read") { rt in rt.push(config); return 1 }
        lua.register("__t_hide") { rt in hidden.append(rt.stringArgument(1) ?? "<nil>"); return 0 }
        lua.register("__t_jdec") { rt in
            let s = rt.stringArgument(1) ?? ""
            if let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                rt.pushJSON(obj)
            } else { rt.pushNil() }
            return 1
        }
        try lua.run(#"""
        local noop = function() end
        __t_timer_log = {}
        function __t_timers() return table.concat(__t_timer_log, ",") end
        host = {
            prefs = { get = function(k) if k == "enabled" then return "true" end end, set = noop },
            fs = { read = function() return __t_read() end },
            json = { decode = function(s) return __t_jdec(s) end, encode = function() return "{}" end },
            log = { info = noop, warn = noop, error = noop },
            time = function() return 0 end,
            env = { get = function() return nil end },
            keys = { set_rules = noop, stroke = noop, system = noop },
            timer = {
                schedule = function(o) __t_timer_log[#__t_timer_log + 1] = "schedule " .. tostring(o.id) end,
                cancel = function(id) __t_timer_log[#__t_timer_log + 1] = "cancel " .. tostring(id) end,
            },
            apps = {
                frontmost = function() return { name = "Example", bundleID = "com.example.front", pid = 42 } end,
                hide = function(bid) __t_hide(bid) end,
                windows = function() return 0 end,
                launch_or_focus = noop,
            },
        }
        setmetatable(host, { __index = function()
            return setmetatable({}, { __index = function(t) return t end, __call = function(t) return t end })
        end })
        -- Whether an effect of the published ctx would pass right now: a hide through an app object of
        -- that ctx, with host.apps.hide swapped for a local flag so the hide recorder stays untouched.
        function __t_firing()
            local c = _HS and _HS.ctx
            if not c then return "nil" end
            local real, hit = host.apps.hide, false
            host.apps.hide = function() hit = true end
            make_app("Probe", "com.example.probe", 1, c).hide()
            host.apps.hide = real
            return tostring(hit)
        end
        """#, name: "=hoststub")
        try lua.run(Self.facadeSource(), name: "@hammerspoon-compat")
        return (lua, { hidden })
    }

    /// The shipped init.lua, relative to this test file.
    private static func facadeSource() -> String {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = appRoot.appendingPathComponent("Examples/extensions/hammerspoon-compat/init.lua")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func assertSpent(_ lua: LuaRuntime, _ name: String, _ arg: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try lua.callGlobal(name, [arg], budget: Self.budget), name, file: file, line: line) {
            XCTAssertEqual($0 as? LuaRuntime.LuaError, Self.spent, name, file: file, line: line)
        }
    }

    /// Each dispatcher aborted on its budget leaves `firing` on; the next rebuild runs the config's top
    /// level, and its hide() is refused.
    func testATopLevelHideIsRefusedInTheRebuildAfterADispatchAbortedOnItsBudget() throws {
        XCTAssertEqual(Self.dispatches.map { $0.0 }, ["hs_dispatch", "hs_timer_fired", "hs_url_open",
                                                  "hs_app_activated", "hs_eventtap_dispatch"])
        for (name, arg) in Self.dispatches {
            let (lua, hidden) = try makeRuntime(config: Self.spinConfig)
            XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "keyDown", name)   // warm: a rebuild
            XCTAssertEqual(hidden(), [], "\(name): a rebuild's top level hides nothing")
            assertSpent(lua, name, arg)
            XCTAssertEqual(try lua.callGlobal("__t_firing"), "true", "\(name): the abort leaves firing on")
            XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "keyDown", name)   // the next rebuild
            XCTAssertEqual(hidden(), [], "\(name): top-level hide() after an aborted dispatch must be refused")
            XCTAssertEqual(try lua.callGlobal("__t_firing"), "false", name)
        }
    }

    /// The register ctx, no budget involved. A register runs the top-level hide() once, as the config
    /// intends, on a cold VM too; a rebuild while the register ctx is published hides nothing; settings
    /// "reload" registers and then rebuilds for the diagnostics rows in the same call, one hide in all.
    /// Counts are compared per call, so each check fails on its own when hide() reads another run's ctx.
    func testATopLevelHideRunsOnceAtRegisterAndNotInTheRebuildAfterIt() throws {
        let config = "local front = hs.application.frontmostApplication()\nif front then front:hide() end\n"
        let (lua, hidden) = try makeRuntime(config: config)
        try lua.callGlobal("on_launch", [""])
        XCTAssertEqual(hidden(), [Self.front], "register on a cold VM hides once")
        try lua.callGlobal("on_launch", [""])
        let afterRegister = hidden().count
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "")
        XCTAssertEqual(hidden().count, afterRegister, "a rebuild after register must not hide again")
        try lua.callGlobal("settings_action", ["hammerspoon-compat", "reload", "", "{}"])
        XCTAssertEqual(hidden().count, afterRegister + 1, "reload registers (one hide); its diagnostics rebuild must not")
    }

    /// hide() inside a fired callback still reaches the host, through both ways an app object is made:
    /// frontmostApplication() and the object an app watcher receives.
    func testHideFromAFiredCallbackStillHides() throws {
        let config = """
        hs.hotkey.bind({"cmd", "alt"}, "h", function() hs.application.frontmostApplication():hide() end)
        hs.application.watcher.new(function(_, _, app) app:hide() end):start()
        """
        let (lua, hidden) = try makeRuntime(config: config)
        try lua.callGlobal("hs_dispatch", ["1"])
        XCTAssertEqual(hidden(), [Self.front])
        try lua.callGlobal("hs_app_activated", [#"{"name":"Other","bundleID":"com.example.other","pid":7}"#])
        XCTAssertEqual(hidden(), [Self.front, "com.example.other"])
        XCTAssertEqual(try lua.callGlobal("__t_firing"), "false")
    }

    /// A dispatch after an aborted one on the same warm VM behaves as a fresh one: firing is on while its
    /// callback runs (the hide goes through) and off when it returns, so the next rebuild hides nothing.
    func testADispatchAfterAnAbortedOneBehavesAsAFreshOne() throws {
        let config = """
        local front = hs.application.frontmostApplication()
        if front then front:hide() end
        hs.hotkey.bind({"cmd", "alt"}, "j", function() for i = 1, 5000000 do end end)
        hs.hotkey.bind({"cmd", "alt"}, "h", function() hs.application.frontmostApplication():hide() end)
        """
        let (lua, hidden) = try makeRuntime(config: config)
        try lua.callGlobal("hs_eventtap_probe")
        assertSpent(lua, "hs_dispatch", "1")
        XCTAssertEqual(try lua.callGlobal("__t_firing"), "true")
        try lua.callGlobal("hs_dispatch", ["2"])
        XCTAssertEqual(hidden(), [Self.front], "the next dispatch's callback hides once")
        XCTAssertEqual(try lua.callGlobal("__t_firing"), "false", "and turns firing off when it returns")
        try lua.callGlobal("hs_eventtap_probe")
        XCTAssertEqual(hidden(), [Self.front], "the rebuild after it hides nothing")
    }

    // MARK: - #1156: the register window ends with the register run's top level

    /// #1156: an app object a register run stores in a table every run shares (the standard `table` library)
    /// hides only from that run's own fired callback: not from a later rebuild's or register's top level, and
    /// not from another run's callback. A register's own top-level hide is the once-per-register row above.
    func testAnAppObjectParkedByARegisterRunHidesOnlyFromThatRunsCallback() throws {
        let config = """
        if table.parked then table.parked:hide() end
        table.parked = table.parked or hs.application.frontmostApplication()
        hs.hotkey.bind({"cmd", "alt"}, "p", function() table.parked:hide() end)
        """
        let (lua, hidden) = try makeRuntime(config: config)
        try lua.callGlobal("on_launch", [""])
        XCTAssertEqual(hidden(), [], "register parks the object and hides nothing")
        try lua.callGlobal("hs_dispatch", ["1"])
        XCTAssertEqual(hidden(), [Self.front], "the register run's fired callback hides through it")
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "")
        XCTAssertEqual(hidden(), [Self.front], "a later rebuild's top level must not hide through it")
        try lua.callGlobal("on_launch", [""])
        XCTAssertEqual(hidden(), [Self.front], "a later register's top level must not hide through it")
        try lua.callGlobal("hs_dispatch", ["1"])
        XCTAssertEqual(hidden(), [Self.front], "another run's fired callback must not hide through it")
    }

    /// #1156: config code that runs after a register's top level has returned (here the error value's
    /// __tostring, run when the shim logs the error) gets no register effects; the top-level hide before
    /// the error still runs, once.
    func testConfigCodeRunAfterARegisterTopLevelReturnedDoesNotHide() throws {
        let config = """
        local front = hs.application.frontmostApplication()
        front:hide()
        error(setmetatable({}, { __tostring = function() front:hide(); return "stopped" end }))
        """
        let (lua, hidden) = try makeRuntime(config: config)
        try lua.callGlobal("on_launch", [""])
        XCTAssertEqual(hidden(), [Self.front], "the top-level hide only")
    }

    /// Run 1 parks nothing it can use; run 2 (the register below) parks its own app object, then spends
    /// its budget in the top level (a bounded loop, as in spinConfig). Every dispatcher fires `use`.
    private static let parkConfig = """
    if table.parked then table.parked:hide() end
    table.parked = hs.application.frontmostApplication()
    local function use() table.parked:hide() end
    hs.hotkey.bind({"cmd", "alt"}, "j", use)
    hs.timer.doAfter(60, use)
    hs.urlevent.httpCallback = use
    hs.application.watcher.new(use):start()
    hs.eventtap.new({ hs.eventtap.event.types.keyDown }, use):start()
    table.runs = (table.runs or 0) + 1
    if table.runs == 2 then for i = 1, 5000000 do end end
    """

    /// #1156: a register run that spends its budget in the top level never reaches the line that ends its
    /// register window. The object it parked before that must not hide from what runs next on the same warm
    /// VM: a callback of the run still published (each dispatcher), then the next rebuild's top level.
    func testAnObjectParkedByARegisterRunAbortedOnItsBudgetDoesNotHideLater() throws {
        XCTAssertEqual(Self.dispatches.map { $0.0 }, ["hs_dispatch", "hs_timer_fired", "hs_url_open",
                                                  "hs_app_activated", "hs_eventtap_dispatch"])
        for (name, arg) in Self.dispatches {
            let (lua, hidden) = try makeRuntime(config: Self.parkConfig)
            try lua.run("function __t_runs() return tostring(table.runs) end", name: "=probe")
            XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "keyDown", name)   // run 1: published
            assertSpent(lua, "on_launch", "")                                          // run 2: register, aborted
            XCTAssertEqual(try lua.callGlobal("__t_runs"), "2", "\(name): the register got past the park line")
            XCTAssertEqual(hidden(), [], "\(name): the register's top level must not hide through run 1's object")
            try lua.callGlobal(name, [arg])
            XCTAssertEqual(hidden(), [], "\(name): run 1's callback must not hide through the aborted register's object")
            XCTAssertEqual(try lua.callGlobal("__t_firing"), "false", name)
            XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "keyDown", name)   // run 3: a rebuild
            XCTAssertEqual(hidden(), [], "\(name): the next rebuild's top level must not hide through it")
        }
    }

    // MARK: - #1158: a callback stopped on its budget, the timer object's start and stop

    /// Every dispatcher's callback parks an app object of its run in the standard `table` library, then
    /// spends its budget (a bounded loop, as in spinConfig). Bind 2 hides through whatever is parked.
    private static let abortParkConfig = """
    if table.parked then table.parked:hide() end
    local function park() table.parked = hs.application.frontmostApplication(); for i = 1, 5000000 do end end
    hs.hotkey.bind({"cmd", "alt"}, "j", park)
    hs.hotkey.bind({"cmd", "alt"}, "u", function() table.parked:hide() end)
    hs.timer.doAfter(60, park)
    hs.urlevent.httpCallback = park
    hs.application.watcher.new(park):start()
    hs.eventtap.new({ hs.eventtap.event.types.keyDown }, park):start()
    """

    /// #1158: a callback stopped on its budget never reaches the line that ends its firing window. The
    /// object it parked must not hide from a later run: the next rebuild's top level, then that run's callback.
    func testAnObjectParkedByACallbackAbortedOnItsBudgetDoesNotHideFromALaterRun() throws {
        XCTAssertEqual(Self.dispatches.map { $0.0 }, ["hs_dispatch", "hs_timer_fired", "hs_url_open",
                                                  "hs_app_activated", "hs_eventtap_dispatch"])
        for (name, arg) in Self.dispatches {
            let (lua, hidden) = try makeRuntime(config: Self.abortParkConfig)
            try lua.run("function __t_parked() return tostring(table.parked ~= nil) end", name: "=probe")
            XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "keyDown", name)   // run 1: published
            assertSpent(lua, name, arg)                                                 // its callback parks, aborts
            XCTAssertEqual(try lua.callGlobal("__t_parked"), "true", "\(name): the callback got past the park line")
            XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "keyDown", name)   // run 2: a rebuild
            XCTAssertEqual(hidden(), [], "\(name): the next rebuild's top level must not hide through it")
            try lua.callGlobal("hs_dispatch", ["2"])
            XCTAssertEqual(hidden(), [], "\(name): another run's callback must not hide through it")
        }
    }

    /// #1158: the timer object's start and stop are effects like doAfter/doEvery: a register's top level
    /// and a fired callback reach the host timer, a rebuild's top level does not (no re-arm, no cancel).
    /// The host timer is a recorder (schedule/cancel append to a list); nothing is armed.
    func testATimersStartAndStopReachTheHostOnlyAtRegisterAndFromACallback() throws {
        let config = """
        local t = hs.timer.doEvery(60, function() end)
        t:start()
        t:stop()
        t:start()
        hs.hotkey.bind({"cmd", "alt"}, "t", function() t:stop(); t:start() end)
        """
        let (lua, _) = try makeRuntime(config: config)
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "")
        XCTAssertEqual(try lua.callGlobal("__t_timers"), "", "a rebuild's top level must not start or stop it")
        try lua.callGlobal("on_launch", [""])
        let registered = "schedule hst_1,schedule hst_1,cancel hst_1,schedule hst_1"
        XCTAssertEqual(try lua.callGlobal("__t_timers"), registered, "register: doEvery, start, stop, start")
        XCTAssertEqual(try lua.callGlobal("hs_eventtap_probe"), "")
        XCTAssertEqual(try lua.callGlobal("__t_timers"), registered, "a rebuild after register must not either")
        try lua.callGlobal("hs_dispatch", ["1"])
        XCTAssertEqual(try lua.callGlobal("__t_timers"), registered + ",cancel hst_1,schedule hst_1",
                       "a fired callback stops and starts it")
    }
}
