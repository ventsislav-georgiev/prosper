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
    keys = { set_rules = function() end },
    timer = { cancel = function() end },
    alert = { show = function() end },
}

-- ---- load real init.lua ----
local env = setmetatable({ host = host }, { __index = _G })
local chunk = assert(loadfile(DIR .. "init.lua", "t", env))
chunk()
local hs_url_open = env.hs_url_open
local on_launch = env.on_launch
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
