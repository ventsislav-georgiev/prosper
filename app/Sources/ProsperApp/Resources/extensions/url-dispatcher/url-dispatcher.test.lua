-- Unit tests for url-dispatcher/init.lua. Uses the shared harness (real JSON
-- codec, recorded host side effects) so scripts/test-extensions.sh runs it.
--
-- Guards the routing logic + the payload-decode fix: on_url receives a JSON
-- STRING (callGlobal pushes a Lua string), not a table — the old `payload.url`
-- silently no-op'd every link.
--
-- Hot-path budget (asserted below): on_url stays well under 1ms/link — a few
-- prefs reads + a substring scan; links arrive at human click rate, not on the
-- keystroke path, so this is comfortable headroom.

local h = require("harness")
local PROSPER = "eu.illegible.prosper"

local host, env = h.makeHost{ defaultBrowser = PROSPER } -- Prosper is default now
local G = h.load(h.dir() .. "init.lua", host)
local on_url = G.on_url
local J = host.json.encode
local function payload(url) return J{ url = url } end
local function lastBrowser() return env.urlOpened and env.urlOpened.browser end
local function reset() env.urlOpened = nil; env.urlOpens = {}; env.alerts = {} end

-- 1. decode fix: a STRING payload must route (the bug: payload.url == nil)
host.prefs.set("routes", J{ { match = "github.com", browser = "com.google.Chrome" } })
reset()
on_url(payload("https://github.com/x/y"))
h.eq(lastBrowser(), "com.google.Chrome", "string payload routes by rule (decode fix)")
h.eq(env.urlOpened.url, "https://github.com/x/y", "url forwarded intact")

-- 2. proves the OLD path was broken: indexing the JSON string yields nil
h.eq(payload("https://x").url, nil, "indexing JSON string directly is nil (why old code failed)")

-- 3. no rule -> fallback browser
host.prefs.set("fallback", "org.mozilla.firefox")
reset()
on_url(payload("https://example.com"))
h.eq(lastBrowser(), "org.mozilla.firefox", "unmatched link -> fallback")

-- 4. no rule + no fallback -> SAFE_FALLBACK (Safari), never lost
env.prefs["fallback"] = nil
reset()
on_url(payload("https://nowhere.test"))
h.eq(lastBrowser(), "com.apple.Safari", "no fallback -> Safari safety net")

-- 5. loop guard: a rule resolving to Prosper must divert to Safari
host.prefs.set("routes", J{ { match = "loop.test", browser = PROSPER } })
reset()
on_url(payload("https://loop.test/a"))
h.eq(lastBrowser(), "com.apple.Safari", "loop guard: Prosper rule -> Safari")
host.prefs.set("routes", J{ { match = "github.com", browser = "com.google.Chrome" } })

-- 6. malformed / empty payloads never call open
reset()
on_url(nil); on_url(""); on_url(J{ url = "" }); on_url(J{ noturl = 1 })
h.eq(#env.urlOpens, 0, "nil/empty/garbage payloads open nothing")

-- 6b. non-table decode (corrupt/odd payload) must not crash
reset()
on_url("123"); on_url("true")
h.eq(#env.urlOpens, 0, "non-table payload decode -> no crash, no open")

-- 6c. corrupt routes pref (non-table) -> empty, falls to fallback
env.prefs["routes"] = "123"
host.prefs.set("fallback", "com.apple.Safari")
reset()
on_url(payload("https://anything.test"))
h.eq(lastBrowser(), "com.apple.Safari", "corrupt routes pref -> empty, uses fallback")
host.prefs.set("routes", J{ { match = "github.com", browser = "com.google.Chrome" } })

-- 7. first match wins
host.prefs.set("routes", J{
    { match = "docs.google.com", browser = "com.google.Chrome" },
    { match = "google.com",      browser = "com.apple.Safari" },
})
reset()
on_url(payload("https://docs.google.com/d/1"))
h.eq(lastBrowser(), "com.google.Chrome", "first matching rule wins")

-- ── settings_action ──────────────────────────────────────────────────────────
-- 8. add a route (form arrives as the 4th arg form_json, not the value arg)
env.prefs["routes"] = nil
G.settings_action("url-dispatcher", "record.save:routes:", nil, J{ match = "figma.com", browser = "Arc" })
local routes = host.json.decode(env.prefs["routes"])
h.eq(routes and #routes, 1, "add route: one rule persisted")
h.eq(routes[1].match, "figma.com", "add route: match persisted")
h.eq(routes[1].browser, "company.thebrowser.Browser", "add route: friendly name -> bundle id")

-- 9. edit a route (old id removed, new saved, no dup)
G.settings_action("url-dispatcher", "record.save:routes:figma.com", nil, J{ match = "figma.com", browser = "Chrome" })
routes = host.json.decode(env.prefs["routes"])
h.eq(#routes, 1, "edit route: no duplicate")
h.eq(routes[1].browser, "com.google.Chrome", "edit route updates in place")

-- 10. delete a route
G.settings_action("url-dispatcher", "record.delete:routes:figma.com", "")
routes = host.json.decode(env.prefs["routes"])
h.eq(routes and #routes, 0, "delete route removes it")

-- 11. set fallback maps name -> bundle id
G.settings_action("url-dispatcher", "set:fallback", "Brave")
h.eq(env.prefs["fallback"], "com.brave.Browser", "set:fallback name -> bundle id")

-- 12. make_default seeds fallback from the prior default browser
env.prefs["fallback"] = nil
env.defaultBrowser = "com.google.Chrome" -- prior default before takeover
reset()
G.url_dispatcher_make_default()
h.eq(env.prefs["fallback"], "com.google.Chrome", "make_default seeds fallback from prior default")
h.eq(env.defaultBrowser, PROSPER, "make_default sets Prosper default")
h.eq(#env.alerts, 1, "make_default shows one alert")

-- 13. make_default does NOT clobber an existing fallback
host.prefs.set("fallback", "org.mozilla.firefox")
env.defaultBrowser = "com.apple.Safari"
G.url_dispatcher_make_default()
h.eq(env.prefs["fallback"], "org.mozilla.firefox", "make_default keeps existing fallback")

-- 14. settings_render returns a settings UI with the 3 sections (no crash)
host.prefs.set("routes", J{ { match = "github.com", browser = "com.google.Chrome" } })
local ui = G.settings_render("url-dispatcher", "{}")
h.eq(ui and ui.kind, "settings.ui", "settings_render builds a settings UI")
h.eq(#ui.sections, 3, "settings_render builds 3 sections")

-- ── performance: on_url hot path ─────────────────────────────────────────────
host.prefs.set("routes", J{
    { match = "github.com", browser = "com.google.Chrome" },
    { match = "figma.com",  browser = "company.thebrowser.Browser" },
    { match = "localhost",  browser = "com.google.Chrome" },
})
host.prefs.set("fallback", "com.apple.Safari")
local p = payload("https://github.com/some/long/path?q=1")
local per = h.bench(20000, function() on_url(p) end) * 1e6 -- us/call
print(string.format("perf: on_url = %.2f us/link", per))
h.le(per, 1000, "on_url under 1ms/link hot-path budget")

print("url-dispatcher: ALL PASS")
