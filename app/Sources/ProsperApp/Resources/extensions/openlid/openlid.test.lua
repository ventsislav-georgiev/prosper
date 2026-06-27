-- Tests for the openlid extension. Run via scripts/test-extensions.sh (which
-- puts the shared harness on LUA_PATH). Example of how a Prosper extension ships
-- its own tests; *.test.lua is stripped from the app bundle and never published.

local h = require("harness")
local INIT = h.dir() .. "init.lua"
local function state(host) return host.json.decode(host.prefs.get("state") or "{}") end
local function batt(G, host, src)
    G.on_battery(host.json.encode { powerSource = src, percentage = 90 })
end

-- ── Unplug guard (matches the Hammerspoon openlid spoon: no polling) ──────────
do
    local host, env = h.makeHost { power = "AC Power" }
    host.prefs.set("busy_cmd", "dch -ls")
    local G = h.load(INIT, host)

    -- AC plugged -> auto-on, lid-close override engaged.
    env.power = "AC Power"; batt(G, host, "AC Power")
    h.eq(state(host).active, true, "auto-on when plugged")
    h.eq(state(host).autoActivated, true, "marked auto")
    h.eq(env.flags.lidDisabled, true, "lid sleep disabled while awake")

    -- Unplug WITH live sessions -> stays awake, demoted to manual.
    env.shellOut = "session-1\n"; env.power = "Battery Power"; batt(G, host, "Battery Power")
    h.eq(state(host).active, true, "stays awake on unplug with sessions")
    h.eq(state(host).autoActivated, false, "demoted to manual so it won't auto-off")

    -- Reset, fresh auto-on, unplug WITHOUT sessions -> turns off.
    G.openlid_toggle("")                       -- active -> off
    env.power = "AC Power"; batt(G, host, "AC Power")
    h.eq(state(host).autoActivated, true, "re-auto-on after reset")
    env.shellOut = "  \n"; env.power = "Battery Power"; batt(G, host, "Battery Power")
    h.eq(state(host).active, false, "off on unplug when no sessions")
    h.eq(env.flags.lidDisabled, false, "lid override released on off")
end

-- ── Battery threshold wins over the session-hold (no toast whiplash) ──────────
do
    local host, env = h.makeHost { power = "AC Power" }
    host.prefs.set("busy_cmd", "dch -ls")
    host.prefs.set("battery_threshold_pct", "20")
    local G = h.load(INIT, host)
    env.power = "AC Power"; G.on_battery(host.json.encode { powerSource = "AC Power", percentage = 90 })
    h.eq(state(host).active, true, "auto-on while plugged")

    -- Unplug WITH live sessions but BELOW threshold -> battery wins, single off.
    env.shellOut = "session-1\n"; env.power = "Battery Power"
    G.on_battery(host.json.encode { powerSource = "Battery Power", percentage = 9 })
    h.eq(state(host).active, false, "critically low unplug sleeps despite sessions")
    assert(h.lastAlert(env):find("battery"), "only the battery reason is shown, no 'active sessions' whiplash")

    -- Above threshold, the session-hold still applies (held, demoted to manual).
    G.openlid_toggle("")                                  -- reset off
    env.power = "AC Power"; G.on_battery(host.json.encode { powerSource = "AC Power", percentage = 90 })
    env.shellOut = "session-1\n"; env.power = "Battery Power"
    G.on_battery(host.json.encode { powerSource = "Battery Power", percentage = 90 })
    h.eq(state(host).active, true, "healthy battery unplug holds for sessions")
    h.eq(state(host).autoActivated, false, "held session is demoted to manual")
end

-- ── Threshold catches the battery draining past the line while unplugged ──────
do
    local host, env = h.makeHost { power = "Battery Power" }
    host.prefs.set("battery_threshold_pct", "20")
    local G = h.load(INIT, host)
    G.openlid_toggle("")                                  -- manual ON, on battery
    h.eq(state(host).active, true, "manual on")
    -- Same-source % drop (changed=false) must still enforce the threshold.
    G.on_battery(host.json.encode { powerSource = "Battery Power", percentage = 15 })
    h.eq(state(host).active, false, "unchanged-source drain below threshold turns off")
end

-- ── No busy command configured -> plain unplug-off (guard inert) ──────────────
do
    local host, env = h.makeHost { power = "AC Power" }
    local G = h.load(INIT, host)
    env.power = "AC Power"; batt(G, host, "AC Power")
    env.shellOut = "ignored"; env.power = "Battery Power"; batt(G, host, "Battery Power")
    h.eq(state(host).active, false, "unconfigured guard = plain unplug-off")
end

-- ── Toast wording is state-first and human ────────────────────────────────────
do
    local host, env = h.makeHost {}
    local G = h.load(INIT, host)
    G.openlid_toggle("")                        -- turn on (indefinite)
    assert(h.lastAlert(env):find("Mac awake"), "ON toast says 'Mac awake'")
    G.openlid_toggle("")                        -- turn off (manual)
    assert(h.lastAlert(env):find("Mac sleeps"), "OFF toast says 'Mac sleeps'")
    -- Manual off does not append a reason; an auto reason does.
    assert(not h.lastAlert(env):find("manual"), "manual off shows no internal reason")
end

-- ── Display caffeine: independent of the lid override ─────────────────────────
do
    local host, env = h.makeHost {}
    local G = h.load(INIT, host)

    -- Toggle display caffeine on -> only the display assertion engages.
    G.openlid_caffeine("")
    h.eq(state(host).caffeine, true, "caffeine on")
    h.eq(env.flags.idleDisplay, true, "display assertion engaged")
    h.eq(env.flags.idleSystem, false, "caffeine does not touch system sleep")
    h.eq(env.flags.lidDisabled, false, "caffeine does not touch lid override")

    -- Lid override on alongside caffeine -> both live, independent assertions.
    G.openlid_toggle("")
    h.eq(state(host).active, true, "lid override on")
    h.eq(env.flags.idleSystem, true, "system assertion engaged")
    h.eq(env.flags.idleDisplay, true, "display assertion still on")

    -- Turning the lid override off leaves caffeine running.
    G.openlid_toggle("")
    h.eq(state(host).active, false, "lid override off")
    h.eq(env.flags.idleDisplay, true, "caffeine survives lid-override off")
    h.eq(env.flags.idleSystem, false, "system assertion released")

    -- Toggle caffeine off -> display assertion released.
    G.openlid_caffeine("")
    h.eq(state(host).caffeine, false, "caffeine off")
    h.eq(env.flags.idleDisplay, false, "display assertion released")
end

-- ── Timed caffeine + expiry handler ───────────────────────────────────────────
do
    local host, env = h.makeHost {}
    local G = h.load(INIT, host)
    G.on_caff_on(host.json.encode { secs = 1800 })
    h.eq(state(host).caffeine, true, "timed caffeine on")
    assert(env.timers["caffexpiry"], "expiry timer scheduled")
    G.on_caffeine_expiry("")
    h.eq(state(host).caffeine, false, "caffeine off after expiry")
    h.eq(env.flags.idleDisplay, false, "display released on expiry")
end

-- ── Manual activate is REFUSED below the battery threshold (on battery) ───────
do
    local host, env = h.makeHost { power = "Battery Power", pct = 9 }
    host.prefs.set("battery_threshold_pct", "20")
    local G = h.load(INIT, host)
    G.openlid_toggle("")                                  -- manual on attempt
    assert(not state(host).active, "low battery refuses manual activate")
    h.eq(env.flags.idleSystem, false, "no system assertion when refused")
    assert(h.lastAlert(env):find("battery"), "refusal toast names the battery reason")
end

-- ── Menu "Settings…" deep-links to this extension's pane ──────────────────────
do
    local host, env = h.makeHost {}
    local G = h.load(INIT, host)
    G.on_open_settings("")
    h.eq(env.settingsOpened, "openlid", "menu opens the openlid settings pane")
end

-- ── Hot-path cost budgets (deterministic: host-bridge call counts) ────────────
-- Each host.* call is a Lua→Swift hop (often a UserDefaults/pmset/NSScreen
-- syscall), so these counts — not wall-clock — are the stable perf contract.
-- Tighten only with a matching code change; a jump here is a real regression.
do
    local host, env = h.makeHost { power = "AC Power" }
    local G = h.load(INIT, host)
    G.on_launch(host.json.encode { powerSource = "AC Power" })
    G.openlid_toggle("")                                  -- indefinite ON

    -- BUDGET 1: indefinite keep-awake schedules NO repeating timer (no 60s wakeups).
    h.eq(env.timers["tick"], nil, "indefinite session has no periodic tick")

    -- BUDGET 2: a battery event with an UNCHANGED source writes nothing and never
    -- shells out (the busy probe is reserved for the unplug transition).
    h.resetCalls(env)
    G.on_battery(host.json.encode { powerSource = "AC Power", percentage = 88 })
    h.eq(env.calls.prefsSet, 0, "no-transition battery event persists nothing")
    h.eq(env.calls.shell, 0, "no-transition battery event never shells out")

    -- BUDGET 3: a menu render (on_tick) reads ≤2 prefs and sets the menubar once.
    h.resetCalls(env)
    G.on_tick("")
    h.le(env.calls.prefsGet, 2, "render reads at most 2 prefs")
    h.eq(env.calls.menubarSet, 1, "render sets the menubar exactly once")
    h.eq(env.calls.prefsSet, 0, "render never writes")
end

-- ── Unplug transition probes the busy command exactly ONCE ────────────────────
do
    local host, env = h.makeHost { power = "AC Power" }
    host.prefs.set("busy_cmd", "dch -ls")
    local G = h.load(INIT, host)
    env.power = "AC Power"; G.on_battery(host.json.encode { powerSource = "AC Power", percentage = 90 })
    env.shellOut = "s1\n"; env.power = "Battery Power"
    h.resetCalls(env)
    G.on_battery(host.json.encode { powerSource = "Battery Power", percentage = 90 })
    h.eq(env.calls.shell, 1, "unplug runs the busy probe exactly once")
end

-- ── Timed session DOES tick; expiry tears the ticker down ─────────────────────
do
    local host, env = h.makeHost {}
    local G = h.load(INIT, host)
    G.on_menu_on(host.json.encode { secs = 1800 })        -- timed ON
    assert(env.timers["tick"], "timed session schedules the countdown tick")
    assert(env.timers["expiry"], "timed session schedules expiry")
    G.on_expiry("")                                       -- fire expiry
    h.eq(state(host).active, false, "expired session is off")
    h.eq(env.timers["tick"], nil, "ticker cancelled once nothing counts down")
end

-- ── Wall-clock sanity (generous; catches order-of-magnitude regressions only) ─
do
    local host, env = h.makeHost { power = "AC Power" }
    local G = h.load(INIT, host)
    G.openlid_toggle("")
    local us = h.bench(5000, function() G.on_tick("") end) * 1e6
    h.le(us, 200, string.format("render under 200us/call (was %.1f)", us))
    local lus = h.bench(1000, function() h.load(INIT, h.makeHost {}) end) * 1e6
    h.le(lus, 3000, string.format("VM load under 3ms (was %.1f)", lus))
end

-- ── Legacy mac_awake_mode migrates to the two rule checkboxes ─────────────────
do
    -- "power" -> keep-awake-while-plugged-in (auto-on on AC).
    local host, env = h.makeHost { power = "AC Power" }
    host.prefs.set("mac_awake_mode", "power")
    local G = h.load(INIT, host)
    G.on_launch(host.json.encode { powerSource = "AC Power" })
    h.eq(state(host).active, true, "mac_awake_mode=power migrates to auto-on while plugged")
    h.eq(state(host).autoActivated, true, "power migration is the auto (plugged-in) rule")

    -- "on" -> turn-on-at-launch (manual; not auto).
    local host2 = h.makeHost { power = "Battery Power" }
    host2.prefs.set("mac_awake_mode", "on")
    local G2 = h.load(INIT, host2)
    G2.on_launch(host2.json.encode { powerSource = "Battery Power" })
    h.eq(state(host2).active, true, "mac_awake_mode=on migrates to turn-on-at-launch")
    h.eq(state(host2).autoActivated, false, "on migration is manual (survives unplug)")

    -- "restore" -> nothing automatic.
    local host3 = h.makeHost { power = "AC Power" }
    host3.prefs.set("mac_awake_mode", "restore")
    local G3 = h.load(INIT, host3)
    G3.on_launch(host3.json.encode { powerSource = "AC Power" })
    h.eq(state(host3).active, false, "mac_awake_mode=restore does nothing automatic")
end

-- ── Plugged-in rule LOCKS the manual switch (shortcut off is refused) ─────────
do
    local host, env = h.makeHost { power = "AC Power" }      -- rule_on_ac defaults true
    local G = h.load(INIT, host)
    G.on_launch(host.json.encode { powerSource = "AC Power" })
    h.eq(state(host).active, true, "auto-on at launch on AC")
    h.eq(state(host).autoActivated, true, "rule owns the state")
    G.openlid_toggle("")                                     -- try to turn off via shortcut
    h.eq(state(host).active, true, "shortcut off refused while the plugged-in rule owns it")
    assert(h.lastAlert(env):find("plugged in"), "refusal names the plugged-in rule")
    G.on_menu_off("")                                       -- menu "let sleep" also refused
    h.eq(state(host).active, true, "menu off refused while the plugged-in rule owns it")
    -- Unplug releases the auto flag (the only way it clears), so it's no longer locked.
    env.power = "Battery Power"
    G.on_battery(host.json.encode { powerSource = "Battery Power", percentage = 90 })
    h.eq(state(host).active, false, "unplug releases the rule-held session")

    -- A purely manual session (autoActivated false) is NOT locked — off works.
    local host2 = h.makeHost { power = "AC Power" }
    host2.prefs.set("rule_on_ac", "false")                  -- no auto rule
    local G2 = h.load(INIT, host2)
    G2.openlid_toggle("")                                    -- manual ON (not auto)
    h.eq(state(host2).active, true, "manual on")
    G2.openlid_toggle("")                                    -- manual OFF allowed
    h.eq(state(host2).active, false, "manual session is not locked — off works")
end

-- ── Turning the plugged-in rule off in Settings releases its auto session ─────
do
    local host, env = h.makeHost { power = "AC Power" }
    local G = h.load(INIT, host)
    G.on_launch(host.json.encode { powerSource = "AC Power" })
    h.eq(state(host).active, true, "auto-on")
    G.settings_action("openlid", "set:rule_on_ac", "false", "{}")
    h.eq(state(host).active, false, "disabling the rule releases the auto-held session")
    h.eq(host.prefs.get("rule_on_ac"), "false", "rule pref persisted")
end

-- ── Settings render builds the Status + Controls + rule sections (no crash) ────
do
    local host, env = h.makeHost { power = "AC Power" }
    env.shellOut = " SleepDisabled\t\t1\n"                   -- real pmset state = held
    local G = h.load(INIT, host)
    G.openlid_toggle("")                                     -- manual on
    local ui = G.settings_render("openlid", "{}")
    h.eq(ui and ui.kind, "settings.ui", "settings_render builds a settings UI")
    h.eq(ui.sections[1].id, "status", "Status is the first section")
    -- Status reflects the REAL system state, not just our stored flag.
    local awake = ui.sections[1].rows[1]
    h.eq(awake.value, "on", "Status shows Mac-awake ON when disablesleep is held")
end

print("ok openlid")
