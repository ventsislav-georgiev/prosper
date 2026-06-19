-- hammerspoon-compat — run an unmodified ~/.hammerspoon/init.lua under Prosper.
--
-- Prosper's extension model is STATELESS: no resident VM holds live closures.
-- Hammerspoon's whole model is the opposite — `hs.hotkey.bind` stashes a Lua
-- closure the runtime keeps forever. We bridge the two without depending on a
-- resident VM by running the user's config in TWO MODES, both on a fresh VM:
--
--   register (on system.launch): run init.lua, RECORD every hs.hotkey.bind, and
--     emit one native `invoke` key rule per binding. Top-level side effects
--     (hs.caffeinate.set, hs.alert, …) run once here. Hotkey closures do NOT fire.
--   dispatch (a bound key is pressed): the native tap swallowed the key and
--     re-invokes hs_dispatch(index) on our lane. We re-run init.lua with side
--     effects suppressed (just rebuilds the closure table), then fire the ONE
--     matched closure. Re-running init is a few ms — fine at human keypress rate.
--
-- The `hs` table is a shim over host.*: ~20 common APIs map cleanly, everything
-- else is an inert chainable no-op so a `:start():setTitle()` chain never crashes
-- the config. Raw hs.eventtap.new keyDown/systemDefined taps DO run, via a lazy
-- opt-in resident VM (event_taps=true in the manifest; see EventTapHost.swift and
-- the "raw eventtaps" section below). Still unsupported-by-design: Spoons. They
-- warn once and do nothing.
--
-- DISABLED BY DEFAULT: on_launch returns immediately unless the `enabled` pref is
-- on, so with the switch off this extension installs no rules and runs no config.

local HS_INIT = "~/.hammerspoon/init.lua"

-- ============ Enable gate ============
local function is_enabled()
    return host.prefs.get("enabled") == "true"
end

-- ============ combo normalization (hs mods+key -> Prosper KeyCombo spec) ============
local MOD_ALIAS = { command = "cmd", cmd = "cmd", option = "alt", alt = "alt",
                    control = "ctrl", ctrl = "ctrl", shift = "shift" }

-- Standard macOS virtual keycode -> name, mirroring hs.keycodes.map (US ANSI). An
-- eventtap callback does `hs.keycodes.map[event:getKeyCode()]` to branch on key
-- names ("f5"/"d"/…), so the identity stub (which returned the number) broke every
-- such comparison. Codes not listed here index back to themselves (the metatable
-- fallback), so a numeric compare like `keycode == 176` still works.
local KEYCODE_MAP = {
    [0]="a",[1]="s",[2]="d",[3]="f",[4]="h",[5]="g",[6]="z",[7]="x",[8]="c",[9]="v",
    [11]="b",[12]="q",[13]="w",[14]="e",[15]="r",[16]="y",[17]="t",
    [18]="1",[19]="2",[20]="3",[21]="4",[22]="6",[23]="5",[24]="=",[25]="9",[26]="7",
    [27]="-",[28]="8",[29]="0",[30]="]",[31]="o",[32]="u",[33]="[",[34]="i",[35]="p",
    [36]="return",[37]="l",[38]="j",[39]="'",[40]="k",[41]=";",[42]="\\",[43]=",",
    [44]="/",[45]="n",[46]="m",[47]=".",[48]="tab",[49]="space",[50]="`",[51]="delete",
    [53]="escape",[65]="padperiod",[67]="padmultiply",[69]="padplus",[71]="padclear",
    [75]="paddivide",[76]="padenter",[78]="padminus",[81]="padequals",
    [82]="pad0",[83]="pad1",[84]="pad2",[85]="pad3",[86]="pad4",[87]="pad5",[88]="pad6",
    [89]="pad7",[91]="pad8",[92]="pad9",
    [96]="f5",[97]="f6",[98]="f7",[99]="f3",[100]="f8",[101]="f9",[103]="f11",
    [105]="f13",[106]="f16",[107]="f14",[109]="f10",[111]="f12",[113]="f15",
    [114]="help",[115]="home",[116]="pageup",[117]="forwarddelete",[118]="f4",
    [119]="end",[120]="f2",[121]="pagedown",[122]="f1",[123]="left",[124]="right",
    [125]="down",[126]="up",
}

-- Returns a "cmd+alt+i" style string, or nil if a modifier can't be expressed
-- natively (e.g. "fn") — an unparseable combo is dropped by the host rule decoder.
local function to_combo(mods, key)
    local parts = {}
    if type(mods) == "string" then mods = { mods } end
    for _, m in ipairs(mods or {}) do
        local norm = MOD_ALIAS[tostring(m):lower()]
        if not norm then return nil end -- unsupported modifier -> skip this binding
        parts[#parts + 1] = norm
    end
    parts[#parts + 1] = tostring(key):lower()
    return table.concat(parts, "+")
end

-- ============ The hs shim ============
-- `binds` is rebuilt on every run (register or dispatch). `mode`/`firing` gate
-- side effects: a side-effecting host call runs only at register time (top-level
-- config intent, once) OR while a fired callback is executing (the action itself).
local function build_hs(ctx)
    local warned = {}
    local function warn_once(api)
        if not warned[api] then
            warned[api] = true
            host.log.warn("hammerspoon-compat: " .. api .. " is not supported (no-op)")
        end
    end

    -- A side effect is allowed when applying config (register) or running a
    -- fired hotkey callback (dispatch + firing). Top-level calls during a dispatch
    -- re-run are suppressed so they don't fire again on every keypress.
    local function allowed() return ctx.mode == "register" or ctx.firing end

    -- Chainable no-op: both indexing AND calling return the object itself, so an
    -- unmodified config can index arbitrarily deep AND call at any point —
    -- `hs.eventtap.event.types.keyDown`, `hs.foo.bar():baz():qux()`, `hs.x.y` then
    -- `y()` — without ever throwing. (Returning a bare function from __index broke
    -- the deep-index case: a function isn't indexable, so `.types.keyDown` aborted
    -- the whole chunk and no later rules registered.)
    local function chainable(name)
        local t = {}
        return setmetatable(t, {
            __index = function() if name then warn_once(name) end; return t end,
            __call = function() return t end,
        })
    end

    local hs = {}

    -- The pressed callback is the first function-typed argument. This transparently
    -- handles hs.hotkey.bind's optional message form — bind(mods,key,"msg",pressedfn,…)
    -- — as well as the plain bind(mods,key,pressedfn,…); a string message is ignored.
    local function first_fn(...)
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            if type(v) == "function" then return v end
        end
        return nil
    end

    -- hotkey.bind RECORDS + auto-enables (matches hs: bind is active immediately).
    -- hotkey.new RECORDS but stays disabled until :enable() — install() emits a rule
    -- only for enabled bindings, so `new(...)` without `:enable()` fires nothing.
    hs.hotkey = {
        bind = function(mods, key, ...)
            ctx.binds[#ctx.binds + 1] = { combo = to_combo(mods, key), fn = first_fn(...), enabled = true }
            return chainable() -- already active; enable()/disable()/delete() are no-ops
        end,
        new = function(mods, key, ...)
            local entry = { combo = to_combo(mods, key), fn = first_fn(...), enabled = false }
            ctx.binds[#ctx.binds + 1] = entry
            return setmetatable({}, { __index = function(_, k)
                if k == "enable" or k == "start" then return function(s) entry.enabled = true; return s end end
                if k == "disable" or k == "delete" or k == "stop" then return function(s) entry.enabled = false; return s end end
                return function(s) return s end -- any other method: chainable no-op
            end })
        end,
        modal = { new = function() return chainable("hs.hotkey.modal") end },
    }

    -- application launch / focus.
    hs.application = {
        launchOrFocus = function(name) if allowed() then host.apps.launch_or_focus(name) end end,
        launchOrFocusByBundleID = function(id) if allowed() then host.apps.launch_or_focus(id) end end,
        get = function() return nil end,
        frontmostApplication = function()
            local f = host.apps.frontmost(); if not f then return nil end
            return { name = function() return f.name end, bundleID = function() return f.bundleID end,
                     pid = function() return f.pid end }
        end,
    }
    hs.appfinder = chainable("hs.appfinder")

    -- keystroke injection.
    hs.eventtap = {
        keyStroke = function(mods, key) if allowed() then host.keys.stroke(to_combo(mods, key) or "") end end,
        keyStrokes = function() warn_once("hs.eventtap.keyStrokes") end,
        -- Raw per-event tap. RECORDS the callback; the host drives it synchronously on
        -- the keystroke path through a RESIDENT VM. Opt-in via extension.host.event_taps
        -- (see EventTapHost.swift) and lazy — no resident VM unless a tap is :start()ed.
        new = function(types, fn)
            local rec = { fn = fn, types = {}, running = false }
            if type(types) == "table" then
                for _, ty in ipairs(types) do rec.types[ty] = true end
            end
            ctx.eventtaps[#ctx.eventtaps + 1] = rec
            return setmetatable({}, { __index = function(_, k)
                if k == "start" then return function(self) rec.running = true; return self end end
                if k == "stop" then return function(self) rec.running = false; return self end end
                if k == "isEnabled" then return function() return rec.running end end
                return function(self) return self end -- other methods: chainable no-op
            end })
        end,
        event = {
            -- Event type ids the dispatcher echoes back via ev:getType().
            types = { keyDown = "keyDown", keyUp = "keyUp",
                      flagsChanged = "flagsChanged", systemDefined = "systemDefined" },
            -- Synthetic media key. The common idiom posts (name,true) then (name,false);
            -- one host.keys.system(name) already emits the full down+up pair, so only the
            -- press injects (release post is a no-op) — no double press.
            newSystemKeyEvent = function(name, down)
                return { post = function() if down and allowed() then host.keys.system(name) end; return true end }
            end,
        },
    }

    -- caffeinate (power). hs.caffeinate.set(type, value, acAndBattery).
    hs.caffeinate = {
        set = function(_type, value) if allowed() then host.caffeinate.prevent_idle_sleep("system", value and true or false) end end,
        get = function() return false end,
        lockScreen = function() if allowed() then host.caffeinate.lock_screen() end end,
        startScreensaver = function() if allowed() then host.caffeinate.start_screensaver() end end,
        declareUserActivity = function() end,
    }

    -- URLs / shell / AppleScript / alerts / notifications / clipboard.
    hs.urlevent = {
        openURL = function(url) if allowed() then host.url.open(url) end end,
        bind = function() end, -- scheme handlers: unsupported
    }
    hs.openURL = function(url) if allowed() then host.url.open(url) end end
    hs.execute = function(cmd) return allowed() and host.shell.run(cmd) or "" end
    hs.osascript = {
        applescript = function(src)
            if not allowed() then return false end
            local r = host.osascript.run(src) or {}
            return r.ok, r.output, r.error
        end,
    }
    hs.alert = {
        show = function(text) if allowed() then host.alert.show(tostring(text)) end end,
        closeAll = function() end,
    }
    hs.notify = {
        show = function(title, _sub, text) if allowed() then host.notify(tostring(title or ""), tostring(text or "")) end end,
        new = function(_, opts)
            opts = opts or {}
            return setmetatable({}, { __index = function(_, k)
                if k == "send" then return function(self) if allowed() then host.notify(tostring(opts.title or ""), tostring(opts.informativeText or "")) end; return self end end
                return function(self) return self end
            end })
        end,
    }
    hs.pasteboard = {
        getContents = function() return host.clipboard.read() end,
        setContents = function(t) if allowed() then host.clipboard.write(tostring(t)) end end,
    }

    -- reads (safe in either mode).
    hs.battery = {
        percentage = function() return host.battery.percentage() end,
        powerSource = function() return host.battery.power_source() end,
        isCharging = function() return host.battery.power_source() == "AC Power" end,
    }
    hs.screen = {
        allScreens = function() local n = host.screen.count() or 1; local t = {}; for i = 1, n do t[i] = chainable() end; return t end,
        mainScreen = function() return chainable() end,
    }
    -- Real code->name map; unlisted codes fall back to themselves (numeric compares).
    hs.keycodes = { map = setmetatable(KEYCODE_MAP, { __index = function(_, k) return k end }) }

    -- fnutils — pure helpers, no host needed.
    hs.fnutils = {
        each = function(t, f) for _, v in ipairs(t or {}) do f(v) end end,
        map = function(t, f) local o = {}; for i, v in ipairs(t or {}) do o[i] = f(v) end; return o end,
        contains = function(t, e) for _, v in ipairs(t or {}) do if v == e then return true end end; return false end,
        indexOf = function(t, e) for i, v in ipairs(t or {}) do if v == e then return i end end; return nil end,
        concat = function(a, b) local o = {}; for _, v in ipairs(a or {}) do o[#o + 1] = v end; for _, v in ipairs(b or {}) do o[#o + 1] = v end; return o end,
    }

    -- settings — durable state over host.prefs (real hs.settings API). get always
    -- reads; set is gated like any side effect. Values are JSON-encoded.
    hs.settings = {
        -- NB: no `raw and decode(raw) or nil` — that Lua ternary trap turns a stored
        -- `false` (or any falsey decode) into nil. Guard empty/unset explicitly instead.
        get = function(k)
            local raw = host.prefs.get("hs.settings." .. tostring(k))
            if raw == nil or raw == "" then return nil end -- unset / cleared
            return host.json.decode(raw)
        end,
        set = function(k, v) if allowed() then host.prefs.set("hs.settings." .. tostring(k), host.json.encode(v)) end end,
        clear = function(k) if allowed() then host.prefs.set("hs.settings." .. tostring(k), "") end end,
    }

    -- timers: real durable timers over host.timer (host owns the clock + persists;
    -- fires the "timer.fired" event → hs_timer_fired re-fires the closure). Same
    -- durable-routing pattern as hotkeys. doAfter/doEvery RECORD the closure, but
    -- the host.timer.schedule call is a SIDE EFFECT — gated by allowed() so a
    -- dispatch/timer rebuild (which re-runs the config) does NOT re-schedule and
    -- multiply timers; it only repopulates ctx.timers so the right closure fires.
    local function schedule_timer(seconds, fn, repeating)
        local idx = #ctx.timers + 1
        ctx.timers[idx] = { fn = fn }
        local id = "hst_" .. idx
        local function arm()
            if type(seconds) == "number" and fn then
                host.timer.schedule(repeating
                    and { id = id, every = seconds, handler = "hs_timer_fired" }
                    or  { id = id, after = seconds, handler = "hs_timer_fired" })
            end
        end
        if allowed() then arm() end -- created started (hs semantics); rebuild won't re-arm
        return setmetatable({}, { __index = function(_, k)
            if k == "stop" then return function(s) host.timer.cancel(id); return s end end
            if k == "start" then return function(s) arm(); return s end end
            if k == "running" then return function() return true end end
            return function(s) return s end -- fire()/setNextTrigger()/… chainable no-op
        end })
    end
    hs.timer = setmetatable({
        doAfter = function(sec, fn) return schedule_timer(sec, fn, false) end,
        doEvery = function(sec, fn) return schedule_timer(sec, fn, true) end,
        -- duration helpers (pure): hs.timer.minutes(5) etc.
        seconds = function(s) return tonumber(s) or 0 end,
        minutes = function(m) return (tonumber(m) or 0) * 60 end,
        hours   = function(h) return (tonumber(h) or 0) * 3600 end,
        days    = function(d) return (tonumber(d) or 0) * 86400 end,
        weeks   = function(w) return (tonumber(w) or 0) * 604800 end,
        usleep  = function() end, -- can't block the lane; no-op
    }, { __index = function(_, k) warn_once("hs.timer." .. tostring(k)); return function() return chainable() end end })

    -- ============ hs.prosper — opt-in native key-rule bridge ============
    -- Raw `hs.eventtap.new` keyDown taps run via the resident VM (below), but that
    -- pays a Lua call per keystroke. The two common idioms — "press a chord twice to
    -- let it through" and "remap a chord (per app)" — are pure NATIVE rules (~340ns,
    -- no Lua per press), so prefer these when the callback has no real logic. These
    -- declarative helpers record them; install() emits them alongside the hotkey rules. Pure declarations (no side effect → no allowed()
    -- gate); a dispatch rebuild just re-records them, install() runs only at register.
    --   hs.prosper.doubleTap("cmd+q")                 -- first ⌘Q swallowed, 2nd passes
    --   hs.prosper.doubleTap({"cmd"}, "q")            -- hs mods+key form
    --   hs.prosper.remap{ from="alt+down", to="ctrl+tab",
    --                     apps={"com.apple.Safari","com.mitchellh.ghostty"} }
    hs.prosper = {
        doubleTap = function(a, b, c)
            local from, target
            if type(a) == "table" then from = to_combo(a, b); target = c -- (mods,key[,target])
            else from = a; target = b end                                -- (from[,target])
            if from then ctx.native[#ctx.native + 1] = { from = from, double_tap = target or from } end
        end,
        remap = function(opts)
            opts = opts or {}
            local from = opts.from or to_combo(opts.mods, opts.key)
            local to = opts.to or to_combo(opts.toMods, opts.toKey)
            if not (from and to) then return end
            local rule = { from = from, to = to }
            rule.apps = opts.apps
            rule.not_apps = opts.not_apps or opts.notApps
            ctx.native[#ctx.native + 1] = rule
        end,
        swallow = function(opts)
            local from = type(opts) == "string" and opts
                or (type(opts) == "table" and (opts.from or to_combo(opts.mods, opts.key))) or nil
            if not from then return end
            local rule = { from = from, swallow = true }
            if type(opts) == "table" then rule.apps = opts.apps; rule.not_apps = opts.not_apps or opts.notApps end
            ctx.native[#ctx.native + 1] = rule
        end,
    }

    -- Inert by design: Spoons, window mgmt, menubar, pathwatcher, logger.
    -- Chainable so config chains don't crash.
    hs.loadSpoon = function(name) warn_once("hs.loadSpoon(" .. tostring(name) .. ")"); return chainable() end
    hs.spoons = chainable("hs.spoons")
    hs.window = chainable("hs.window")
    hs.menubar = { new = function() warn_once("hs.menubar"); return chainable() end }
    hs.pathwatcher = { new = function() warn_once("hs.pathwatcher"); return chainable() end }
    hs.logger = { new = function() return chainable() end }
    hs.reload = function() end -- we own reload via settings; ignore self-reload
    hs.configdir = (host.env.get("HOME") or "~") .. "/.hammerspoon"

    -- Make every concrete hs.* sub-table fall back to a chainable no-op on
    -- unknown fields, so an unmodified config indexing e.g.
    -- `hs.application.watcher.new(...)` gets a harmless stub instead of nil
    -- (which aborts the chunk before later hs.prosper rules register). Tables
    -- that already carry a metatable (hs.timer, hs.keycodes.map) keep it.
    for k, v in pairs(hs) do
        if type(v) == "table" and not getmetatable(v) then
            local kname = k
            setmetatable(v, { __index = function(_, key)
                warn_once("hs." .. kname .. "." .. tostring(key)); return chainable()
            end })
        end
    end

    -- Anything else the config touches: warn once, stay chainable.
    return setmetatable(hs, { __index = function(_, k) warn_once("hs." .. tostring(k)); return chainable() end })
end

-- ============ run the user's config ============
-- `_HS` is a VM-global holding the last build's ctx (mode + live bind closures).
-- The async lane caches this extension's VM across deliveries (system.launch,
-- each hotkey), so `_HS.ctx.binds` survives between presses — the hot path fires a
-- LIVE closure with no file read / parse / re-run. It's nil only on a cold or
-- evicted VM, where hs_dispatch rebuilds it once (effects suppressed) before firing.
_HS = nil

-- mode = "register" (apply config: top-level effects run, hotkeys recorded) |
--        "rebuild"  (repopulate closures only: top-level effects suppressed).
-- Module-scope inert no-op for sandbox globals the config may call but that
-- Prosper either handles natively (e.g. `require("openlid")` — openlid is a
-- native flagship) or cannot sandbox (loadfile/dofile read arbitrary files).
-- Indexable AND callable, so `openlid = require("openlid"); openlid.start()`
-- and `local r = loadfile(p); r()` are safe no-ops instead of aborting the
-- chunk before later hs.prosper rules (cmd+q double-tap, remaps) register.
local _warned_global = {}
local function inert(name)
    if name and not _warned_global[name] then
        _warned_global[name] = true
        host.log.warn("hammerspoon-compat: " .. name .. " not supported (no-op)")
    end
    local t = {}
    return setmetatable(t, {
        __index = function() return t end,
        __call = function() return t end,
    })
end

local function run_user_config(mode)
    local source = host.fs.read(HS_INIT)
    if not source then
        if mode == "register" then host.log.warn("hammerspoon-compat: " .. HS_INIT .. " not found / unreadable") end
        _HS = nil
        return nil
    end

    local ctx = { mode = mode, firing = false, binds = {}, timers = {}, native = {}, eventtaps = {} }
    -- Sandbox the user's chunk in a fresh env: inject `hs`, expose stdlib + print.
    -- No `_G` passthrough -> the config can't reach Prosper's host.* directly.
    local osShim = {
        time = host.time, clock = host.time,
        date = os and os.date or nil,                 -- os stripped by sandbox -> nil; pcall-safe
        getenv = function(k) return host.env.get(k) end,
    }
    local env = {
        hs = build_hs(ctx),
        print = function() end, -- hs print goes to its console; swallow
        pairs = pairs, ipairs = ipairs, next = next, type = type, tostring = tostring,
        tonumber = tonumber, select = select, error = error, pcall = pcall, xpcall = xpcall,
        setmetatable = setmetatable, getmetatable = getmetatable, rawget = rawget, rawset = rawset,
        rawequal = rawequal, rawlen = rawlen, assert = assert, unpack = table.unpack,
        string = string, table = table, math = math, os = osShim,
        -- Module loaders: no-op (Prosper handles native modules; can't sandbox file reads)
        require = function(m) return inert("require(" .. tostring(m) .. ")") end,
        loadfile = function() return inert("loadfile") end,
        dofile = function() return inert("dofile") end,
        -- HS predefines a global `spoon` table (Spoon registry). Spoons aren't
        -- loaded here; inert keeps `spoon.X:method()` chains from aborting.
        spoon = inert("spoon"),
    }
    env._G = env

    local chunk, err = load(source, "@" .. HS_INIT, "t", env)
    if not chunk then
        host.log.error("hammerspoon-compat: parse error: " .. tostring(err))
        _HS = nil
        return nil
    end
    local ok, rerr = pcall(chunk)
    if not ok then
        host.log.error("hammerspoon-compat: init.lua error: " .. tostring(rerr))
        -- partial bindings may still be usable; fall through
    end
    _HS = { ctx = ctx }
    return ctx
end

-- Fire bound closure #idx. Returns false if it isn't there (caller may rebuild).
local function fire(idx)
    local ctx = _HS and _HS.ctx
    local b = ctx and ctx.binds[idx]
    if not (b and b.fn) then return false end
    ctx.firing = true                       -- side-effecting hs.* allowed inside the callback
    local ok, err = pcall(b.fn)
    ctx.firing = false
    if not ok then host.log.error("hammerspoon-compat: hotkey error: " .. tostring(err)) end
    return true
end

-- Fire timer closure #idx (same shape as fire(), separate list).
local function fire_timer(idx)
    local ctx = _HS and _HS.ctx
    local t = ctx and ctx.timers and ctx.timers[idx]
    if not (t and t.fn) then return false end
    ctx.firing = true
    local ok, err = pcall(t.fn)
    ctx.firing = false
    if not ok then host.log.error("hammerspoon-compat: timer error: " .. tostring(err)) end
    return true
end

-- ============ install / teardown ============
local function install()
    local ctx = run_user_config("register")
    local rules = {}
    if ctx then
        -- Dense sequence (skipped binds must NOT leave gaps, or the JSON encoder
        -- emits an object and the host drops every rule). `arg` keeps the ORIGINAL
        -- bind index so hs_dispatch fires the right closure.
        for i, b in ipairs(ctx.binds) do
            if b.combo and b.enabled then rules[#rules + 1] = { from = b.combo, invoke = "hs_dispatch", arg = tostring(i) } end
        end
        -- hs.prosper.* native rules (doubleTap / remap / swallow) — already in the
        -- host's rule shape, appended after the hotkey rules.
        for _, r in ipairs(ctx.native) do rules[#rules + 1] = r end
    end
    host.keys.set_rules(rules) -- replaces our rule set (empty = clears it)
    host.log.info(string.format("hammerspoon-compat: %d hotkey(s) installed", #rules))
end

local function teardown()
    -- Best-effort cancel of scheduled timers (only knowable on a warm VM). If the
    -- VM was evicted we can't enumerate ids; those timers still fire but hs_timer_fired
    -- is gated on is_enabled() so they no-op harmlessly.
    -- ponytail: warm-VM cancel only; persist ids if leftover repeating timers matter.
    if _HS and _HS.ctx and _HS.ctx.timers then
        for i = 1, #_HS.ctx.timers do host.timer.cancel("hst_" .. i) end
    end
    _HS = nil
    host.keys.set_rules({}) -- drop all our key rules
    host.log.info("hammerspoon-compat: disabled, rules cleared")
end

-- ============ host entry points ============

-- system.launch: the ONLY thing that runs unconditionally. Gated on `enabled`.
function on_launch(_payload)
    if not is_enabled() then return end -- disabled => do nothing at all
    install()
end

-- invoke key rule -> fire the bound hotkey closure. arg is the binding index.
-- HOT PATH: warm VM fires the cached closure directly (no I/O / parse). A cold or
-- evicted VM rebuilds the closures once (effects suppressed), then fires.
function hs_dispatch(arg)
    if not is_enabled() then return end
    local idx = tonumber(arg)
    if not idx then return end
    if not (_HS and _HS.ctx) then run_user_config("rebuild") end
    fire(idx)
end

-- timer.fired event -> fire the timer closure. payload is JSON {id="hst_<idx>"}.
-- Same warm/cold contract as hs_dispatch: warm VM fires directly; cold rebuilds once.
function hs_timer_fired(payload)
    if not is_enabled() then return end
    local data = payload and host.json.decode(payload) or nil
    local id = data and data.id
    if type(id) ~= "string" then return end
    local idx = tonumber(id:match("^hst_(%d+)$"))
    if not idx then return end
    if not (_HS and _HS.ctx) then run_user_config("rebuild") end
    fire_timer(idx)
end

-- ============ raw eventtaps (resident VM, opt-in) ============
-- EventTapHost (native) calls these on the SYNC resident runtime. probe() reports
-- which event types have a running tap so the host knows whether to keep the VM
-- and which hot-path branches to arm; dispatch() runs the matching callbacks for
-- one event and returns "true" to swallow. Both gate on is_enabled() so a disabled
-- ext costs nothing and the host evicts the VM.

-- Returns "keyDown", "systemDefined", "keyDown,systemDefined", or "" (no tap).
-- Re-runs the config (effects suppressed) so a live edit/reload is picked up.
function hs_eventtap_probe()
    if not is_enabled() then _HS = nil; return "" end
    local ctx = run_user_config("rebuild")
    if not (ctx and ctx.eventtaps) then return "" end
    local kd, sd = false, false
    for _, t in ipairs(ctx.eventtaps) do
        if t.running then
            if t.types["keyDown"] then kd = true end
            if t.types["systemDefined"] then sd = true end
            -- The native tap only delivers keyDown + systemDefined. A running tap
            -- on keyUp/flagsChanged never fires — warn so it isn't a silent no-op.
            if t.types["keyUp"] or t.types["flagsChanged"] then
                host.log.warn("hammerspoon-compat: eventtap on keyUp/flagsChanged is "
                    .. "not delivered (only keyDown and systemDefined are) — that tap will not fire")
            end
        end
    end
    local out = {}
    if kd then out[#out + 1] = "keyDown" end
    if sd then out[#out + 1] = "systemDefined" end
    return table.concat(out, ",")
end

-- payload: {type, keyCode?, flags={cmd,alt,ctrl,shift,fn}, sys={key,down}?}.
-- HOT PATH: fires the cached closures directly (no reparse). Cold/evicted VM
-- rebuilds once. firing=true lets the callback's side-effecting hs.* run.
function hs_eventtap_dispatch(payload)
    if not is_enabled() then return "false" end
    if not (_HS and _HS.ctx and _HS.ctx.eventtaps) then run_user_config("rebuild") end
    local ctx = _HS and _HS.ctx
    if not (ctx and ctx.eventtaps) then return "false" end
    local e = payload and host.json.decode(payload) or nil
    if not e then return "false" end
    local flags, sys = e.flags or {}, e.sys
    local ev = {
        getType = function() return e.type end,
        getKeyCode = function() return e.keyCode end,
        getFlags = function() return flags end,
        systemKey = function() return { key = sys and sys.key, down = sys and sys.down } end,
    }
    ctx.firing = true
    local swallow = false
    for _, t in ipairs(ctx.eventtaps) do
        if t.running and t.types[e.type] then
            local ok, res = pcall(t.fn, ev)
            if not ok then
                host.log.error("hammerspoon-compat: eventtap callback error: " .. tostring(res))
            elseif res == true then
                swallow = true
            end
        end
    end
    ctx.firing = false
    return swallow and "true" or "false"
end

-- ============ settings (dynamic Tier-B) ============

-- Describe one hs.prosper.* native rule for the diagnostics list.
local function native_rule_label(r)
    if r.double_tap then return r.from .. "  ⇒  double-tap " .. tostring(r.double_tap) end
    if r.to then return r.from .. "  ⇒  " .. tostring(r.to) end
    if r.system then return r.from .. "  ⇒  media " .. tostring(r.system) end
    if r.launch then return r.from .. "  ⇒  launch " .. tostring(r.launch) end
    if r.swallow then return r.from .. "  ⇒  swallow" end
    return r.from or "?"
end

-- Re-run the config (effects suppressed) and report what was parsed and shimmed:
-- hotkeys, native key rules, raw eventtaps (and which event types actually run),
-- and timers. Returns a list of `info` rows ready to splice into the section.
-- This is the user-facing answer to "did my init.lua actually take effect?".
local function diagnostics_rows()
    local rows = {}
    local function info(title, subtitle)
        rows[#rows + 1] = host.ui.settings.row { kind = "info", title = title, subtitle = subtitle }
    end
    if not is_enabled() then
        info("Status", "Disabled — turn on the toggle above to load your config.")
        return rows
    end
    -- If Accessibility is missing, NOTHING below will actually fire — say so first,
    -- loudly, so the parsed-count rows aren't mistaken for "working".
    if host.perms and host.perms.has and not host.perms.has("accessibility") then
        info("⚠︎ Accessibility NOT granted",
            "Everything below is parsed but DEAD until you grant Accessibility (row above) and Re-check.")
    end
    local ctx = run_user_config("rebuild")
    if not ctx then
        info("Status", "No ~/.hammerspoon/init.lua found, or it failed to load (check logs).")
        return rows
    end

    -- Hotkeys (hs.hotkey.bind) → invoke rules.
    local hot = {}
    for _, b in ipairs(ctx.binds or {}) do
        if b.combo and b.enabled then hot[#hot + 1] = b.combo end
    end
    info("Hotkeys", #hot == 0 and "none"
        or (#hot .. " active:  " .. table.concat(hot, "   ·   ")))

    -- Native key rules (hs.prosper.doubleTap / remap / swallow / …).
    local nat = {}
    for _, r in ipairs(ctx.native or {}) do nat[#nat + 1] = native_rule_label(r) end
    info("Key remaps (hs.prosper)", #nat == 0 and "none"
        or (#nat .. " active:  " .. table.concat(nat, "   ·   ")))

    -- Raw eventtaps (hs.eventtap.new) — these need the resident VM (event_taps).
    local taps, kd, sd, ignored = 0, false, false, false
    for _, t in ipairs(ctx.eventtaps or {}) do
        if t.running then
            taps = taps + 1
            if t.types["keyDown"] then kd = true end
            if t.types["systemDefined"] then sd = true end
            if t.types["keyUp"] or t.types["flagsChanged"] then ignored = true end
        end
    end
    local served = {}
    if kd then served[#served + 1] = "keyDown" end
    if sd then served[#served + 1] = "systemDefined" end
    local tapMsg
    if taps == 0 then
        tapMsg = "none"
    else
        tapMsg = taps .. " running, serving: " .. (next(served) and table.concat(served, " + ") or "—")
        if ignored then
            tapMsg = tapMsg .. "  (⚠︎ keyUp/flagsChanged taps are NOT delivered)"
        end
    end
    info("Raw eventtaps (hs.eventtap)", tapMsg)

    -- Timers (hs.timer.doAfter / doEvery).
    local timers = ctx.timers and #ctx.timers or 0
    info("Timers", timers == 0 and "none" or (timers .. " scheduled"))
    return rows
end

-- The section is `dynamic = true` so EVERY control change is delivered to
-- settings_action (a static section would silently write the pref and run
-- nothing — the toggle would never install rules without a restart/Apply).
-- That lets the enable toggle install/teardown live, the moment it's flipped.
function settings_render(section_id, _state)
    return host.ui.settings.render(host.ui.settings.ui {
        title = "Hammerspoon",
        subtitle = "Run your ~/.hammerspoon/init.lua through Prosper",
        sections = {
            host.ui.settings.section {
                id = section_id, title = "Hammerspoon", accent = "hammer.fill",
                footer = "Loads ~/.hammerspoon/init.lua and maps hs.* hotkeys + APIs onto "
                    .. "Prosper. Raw eventtaps run via a lazy resident VM; Spoons are inert. "
                    .. "Off by default.",
                rows = {
                    host.ui.settings.row {
                        kind = "toggle", key = "enabled",
                        title = "Load ~/.hammerspoon/init.lua",
                        subtitle = "When off, this extension does nothing at all",
                        value = is_enabled() and "true" or "false",
                    },
                    -- HARD requirement: every shortcut this extension installs rides
                    -- Prosper's CGEvent keystroke tap, and macOS refuses to start that
                    -- tap without Accessibility. Carbon-based app shortcuts work without
                    -- it, which is why those keep firing while hotkeys/remaps/eventtaps/
                    -- media keys stay dead. This row shows the live grant state + a
                    -- one-click "Open" into System Settings and a "Re-check".
                    host.ui.settings.row {
                        kind = "permission", name = "accessibility",
                        title = "Accessibility (required)",
                        subtitle = "Hotkeys, key remaps, raw eventtaps and media keys do "
                            .. "NOT fire without this. Grant it, then Re-check.",
                    },
                    host.ui.settings.row {
                        kind = "info", title = "Config path",
                        subtitle = "~/.hammerspoon/init.lua",
                    },
                    host.ui.settings.row {
                        kind = "button", id = "reload", actionID = "reload",
                        title = "Re-read config",
                        subtitle = "Reload init.lua and reinstall hotkeys (after you edit it)",
                        style = "neon",
                    },
                },
            },
            -- What actually parsed + shimmed — so a config that silently registered
            -- nothing (e.g. an eventtap that never :start()ed) is visible at a glance.
            host.ui.settings.section {
                id = section_id .. ".loaded", title = "What's loaded", accent = "list.bullet",
                footer = "Re-read above after editing init.lua to refresh this list.",
                rows = diagnostics_rows(),
            },
        },
    })
end

-- Toggle flip ("set:enabled") and the "Re-read config" button both reach here.
-- Dynamic sections do NOT auto-persist control values, so the toggle writes the
-- pref itself, then installs (on) or tears down (off) immediately — no restart,
-- no separate Apply step.
function settings_action(section_id, actionID, value, _formJSON)
    if actionID == "set:enabled" then
        host.prefs.set("enabled", value == "true" and "true" or "false")
        if is_enabled() then install() else teardown() end
    elseif actionID == "reload" then
        if is_enabled() then install() else teardown() end
    end
    return settings_render(section_id, "{}")
end
