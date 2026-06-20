-- Standalone test for the hammerspoon-compat URL-routing shim. Pure Lua: mocks
-- host.* + a fake ~/.hammerspoon/init.lua and drives the real init.lua's
-- hs_url_open end-to-end. Run: `lua test_url_routing.lua` (no app build).
--
-- Covers: parse_url; httpCallback invoked with (scheme,host,params,fullURL);
-- openURLWithBundle routing + loop guard; setDefaultHandler suppressed on the
-- per-link rebuild (must not re-steal the default browser every link); no-op when
-- the config defines no httpCallback; disabled gate.

local DIR = (arg[0]:match("^(.*/)") or "./")

-- ---- mock host ----
local prefs = { enabled = "true" }
local opened = {}
local set_default_calls = {}
local kbd_set = {} -- host.keyboard.set_source calls (per-app input switching)
local scheduled, alerts, confirms, osascripts = {}, {}, {}, {}
local confirm_result = true -- what host.dialog.confirm returns (OK vs Cancel)
local hidden = {}           -- host.apps.hide calls (bundleID) — window API
local window_count = 0      -- what host.apps.windows returns (AX window count)
local FAKE_INIT = [[
hs.urlevent.setDefaultHandler("http")
hs.urlevent.httpCallback = function(scheme, host, params, fullURL)
    if host == "github.com" then
        hs.urlevent.openURLWithBundle(fullURL, "com.google.Chrome")
    elseif host == "self.test" then
        hs.urlevent.openURLWithBundle(fullURL, "eu.illegible.prosper")  -- loop bait
    else
        hs.urlevent.openURLWithBundle(fullURL, "org.mozilla.firefox")
    end
end
]]

local function json_decode(s)
    -- only the shapes the handlers use: {"url":"..."} and {"id":"..."}
    local url = s and s:match('"url"%s*:%s*"(.-)"')
    if url then return { url = url } end
    local id = s and s:match('"id"%s*:%s*"(.-)"')
    if id then return { id = id } end
    local name = s and s:match('"name"%s*:%s*"(.-)"')
    if name then return { name = name } end -- app.activated payload {"name":...}
    return {}
end
local function json_encode() return "{}" end

local default_browser = "com.apple.Safari" -- mutable so tests can flip the default
local function id_ui(o) o = o or {}; return o end
host = {
    prefs = { get = function(k) return prefs[k] end, set = function(k, v) prefs[k] = v end },
    json = { decode = json_decode, encode = json_encode },
    fs = { read = function() return FAKE_INIT end },
    perms = { has = function() return true end },
    url = {
        open = function(u, b) opened[#opened + 1] = { url = u, browser = b } end,
        default_browser = function() return default_browser end,
        set_default_browser = function(id) set_default_calls[#set_default_calls + 1] = id; return true end,
    },
    ui = { settings = {
        ui = function(o) o = o or {}; o.kind = "settings.ui"; return o end,
        section = id_ui, row = id_ui,
        render = function(node) return node end,
    } },
    time = function() return 0 end,
    env = { get = function() return nil end },
    log = { info = function() end, warn = function() end, error = function(m) print("ERR " .. tostring(m)) end },
    keys = { set_rules = function() end, stroke = function() end },
    timer = { cancel = function() end,
              schedule = function(spec) scheduled[#scheduled + 1] = spec end }, -- doAfter/doEvery
    alert = { show = function(t) alerts[#alerts + 1] = t end },
    dialog = { confirm = function(o) confirms[#confirms + 1] = o; return confirm_result end },
    osascript = { run = function(src) osascripts[#osascripts + 1] = src
                                       return { ok = true, output = "", error = "" } end },
    apps = { frontmost = function() return { name = "Finder", bundleID = "com.apple.finder", pid = 1 } end,
             launch_or_focus = function() end,
             windows = function(_) return window_count end,
             hide = function(bid) hidden[#hidden + 1] = bid end },
    keyboard = {
        current_source = function() return "com.apple.keylayout.ABC" end,
        layouts = function() return { { id = "id.ABC", name = "ABC" },
                                      { id = "id.BG", name = "Bulgarian-Phonetic" } } end,
        set_source = function(id) kbd_set[#kbd_set + 1] = id; return true end,
    },
}

-- ---- load real init.lua ----
local env = setmetatable({ host = host }, { __index = _G })
local chunk = assert(loadfile(DIR .. "init.lua", "t", env))
chunk()
local hs_url_open = env.hs_url_open
local on_launch = env.on_launch
local hs_app_activated = env.hs_app_activated
local hs_dispatch = env.hs_dispatch
local hs_timer_fired = env.hs_timer_fired
local settings_render = env.settings_render

local fails = 0
local function check(c, m) if not c then fails = fails + 1; print("FAIL: " .. m) else print("ok: " .. m) end end
local function reset() opened = {}; set_default_calls = {} end
local function last() return opened[#opened] end
local function payload(url) return '{"url":"' .. url .. '"}' end

-- 1. cold VM: hs_url_open rebuilds config + fires httpCallback -> routes by host
env._HS = nil
reset()
hs_url_open(payload("https://github.com/a/b"))
check(last() and last().browser == "com.google.Chrome", "cold VM routes github -> Chrome via httpCallback")
check(last() and last().url == "https://github.com/a/b", "full URL passed to callback")

-- 2. CRITICAL: open fired even though rebuild mode suppresses side effects
--    (proves ctx.firing=true wraps the callback so openURLWithBundle's gate opens)
check(#opened == 1, "callback side effect (open) actually ran under rebuild VM")

-- 3. setDefaultHandler must NOT run on the per-link rebuild (would re-steal default)
check(#set_default_calls == 0, "setDefaultHandler suppressed on per-link rebuild")

-- 4. loop guard: callback routing to Prosper itself diverts to Safari
reset()
hs_url_open(payload("https://self.test/x"))
check(last() and last().browser == "com.apple.Safari", "loop guard: openURLWithBundle(Prosper) -> Safari")

-- 5. default branch routes unmatched host -> firefox
reset()
hs_url_open(payload("https://random.example/p"))
check(last() and last().browser == "org.mozilla.firefox", "unmatched host -> firefox (config's else)")

-- 6. on_launch (register mode) DOES run setDefaultHandler once
env._HS = nil
reset()
on_launch(nil)
check(#set_default_calls == 1 and set_default_calls[1] == "eu.illegible.prosper",
      "on_launch register: setDefaultHandler sets Prosper default once")

-- 7. config without httpCallback -> hs_url_open is a no-op
FAKE_INIT = "local x = 1\n"   -- no urlevent usage
env._HS = nil
reset()
hs_url_open(payload("https://github.com/a"))
check(#opened == 0, "no httpCallback in config -> no routing (no-op)")
FAKE_INIT = [[
hs.urlevent.httpCallback = function(scheme, host, params, fullURL)
    hs.urlevent.openURLWithBundle(fullURL, "com.google.Chrome")
end
]]

-- 8. disabled gate: nothing fires when enabled pref is off
prefs.enabled = "false"
env._HS = nil
reset()
hs_url_open(payload("https://github.com/a"))
check(#opened == 0, "disabled extension routes nothing")
prefs.enabled = "true"

-- 9. malformed payloads
env._HS = nil
reset()
hs_url_open(nil); hs_url_open(""); hs_url_open('{"nope":1}')
check(#opened == 0, "nil/empty/garbage payload -> no routing")

-- 9b. diagnostics: a "URL routing (hs.urlevent)" row reflects httpCallback presence
local function find_row(ui, title)
    for _, sec in ipairs(ui and ui.sections or {}) do
        for _, r in ipairs(sec.rows or {}) do
            if r.title == title then return r end
        end
    end
end
-- config WITH httpCallback (restored at end of test 7), Prosper NOT the default
FAKE_INIT = [[
hs.urlevent.httpCallback = function(scheme, host, params, fullURL)
    hs.urlevent.openURLWithBundle(fullURL, "com.google.Chrome")
end
]]
env._HS = nil
local row = find_row(settings_render("hammerspoon-compat", "{}"), "URL routing (hs.urlevent)")
check(row ~= nil, "diagnostics shows a URL routing row")
check(row and row.subtitle and row.subtitle:find("NOT the default", 1, true) ~= nil,
      "URL row warns when httpCallback set but Prosper isn't default")
default_browser = "eu.illegible.prosper"
env._HS = nil
row = find_row(settings_render("hammerspoon-compat", "{}"), "URL routing (hs.urlevent)")
check(row and row.subtitle and row.subtitle:find("route through your config", 1, true) ~= nil,
      "URL row confirms routing when Prosper IS default")
default_browser = "com.apple.Safari"
-- config WITHOUT httpCallback -> row says none
FAKE_INIT = "local x = 1\n"
env._HS = nil
row = find_row(settings_render("hammerspoon-compat", "{}"), "URL routing (hs.urlevent)")
check(row and row.subtitle == "none", "URL row says none when config has no httpCallback")
FAKE_INIT = [[
hs.urlevent.httpCallback = function(scheme, host, params, fullURL)
    hs.urlevent.openURLWithBundle(fullURL, "com.google.Chrome")
end
]]

-- 9d. URLDispatcher Spoon shim: a config that routes via spoon.URLDispatcher
--     (url_patterns + a url_redir_decoder using hs.http.urlParts) drives the same
--     hs.urlevent.httpCallback path. Proves the shim wires start()->httpCallback,
--     applies decoders before patterns, and falls back to default_handler.
FAKE_INIT = [[
hs.loadSpoon("SpoonInstall")
local function strip_utm(scheme, host, params, fullURL)
    local p = hs.http.urlParts(fullURL)
    if not p.query then return fullURL end
    local kept = {}
    for pair in p.query:gmatch("[^&]+") do
        local k = pair:match("([^=]+)=")
        if k ~= "utm_source" then kept[#kept + 1] = pair end
    end
    local q = table.concat(kept, "&")
    return p.scheme .. "://" .. p.host .. (p.path or "") .. (q ~= "" and ("?" .. q) or "")
end
spoon.SpoonInstall:andUse("URLDispatcher", {
    config = { default_handler = "com.apple.Safari" },
    start = true,
})
spoon.URLDispatcher.url_patterns = {
    { "github%.com", "com.google.Chrome" },
}
spoon.URLDispatcher.url_redir_decoders = {
    { "strip utm", strip_utm, nil, true },
}
]]
env._HS = nil
reset()
hs_url_open(payload("https://github.com/x"))
check(last() and last().browser == "com.google.Chrome", "URLDispatcher: github -> Chrome via url_patterns")
reset()
hs_url_open(payload("https://example.com/p?utm_source=x&id=5"))
check(last() and last().browser == "com.apple.Safari", "URLDispatcher: unmatched -> default_handler (Safari)")
check(last() and not last().url:find("utm_source") and last().url:find("id=5") ~= nil,
      "URLDispatcher: decoder stripped utm, kept id (" .. tostring(last() and last().url) .. ")")
-- diagnostics row should show the live route/rewriter counts
default_browser = "eu.illegible.prosper"
env._HS = nil
row = find_row(settings_render("hammerspoon-compat", "{}"), "URL routing (hs.urlevent)")
check(row and row.subtitle and row.subtitle:find("route(s)", 1, true) ~= nil,
      "URLDispatcher: diagnostics shows route/rewriter counts")
default_browser = "com.apple.Safari"
FAKE_INIT = [[
hs.urlevent.httpCallback = function(scheme, host, params, fullURL)
    hs.urlevent.openURLWithBundle(fullURL, "com.google.Chrome")
end
]]

-- 9e. app.activated: hs.application.watcher.new(fn):start() fires per-app input
--     switching via hs.keycodes.currentSourceID (the "Keyboard Pilot" init.lua idiom).
FAKE_INIT = [[
local bg = "com.apple.keylayout.Bulgarian-Phonetic"
local map = { Slack = bg, Telegram = bg }
local function upd(app) hs.keycodes.currentSourceID(map[app] or "com.apple.keylayout.ABC") end
appWatcher = hs.application.watcher.new(function(app, event)
    if event == hs.application.watcher.activated then upd(app) end
end)
appWatcher:start()
]]
env._HS = nil; kbd_set = {}
on_launch(nil) -- register: records the watcher (started), fires no callback
check(#kbd_set == 0, "no input switch at register (watcher only records)")
hs_app_activated('{"name":"Slack"}')
check(kbd_set[#kbd_set] == "com.apple.keylayout.Bulgarian-Phonetic", "app.activated Slack -> Bulgarian")
hs_app_activated('{"name":"Finder"}')
check(kbd_set[#kbd_set] == "com.apple.keylayout.ABC", "app.activated Finder -> default ABC")
check(#kbd_set == 2, "one input switch per activation")

-- 9f. disabled gate + malformed payloads don't switch input
prefs.enabled = "false"; env._HS = nil; kbd_set = {}
hs_app_activated('{"name":"Slack"}')
check(#kbd_set == 0, "disabled extension switches no input source")
prefs.enabled = "true"
env._HS = nil; kbd_set = {}
hs_app_activated(nil); hs_app_activated(""); hs_app_activated('{"nope":1}')
check(#kbd_set == 0, "nil/empty/garbage app.activated payload -> no switch")

-- 9g. hs.keycodes.layouts(true) -> source ids (vs names), observed via the setter
FAKE_INIT = [[
appWatcher = hs.application.watcher.new(function(app, event)
    if event == hs.application.watcher.activated then
        hs.keycodes.currentSourceID(hs.keycodes.layouts(true)[2]) -- 2nd source *id*
    end
end)
appWatcher:start()
]]
env._HS = nil; kbd_set = {}
on_launch(nil)
hs_app_activated('{"name":"X"}')
check(kbd_set[1] == "id.BG", "hs.keycodes.layouts(true) returns source ids")

-- 9h. hs.dialog.blockAlert + deferred work: the Empty-Trash idiom. A hotkey shows a
--     modal confirm; on OK it schedules an osascript via hs.timer.doAfter (NOT run
--     synchronously). The host fires timer.fired later -> the osascript runs.
FAKE_INIT = [[
hs.hotkey.bind({"cmd", "shift"}, "delete", function()
    local btn = hs.dialog.blockAlert("Empty Trash", "Sure?", "Empty Trash", "Cancel", "warning")
    if btn == "Empty Trash" then
        hs.alert.show("Emptying Trash...")
        hs.timer.doAfter(0.1, function()
            if hs.osascript.applescript('tell application "Finder" to empty trash') then
                hs.alert.show("emptied")
            end
        end)
    end
end)
]]
env._HS = nil; scheduled = {}; alerts = {}; confirms = {}; osascripts = {}
on_launch(nil)
local trash_idx
for i, b in ipairs(env._HS.ctx.binds) do if b.combo == "cmd+shift+delete" then trash_idx = i end end
check(trash_idx ~= nil, "cmd+shift+delete bind recorded (keycode-based, layout-independent)")
-- Cancel: confirm returns the cancel button -> no work scheduled
confirm_result = false
hs_dispatch(tostring(trash_idx))
check(#confirms == 1, "blockAlert shows a confirm dialog")
check(#scheduled == 0 and #osascripts == 0, "Cancel -> nothing scheduled, no osascript")
-- OK: schedules the osascript via doAfter, does NOT run it synchronously
confirm_result = true; scheduled = {}; alerts = {}; confirms = {}; osascripts = {}
hs_dispatch(tostring(trash_idx))
check(#osascripts == 0, "Empty Trash deferred (in doAfter), not run synchronously")
check(#scheduled == 1 and scheduled[1].handler == "hs_timer_fired", "doAfter scheduled a host timer")
-- the host fires timer.fired -> the deferred osascript runs
hs_timer_fired('{"id":"' .. scheduled[1].id .. '"}')
check(#osascripts == 1 and osascripts[1]:find("empty trash") ~= nil, "timer.fired runs the empty-trash osascript")

-- 9i. window API: hideAppIfNoWindows(app) hides the frontmost app only when it has
--     zero windows. app:allWindows() length tracks host.apps.windows (AX count);
--     app:hide() calls host.apps.hide, gated on the firing context.
FAKE_INIT = [[
function hideAppIfNoWindows(app)
    if #app:allWindows() == 0 then app:hide() end
end
hs.hotkey.bind({"cmd"}, "W", function()
    hideAppIfNoWindows(hs.application.frontmostApplication())
end)
]]
env._HS = nil; hidden = {}
on_launch(nil)
local w_idx
for i, b in ipairs(env._HS.ctx.binds) do if b.combo == "cmd+w" then w_idx = i end end
check(w_idx ~= nil, "cmd+w bind recorded")
window_count = 2; hidden = {}
hs_dispatch(tostring(w_idx))
check(#hidden == 0, "windows remain (allWindows #=2) -> app NOT hidden")
window_count = 0; hidden = {}
hs_dispatch(tostring(w_idx))
check(#hidden == 1 and hidden[1] == "com.apple.finder", "no windows -> host.apps.hide(frontmost bundleID)")

-- 9j. perf: cmd+W -> hideAppIfNoWindows warm dispatch. Measures SHIM overhead only
--     (frontmostApplication + allWindows table build + hide gate). In production
--     host.apps.windows is an AX cross-process query (~ms) that dominates; the shim
--     wrapper around it must stay negligible. HOT-PATH REQUIREMENT: < 200us/press.
window_count = 1; hidden = {} -- has a window: build list, no hide (steady state)
local W = 5000
local t0w = os.clock()
for _ = 1, W do hs_dispatch(tostring(w_idx)) end
local perw = (os.clock() - t0w) / W * 1e6
print(string.format("perf: cmd+W hideAppIfNoWindows (warm) = %.2f us/press", perw))
check(perw < 200, "warm window-check dispatch under 200us/press (shim overhead)")

-- restore the URL-routing config for the perf tests below
FAKE_INIT = [[
hs.urlevent.httpCallback = function(scheme, host, params, fullURL)
    hs.urlevent.openURLWithBundle(fullURL, "com.google.Chrome")
end
]]

-- 10. perf: warm-VM hs_url_open (closure already built) per link
env._HS = nil
hs_url_open(payload("https://github.com/warm"))   -- warm it
local N = 5000
local p = payload("https://github.com/some/path")
local t0 = os.clock()
for _ = 1, N do hs_url_open(p) end
local per = (os.clock() - t0) / N * 1e6
print(string.format("perf: hs_url_open (warm) = %.2f us/link", per))
check(per < 2000, "warm hs_url_open under 2ms/link")

-- 11. perf: cold-VM hs_url_open (re-reads + reparses config each link)
local M = 2000
t0 = os.clock()
for _ = 1, M do env._HS = nil; hs_url_open(p) end
local cold = (os.clock() - t0) / M * 1e6
print(string.format("perf: hs_url_open (cold rebuild) = %.2f us/link", cold))
check(cold < 5000, "cold hs_url_open under 5ms/link (re-runs init.lua)")

print(fails == 0 and "\nALL PASS" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
