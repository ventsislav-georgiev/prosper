-- Unit tests for inputswitch/init.lua. Shared harness (real JSON codec, recorded
-- host side effects) so scripts/test-extensions.sh runs it.
--
-- Guards the switching logic (override > default, no-op when unconfigured, redundant
-- skip) and the settings CRUD (add via app picker, edit source, delete, set default).

local h = require("harness")

local ABC = "com.apple.keylayout.ABC"
local BG  = "com.apple.keylayout.Bulgarian-Phonetic"
local DE  = "com.apple.keylayout.German"

local host, env = h.makeHost{
    layouts = {
        { id = ABC, name = "ABC" },
        { id = BG,  name = "Bulgarian – Phonetic" },
        { id = DE,  name = "German" },
    },
    keyboardSource = ABC,
}
local G = h.load(h.dir() .. "init.lua", host)
local on_app = G.on_app
local J = host.json.encode
local function payload(bundleID) return J{ bundleID = bundleID, name = bundleID, pid = 1 } end
local function lastSet() return env.keyboardSets[#env.keyboardSets] end
local function reset() env.keyboardSets = {}; env.keyboardSource = ABC end

-- 1. override wins for a listed app
host.prefs.set("default", ABC)
host.prefs.set("apps", J{ { bundleID = "com.tinyspeck.slackmacgap", name = "Slack", source = BG } })
reset()
on_app(payload("com.tinyspeck.slackmacgap"))
h.eq(lastSet(), BG, "listed app uses its override source")

-- 2. unlisted app falls back to the default
reset()
env.keyboardSource = BG -- currently on BG, default is ABC -> a real switch fires
on_app(payload("com.apple.Terminal"))
h.eq(lastSet(), ABC, "unlisted app uses the default source")

-- 3. no default + no override -> never touch the layout
env.prefs["default"] = nil
host.prefs.set("apps", J{})
reset()
on_app(payload("com.apple.Terminal"))
h.eq(#env.keyboardSets, 0, "no config -> layout left untouched")

-- 4. redundant select is skipped (already on the wanted source)
host.prefs.set("default", ABC)
reset() -- keyboardSource == ABC
on_app(payload("com.apple.Terminal"))
h.eq(#env.keyboardSets, 0, "already-correct source -> no redundant set")

-- 5. malformed / empty payloads never switch
reset()
on_app(nil); on_app(""); on_app("123"); on_app(J{ name = "x" }); on_app(J{ bundleID = "" })
h.eq(#env.keyboardSets, 0, "nil/empty/garbage payloads switch nothing")

-- 6. corrupt apps pref (non-table) -> empty, falls to default
host.prefs.set("default", BG)
env.prefs["apps"] = "123"
reset() -- ABC current, default BG -> should switch
on_app(payload("com.apple.Terminal"))
h.eq(lastSet(), BG, "corrupt apps pref -> empty list, uses default")

-- 6b. blank-source override must NOT shadow the default (Lua ""-truthiness trap)
host.prefs.set("default", BG)
host.prefs.set("apps", J{ { bundleID = "com.apple.Terminal", name = "Terminal", source = "" } })
reset() -- ABC current, default BG -> blank override falls through to default
on_app(payload("com.apple.Terminal"))
h.eq(lastSet(), BG, "blank override source falls back to default")

-- 6c. hot-path host-hop budget: <=2 prefs.get per activation (apps, then default)
host.prefs.set("default", ABC)
host.prefs.set("apps", J{ { bundleID = "com.tinyspeck.slackmacgap", name = "Slack", source = BG } })
reset(); env.calls.prefsGet = 0; env.calls.kbdLayouts = 0
on_app(payload("com.apple.Terminal")) -- unlisted -> apps.get + default.get
h.le(env.calls.prefsGet, 2, "on_app reads prefs at most twice (apps + default)")
h.eq(env.calls.kbdLayouts, 0, "on_app never enumerates layouts on the hot path")
env.calls.prefsGet = 0
reset()
on_app(payload("com.tinyspeck.slackmacgap")) -- override hit -> apps.get only
h.le(env.calls.prefsGet, 1, "override hit reads prefs once (no default lookup)")

-- 6d. failed set_source (non-selectable source): attempts once, source unchanged,
--     guard never reports success so it does not corrupt state. (storm is self-limited)
host.prefs.set("default", BG)
host.prefs.set("apps", J{})
reset() -- ABC current, want BG
env.keyboardSetFails = true
on_app(payload("com.apple.Terminal"))
h.eq(#env.keyboardSets, 1, "failed set: attempted exactly once per activation")
h.eq(env.keyboardSource, ABC, "failed set: current source unchanged")
env.keyboardSetFails = nil

-- 6e. realistic storm-source: an override pointing at an id NOT in the (selectable-
--     filtered) layouts — i.e. a source disabled in System Settings after picking.
--     set_source fails per real TIS; on_app attempts once, leaves layout as-is.
local GONE = "com.apple.keylayout.Disabled"
host.prefs.set("default", "")
host.prefs.set("apps", J{ { bundleID = "com.apple.Terminal", name = "Terminal", source = GONE } })
reset() -- ABC current; want = GONE, not in layouts -> set fails
on_app(payload("com.apple.Terminal"))
h.eq(lastSet(), GONE, "disabled-after-pick: set attempted with the stale id")
h.eq(env.keyboardSource, ABC, "disabled-after-pick: layout unchanged, no corruption")

-- ── settings_action ──────────────────────────────────────────────────────────
-- 7. add an app via the native picker (record.add -> chooseApp)
env.prefs["apps"] = nil
env.chosenApp = { bundleID = "com.tinyspeck.slackmacgap", name = "Slack" }
host.prefs.set("default", BG)
G.settings_action("inputswitch", "record.add:apps", nil, "{}")
local apps = host.json.decode(env.prefs["apps"])
h.eq(apps and #apps, 1, "add: one app persisted")
h.eq(apps[1].bundleID, "com.tinyspeck.slackmacgap", "add: bundleID persisted")
h.eq(apps[1].source, BG, "add: seeded with the current default source")
h.eq(env.chooseAppCalled, 1, "add: opened the app picker once")

-- 8. cancelling the picker adds nothing
env.chosenApp = nil
G.settings_action("inputswitch", "record.add:apps", nil, "{}")
apps = host.json.decode(env.prefs["apps"])
h.eq(#apps, 1, "cancelled picker -> no app added")

-- 8b. picker returns a partial table (no bundleID) -> guarded, adds nothing
env.chosenApp = { name = "Ghost" }
G.settings_action("inputswitch", "record.add:apps", nil, "{}")
apps = host.json.decode(env.prefs["apps"])
h.eq(#apps, 1, "partial picker result (no bundleID) -> no app added")
env.chosenApp = { bundleID = "com.tinyspeck.slackmacgap", name = "Slack" }

-- 9. add is idempotent on bundleID (no duplicate)
env.chosenApp = { bundleID = "com.tinyspeck.slackmacgap", name = "Slack" }
G.settings_action("inputswitch", "record.add:apps", nil, "{}")
apps = host.json.decode(env.prefs["apps"])
h.eq(#apps, 1, "re-adding same app -> no duplicate")

-- 10. edit a record's source (friendly name -> id)
G.settings_action("inputswitch", "record.save:apps:com.tinyspeck.slackmacgap", nil, J{ source = "German" })
apps = host.json.decode(env.prefs["apps"])
h.eq(apps[1].source, DE, "edit: friendly name -> input id")

-- 11. delete a record
G.settings_action("inputswitch", "record.delete:apps:com.tinyspeck.slackmacgap", "")
apps = host.json.decode(env.prefs["apps"])
h.eq(apps and #apps, 0, "delete removes the override")

-- 12. set:default maps friendly name -> id
G.settings_action("inputswitch", "set:default", "German")
h.eq(env.prefs["default"], DE, "set:default name -> input id")

-- 13. settings_render builds a settings UI with 2 sections (no crash)
host.prefs.set("apps", J{
    { bundleID = "com.tinyspeck.slackmacgap", name = "Slack",    source = BG },
    { bundleID = "org.telegram.desktop",      name = "Telegram", source = DE },
})
env.calls.kbdLayouts = 0
local ui = G.settings_render("inputswitch", "{}")
h.eq(ui and ui.kind, "settings.ui", "settings_render builds a settings UI")
h.eq(#ui.sections, 2, "settings_render builds 2 sections (default/apps)")
-- layout enumeration is O(1) per render, NOT O(records): one TIS hop regardless of N.
h.eq(env.calls.kbdLayouts, 1, "settings_render enumerates layouts exactly once (not 2+3N)")

-- 14. empty layouts() at seed time (transient TIS failure) + no default ->
--     override persisted with source="" and is deliberately inert (no switch).
do
    local host2, env2 = h.makeHost{ layouts = {}, keyboardSource = ABC }
    local G2 = h.load(h.dir() .. "init.lua", host2)
    env2.chosenApp = { bundleID = "com.apple.Terminal", name = "Terminal" }
    G2.settings_action("inputswitch", "record.add:apps", nil, "{}")
    local a2 = host2.json.decode(env2.prefs["apps"])
    h.eq(a2 and #a2, 1, "empty-layouts add: row still persisted")
    h.eq(a2[1].source, "", "empty-layouts add: source seeded empty (inert)")
    env2.keyboardSets = {}
    G2.on_app(host2.json.encode{ bundleID = "com.apple.Terminal", name = "Terminal", pid = 1 })
    h.eq(#env2.keyboardSets, 0, "inert override (source='') + no default -> switches nothing")
end

-- ── performance: on_app hot path ─────────────────────────────────────────────
host.prefs.set("default", ABC)
host.prefs.set("apps", J{
    { bundleID = "com.tinyspeck.slackmacgap", name = "Slack",    source = BG },
    { bundleID = "org.telegram.desktop",      name = "Telegram", source = BG },
})
local p = payload("com.apple.Terminal")
env.keyboardSource = BG -- force a real switch each call
local per = h.bench(20000, function() env.keyboardSource = BG; on_app(p) end) * 1e6
print(string.format("perf: on_app = %.2f us/activation", per))
h.le(per, 1000, "on_app under 1ms/activation hot-path budget")

print("inputswitch: ALL PASS")
