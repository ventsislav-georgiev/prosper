-- Tests for the openlid extension. Run via scripts/test-extensions.sh (which
-- puts the shared harness on LUA_PATH). Example of how a Prosper extension ships
-- its own tests; *.test.lua is stripped from the app bundle and never published.

local h = require("harness")
local INIT = h.dir() .. "init.lua"
-- The shared harness has no host.log; capture it per host into env.logs.
do
    local makeHost = h.makeHost
    h.makeHost = function(opts)
        local host, env = makeHost(opts)
        env.logs = {}
        local function rec(m) env.logs[#env.logs + 1] = m end
        host.log = { info = rec, warn = rec, error = rec }
        return host, env
    end
end
local function lastLog(env) return env.logs[#env.logs] or "" end
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
    local host, env = h.makeHost { power = "Battery Power" }
    local G = h.load(INIT, host)
    G.openlid_toggle("")                        -- turn on (indefinite)
    assert(h.lastAlert(env):find("Mac awake"), "ON toast says 'Mac awake'")
    G.openlid_toggle("")                        -- turn off (manual)
    assert(h.lastAlert(env):find("Mac sleeps"), "OFF toast says 'Mac sleeps'")
    -- Manual off does not append a reason; an auto reason does.
    assert(not h.lastAlert(env):find("manual"), "manual off shows no internal reason")
end

-- ── Every guard false + lid shut on battery => FORCE sleep (not just release) ─
do
    local host, env = h.makeHost { lidClosed = true, power = "Battery Power" }
    host.prefs.set("network_timeout_min", "2")
    local G = h.load(INIT, host)
    G.openlid_toggle("")                                  -- manual on, lid closed
    h.eq(state(host).active, true, "on")

    -- Network drops -> auto-off timer -> fires. Releasing the assertions alone does
    -- NOT sleep a Mac whose lid is already shut (no new lid-close event, and another
    -- disablesleep writer may still hold), so deactivate must sleep it outright.
    env.reachable = false
    G.on_network(host.json.encode { reachable = false })
    assert(env.timers["netoff"], "netoff scheduled on network loss")
    G.on_netoff("")
    h.eq(state(host).active, false, "off after no-network timeout")
    h.eq(env.flags.lidDisabled, false, "lid override released")
    h.eq(env.flags.sleepNow, 1, "forced sleep with the lid already closed")
end

-- ── netoff arms from reality, not only from events ────────────────────────────
do
    -- Activate while the network is ALREADY gone: no network.changed will ever
    -- arrive, the countdown must start anyway.
    local host, env = h.makeHost { power = "Battery Power" }
    host.prefs.set("network_timeout_min", "2")
    local G = h.load(INIT, host)
    env.reachable = false
    G.openlid_toggle("")
    assert(env.timers["netoff"], "activate while offline arms netoff")

    -- Wake while active + offline (network.changed missed during sleep): same.
    local host2, env2 = h.makeHost { power = "Battery Power" }
    host2.prefs.set("network_timeout_min", "2")
    local G2 = h.load(INIT, host2)
    G2.openlid_toggle("")
    assert(not env2.timers["netoff"], "online: no netoff pending")
    env2.reachable = false
    G2.on_wake("{}")
    assert(env2.timers["netoff"], "wake while offline arms netoff")
end

-- ── Stale netoff fire with the network back => no deactivate, no sleep ────────
do
    local host, env = h.makeHost { lidClosed = true, power = "Battery Power" }
    host.prefs.set("network_timeout_min", "2")
    local G = h.load(INIT, host)
    G.openlid_toggle("")
    env.reachable = false
    G.on_network(host.json.encode { reachable = false })
    env.reachable = true                      -- network returned, cancel event lost
    G.on_netoff("")
    h.eq(state(host).active, true, "stale netoff fire is ignored when reachable")
    h.eq(env.flags.sleepNow, nil, "and it must not force sleep")
end

-- ── Lid open, on AC (clamshell), or caffeine => release only, never sleep ─────
do
    local host, env = h.makeHost { lidClosed = false, power = "Battery Power" }
    local G = h.load(INIT, host)
    G.openlid_toggle("")
    G.openlid_toggle("")
    h.eq(state(host).active, false, "off")
    h.eq(env.flags.sleepNow, nil, "lid open: no forced sleep")

    -- Lid closed on AC is clamshell mode: macOS keeps a docked Mac awake by
    -- design, so a manual off must not put it down under the user.
    local hostAC, envAC = h.makeHost { lidClosed = true, power = "AC Power" }
    hostAC.prefs.set("rule_on_ac", "false")              -- a real off, not back to the rule
    local GAC = h.load(INIT, hostAC)
    GAC.openlid_toggle("")
    GAC.openlid_toggle("")
    h.eq(state(hostAC).active, false, "off")
    h.eq(envAC.flags.sleepNow, nil, "clamshell (AC): no forced sleep")

    -- Display caffeine deliberately on: the user wants the Mac up — release only.
    local host2, env2 = h.makeHost { lidClosed = true, power = "Battery Power" }
    local G2 = h.load(INIT, host2)
    G2.openlid_caffeine("")
    G2.openlid_toggle("")
    G2.openlid_toggle("")
    h.eq(state(host2).active, false, "off")
    h.eq(env2.flags.sleepNow, nil, "caffeine on: no forced sleep")
end

-- ── Display caffeine: independent of the lid override ─────────────────────────
do
    local host, env = h.makeHost { power = "Battery Power" }
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
    local host, env = h.makeHost { power = "Battery Power" }
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
    -- Permissions is ALWAYS present (renderer floats it up + collapses when granted);
    -- it must not appear/disappear on a toggle (that jumped the scroll position).
    h.eq(ui.sections[2].id, "permissions", "Permissions section is always present")
end

-- ── "Sleep this Mac now" releases EVERY hold, even a remote-session one we can't
--    reach through the normal off-switch, and asks the host to sleep ──────────────
do
    local host, env = h.makeHost { power = "AC Power" }
    env.shellOut = " SleepDisabled\t\t1\n"
    local G = h.load(INIT, host)
    G.openlid_toggle("")                                     -- our own override on
    h.eq(env.flags.lidDisabled, true, "lid override held before sleep-now")
    local ui = G.settings_action("openlid", "sleep_now", "", "{}")
    h.eq(env.flags.lidDisabled, false, "sleep-now releases our lid override")
    h.eq(state(host).active, false, "sleep-now clears stored active state")
    h.eq(env.flags.sleepNow, 1, "sleep-now asks the host to release remote holds + sleep")
    -- Must return a FRESH settings tree: a nil return makes the pane keep the
    -- stale pre-click tree ("Mac awake: on") whenever the sleep doesn't take.
    h.eq(ui and ui.kind, "settings.ui", "sleep-now returns a re-rendered settings UI")
end

-- ── Status HUD tells the truth about a hold we didn't set ─────────────────────
do
    local host, env = h.makeHost { power = "AC Power" }
    local G = h.load(INIT, host)
    env.shellOut = " SleepDisabled\t\t1\n"                   -- real pmset = held, but not by us
    local msg = G.openlid_status("")
    assert(msg:find("remote session"), "HUD names the external hold instead of claiming normal sleep")
    env.shellOut = " SleepDisabled\t\t0\n"
    msg = G.openlid_status("")
    assert(msg:find("sleeps normally"), "HUD back to normal once nothing holds")
end

-- ── on_wake reconciles the lid override both ways ──────────────────────────────
do
    local host, env = h.makeHost { power = "AC Power" }
    host.prefs.set("rule_on_ac", "false")                  -- off means off (no rule hold)
    local G = h.load(INIT, host)

    -- Active session: a daemon crash while asleep reset disablesleep; the full
    -- wake must RE-ASSERT it, not just trust the stored flag.
    G.openlid_toggle("")                                     -- manual on
    h.eq(env.flags.lidDisabled, true, "override held")
    env.flags.lidDisabled = false                            -- simulate daemon cold-start reclaim
    G.on_wake("{}")
    h.eq(env.flags.lidDisabled, true, "on_wake re-asserts the override while active")
    h.eq(state(host).active, true, "state untouched")

    -- Stale: not active but the flag survived (e.g. crash between save + release).
    G.openlid_toggle("")                                     -- off (releases)
    local s = state(host); s.lidSleepDisabled = true
    host.prefs.set("state", host.json.encode(s))
    env.flags.lidDisabled = true
    G.on_wake("{}")
    h.eq(env.flags.lidDisabled, false, "on_wake clears a stale override")
    h.eq(state(host).lidSleepDisabled, false, "stale flag cleared in state")
end

-- ── Menubar icon is always exactly ONE glyph (fixed menu-bar width) ───────────
do
    local host, env = h.makeHost { power = "Battery Power" }
    local G = h.load(INIT, host)
    local function icon() G.on_tick(""); return env.menu.title end
    h.eq(icon(), "\u{1F4A4}", "all off = single sleep glyph")
    G.openlid_toggle("")                                     -- Mac awake
    h.eq(icon(), "\u{1F513}", "Mac awake only = single unlock glyph")
    G.openlid_caffeine("")                                   -- + display awake
    h.eq(icon(), "\u{26A1}", "both = single bolt glyph, never a pair")
    G.openlid_toggle("")                                     -- Mac off, display stays
    h.eq(icon(), "\u{2615}", "display awake only = single cup glyph")
    G.openlid_caffeine("")                                   -- all off again
    h.eq(icon(), "\u{1F4A4}", "back to sleep glyph")
    -- No countdown suffix even with a timed session (width must not vary).
    G.on_menu_on(host.json.encode { secs = 1800 })
    h.eq(icon(), "\u{1F513}", "timed session shows the bare glyph, no countdown text")
end

-- ── #502 Plugged-in hold shows 🔌 (sleeps on unplug), apart from manual 🔓/⚡ ──
-- Reads env.menu.title straight after each action: the existing render() calls
-- must already repaint the icon, no on_tick nudge.
do
    local host, env = h.makeHost { power = "AC Power" }      -- rule_on_ac defaults true
    local G = h.load(INIT, host)
    G.on_launch(host.json.encode { powerSource = "AC Power" })
    h.eq(state(host).autoActivated, true, "precondition: plugged-in hold")
    h.eq(env.menu.title, "\u{1F50C}", "rule hold alone = plug glyph")
    assert(env.menu.menu[8].title:find("^\u{1F50C}"), "hold status row starts with plug: " .. env.menu.menu[8].title)
    G.openlid_caffeine("")                                   -- + display awake
    h.eq(env.menu.title, "\u{1F50C}", "rule hold + caffeine = still plug glyph")
    G.openlid_caffeine("")                                   -- display off again
    G.on_menu_on("")                                         -- "Keep awake after unplugging" row
    h.eq(state(host).autoActivated, false, "precondition: now manual")
    h.eq(env.menu.title, "\u{1F513}", "keep after unplugging flips to unlock glyph")
    G.on_menu_off("")                                        -- manual ends on AC, rule on
    h.eq(state(host).autoActivated, true, "precondition: back to the hold")
    h.eq(env.menu.title, "\u{1F50C}", "manual session ending on AC flips back to plug")
    assert(h.lastAlert(env):find("^\u{1F50C}"), "back-to-hold alert starts with plug: " .. h.lastAlert(env))
    G.on_menu_on(host.json.encode { secs = 1800 })           -- duration row: manual on AC
    h.eq(state(host).autoActivated, false, "precondition: manual on AC")
    h.eq(env.menu.title, "\u{1F513}", "manual session on AC keeps unlock glyph")
end

-- ── Menu rows (#482): stay = toggles + durations only; every state has the same
--    rows in the same order, so no row moves under the pointer on a re-render ──
do
    -- One code per row: S = stay row, P = plain clickable row, - = inert, | = separator.
    local function rows(env)
        local out = {}
        for _, r in ipairs(env.menu.menu) do
            if r.separator then out[#out + 1] = "|"
            elseif r.handler and r.enabled ~= false then
                out[#out + 1] = (r.stay == true and "S:" or "P:") .. r.handler
            else
                assert(r.stay == nil, "an inert row is not a stay row: " .. r.title)
                out[#out + 1] = "-"
            end
        end
        return table.concat(out, " ")
    end
    local tail = " | - - | P:on_open_settings"
    local dispOff = "- S:on_caff_on S:on_caff_on S:on_caff_on S:on_caff_on S:on_caff_on |"
    local dispOn  = "- S:on_caff_off - - - - |"
    local macOff  = " - S:on_menu_on S:on_menu_on S:on_menu_on S:on_menu_on S:on_menu_on P:on_menu_until"
    local macOn   = " - S:on_menu_off - - - - -"
    -- #499: the plugged-in hold keeps every on-row live (they make it manual), so
    -- its rows are the off rows; only the titles differ.
    local macRule = macOff

    local host, env = h.makeHost { power = "Battery Power" }
    local G = h.load(INIT, host)
    G.on_tick("")
    h.eq(rows(env), dispOff .. macOff .. tail, "all off")
    G.on_caff_on(host.json.encode { secs = 7200 })           -- display "For 2 hours"
    h.eq(rows(env), dispOn .. macOff .. tail, "display on: same rows, its durations inert")
    G.on_menu_on("")                                         -- Mac awake, no limit
    h.eq(rows(env), dispOn .. macOn .. tail, "both on")
    G.on_caff_off("")
    h.eq(rows(env), dispOff .. macOn .. tail, "Mac on only")

    local host2, env2 = h.makeHost { power = "AC Power" }    -- rule_on_ac defaults true
    local G2 = h.load(INIT, host2)
    G2.on_launch(host2.json.encode { powerSource = "AC Power" })
    G2.on_tick("")
    h.eq(rows(env2), dispOff .. macRule .. tail, "plugged-in rule: same rows, on-rows live")
end

-- ── #499 (a) Menu: a plugged-in hold can become a manual session that survives
--    unplug — indefinite, each duration, and Until… ─────────────────────────────
do
    -- Mac block rows sit after the 6 display rows + separator: 8 status, 9 toggle,
    -- 10..13 durations, 14 Until…  Click the row the menu actually rendered.
    local function menuRow(env, i) return env.menu.menu[i] end
    local function click(G, host, env, i)
        local r = menuRow(env, i)
        assert(r.handler and r.enabled ~= false, "row " .. i .. " is clickable: " .. tostring(r.title))
        G[r.handler](host.json.encode(r.payload or {}))
    end
    local function ruleHeld()
        local host, env = h.makeHost { power = "AC Power" }   -- rule_on_ac defaults true
        local G = h.load(INIT, host)
        G.on_launch(host.json.encode { powerSource = "AC Power" })
        h.eq(state(host).autoActivated, true, "precondition: plugged-in hold")
        return host, env, G
    end

    -- Indefinite: the toggle row.
    local host, env, G = ruleHeld()
    assert(menuRow(env, 8).title:find("plugged in"), "status row names the plugged-in hold")
    h.eq(menuRow(env, 8).enabled, false, "status row stays inert")
    h.eq(menuRow(env, 9).title, "Keep awake after unplugging", "toggle row offers the manual keep")
    h.eq(menuRow(env, 9).stay, true, "toggle row keeps stay")
    click(G, host, env, 9)
    h.eq(state(host).active, true, "still awake")
    h.eq(state(host).autoActivated, false, "now manual")
    h.eq(state(host).endTime, nil, "no limit")
    env.power = "Battery Power"; batt(G, host, "Battery Power")
    h.eq(state(host).active, true, "manual keep survives the unplug")
    h.eq(env.flags.lidDisabled, true, "lid override still held on battery")

    -- Each duration row.
    for i, secs in ipairs { 1800, 3600, 7200, 18000 } do
        local hostD, envD, GD = ruleHeld()
        h.eq(menuRow(envD, 9 + i).stay, true, "duration row keeps stay")
        click(GD, hostD, envD, 9 + i)
        h.eq(state(hostD).autoActivated, false, "duration makes it manual")
        h.eq(state(hostD).endTime, 1000 + secs, "duration sets the end time")
        assert(envD.timers["expiry"], "duration arms expiry")
        envD.power = "Battery Power"; batt(GD, hostD, "Battery Power")
        h.eq(state(hostD).active, true, "timed manual keep survives the unplug")
    end

    -- Until…
    local hostU, envU, GU = ruleHeld()
    envU.dialogReply = "13:30"                                -- harness date is 12:00
    click(GU, hostU, envU, 14)
    h.eq(state(hostU).autoActivated, false, "Until… makes it manual")
    h.eq(state(hostU).endTime, 1000 + 5400, "Until… sets the end time")
    envU.power = "Battery Power"; batt(GU, hostU, "Battery Power")
    h.eq(state(hostU).active, true, "Until… keep survives the unplug")

    -- Off from the plugged-in hold is still refused (the menu has no off row there).
    local hostR, envR, GR = ruleHeld()
    GR.on_menu_off("")
    h.eq(state(hostR).autoActivated, true, "stale off click still respects the hold")
end

-- ── #499 (b) Settings: the locked row is a button that makes the hold manual ──
do
    local function controls(ui)
        for _, sec in ipairs(ui.sections) do if sec.id == "controls" then return sec end end
    end
    local host, env = h.makeHost { power = "AC Power" }
    local G = h.load(INIT, host)
    G.on_launch(host.json.encode { powerSource = "AC Power" })
    local c = controls(G.settings_render("openlid", "{}"))
    local row = c.rows[1]
    h.eq(row.key, "lid_keep", "plugged-in hold: the Mac-awake row is the keep button")
    assert(row.subtitle:find("unplug"), "its copy says what happens on unplug")
    assert(c.footer:find("unplug"), "the Controls footer says what happens on unplug")
    local ui = G.settings_action("openlid", "lid_keep", nil, "{}")
    h.eq(state(host).active, true, "still awake")
    h.eq(state(host).autoActivated, false, "button makes it manual")
    h.eq(state(host).endTime, nil, "no limit")
    h.eq(controls(ui).rows[1].key, "lid_now", "pane re-renders with the manual switch")
    h.eq(controls(ui).rows[1].value, "true", "switch shows on")
    env.power = "Battery Power"; batt(G, host, "Battery Power")
    h.eq(state(host).active, true, "settings keep survives the unplug")
end

-- ── #499 (c) Back to the rule, not to sleep, while plugged in ─────────────────
do
    local function manualOnAC()
        local host, env = h.makeHost { power = "AC Power" }
        local G = h.load(INIT, host)
        G.on_launch(host.json.encode { powerSource = "AC Power" })
        return host, env, G
    end
    local function isRuleHold(host, env, what)
        local s = state(host)
        h.eq(s.active, true, what .. ": still awake")
        h.eq(s.autoActivated, true, what .. ": back to the plugged-in hold")
        h.eq(s.endTime, nil, what .. ": no end time")
        h.eq(env.flags.lidDisabled, true, what .. ": lid override held")
        h.eq(env.flags.idleSystem, true, what .. ": system assertion held")
        h.eq(env.timers["expiry"], nil, what .. ": no expiry left")
    end

    -- Expiry of a timed manual session.
    local host, env, G = manualOnAC()
    G.on_menu_on(host.json.encode { secs = 1800 })
    h.eq(state(host).autoActivated, false, "timed manual")
    G.on_expiry("")
    isRuleHold(host, env, "expiry on AC")
    h.eq(env.timers["tick"], nil, "no countdown left")
    -- ...and the hold it fell back to still lets go on unplug.
    env.power = "Battery Power"; batt(G, host, "Battery Power")
    h.eq(state(host).active, false, "the restored hold releases on unplug")

    -- Turned off by each surface.
    local offs = {
        shortcut = function(G) G.openlid_toggle("") end,
        menu     = function(G) G.on_menu_off("") end,
        settings = function(G) G.settings_action("openlid", "set:lid_now", "false", "{}") end,
    }
    for name, off in pairs(offs) do
        local hostO, envO, GO = manualOnAC()
        GO.on_menu_on("")
        h.eq(state(hostO).autoActivated, false, name .. ": manual")
        off(GO)
        isRuleHold(hostO, envO, name .. " off on AC")
    end

    -- Sleep now means sleep, rule or not.
    local hostS, envS, GS = manualOnAC()
    GS.on_menu_on("")
    GS.settings_action("openlid", "sleep_now", "", "{}")
    h.eq(state(hostS).active, false, "sleep now really turns it off")
    h.eq(envS.flags.lidDisabled, false, "sleep now releases the override")

    -- Rule off, or on battery: off is off.
    local hostB, envB = h.makeHost { power = "Battery Power" }
    local GB = h.load(INIT, hostB)
    GB.on_menu_on(hostB.json.encode { secs = 1800 })
    GB.on_expiry("")
    h.eq(state(hostB).active, false, "expiry on battery is off")
end

-- ── #499 review: manual on AC with the rule on, the off row says what it does ─
do
    local host, env = h.makeHost { power = "AC Power" }
    host.prefs.set("rule_on_ac", "true")
    local G = h.load(INIT, host)
    G.on_launch(host.json.encode { powerSource = "AC Power" })
    G.on_menu_on("")                                         -- hold -> manual
    h.resetCalls(env)
    G.on_tick("")
    h.eq(env.calls.prefsGet, 3, "manual-on-AC render with the key: state + menu icon + rule_on_ac")
    local r = env.menu.menu[9]
    h.eq(r.title, "Let it sleep on unplug", "off row names the return to the hold")
    h.eq(r.handler, "on_menu_off", "same handler")
    h.eq(r.stay, true, "still a stay row")
    local function controls(ui)
        for _, sec in ipairs(ui.sections) do if sec.id == "controls" then return sec end end
    end
    local row = controls(G.settings_render("openlid", "{}")).rows[1]
    h.eq(row.key, "lid_now", "manual switch")
    assert(row.subtitle:find("plugged%-in hold"), "switch copy says off goes back to the hold")
    G[r.handler]("{}")
    h.eq(state(host).autoActivated, true, "and it does go back to the hold")

    -- No rule_on_ac key (a never-touched install, rule on by default): the same
    -- true label, since deactivate goes back to the hold there too.
    local hostD, envD = h.makeHost { power = "AC Power" }
    local GD = h.load(INIT, hostD)
    GD.on_launch(hostD.json.encode { powerSource = "AC Power" })
    GD.on_menu_on("")
    h.resetCalls(envD)
    GD.on_tick("")
    h.eq(envD.menu.menu[9].title, "Let it sleep on unplug", "no key, default rule on: true label")
    h.eq(envD.calls.prefsGet, 5, "no-key render: state + menu icon + rule_on_ac, mac_awake_mode, auto_on_ac")
    GD.on_menu_off("{}")
    h.eq(state(hostD).autoActivated, true, "no key: off does go back to the hold")

    -- On battery, or the legacy key says the rule is off: the old label.
    local hostB, envB = h.makeHost { power = "Battery Power" }
    hostB.prefs.set("rule_on_ac", "true")
    local GB = h.load(INIT, hostB)
    GB.on_launch(hostB.json.encode { powerSource = "Battery Power" })
    GB.on_menu_on("")
    h.eq(envB.menu.menu[9].title, "Let Mac sleep on lid close", "battery: plain off label")
    assert(not controls(GB.settings_render("openlid", "{}")).rows[1].subtitle:find("hold"), "battery: plain switch copy")
    local hostL, envL = h.makeHost { power = "AC Power" }
    hostL.prefs.set("mac_awake_mode", "restore")             -- legacy only, rule off
    local GL = h.load(INIT, hostL)
    GL.on_launch(hostL.json.encode { powerSource = "AC Power" })
    GL.on_menu_on("")
    h.eq(envL.menu.menu[9].title, "Let Mac sleep on lid close", "legacy restore (rule off): old label")
    GL.on_menu_off("{}")
    h.eq(state(hostL).active, false, "legacy restore: off is really off")
end

-- ── #499 (d) No-network guard is battery-only (in transit), armed on unplug ───
do
    local host, env = h.makeHost { power = "AC Power" }
    host.prefs.set("rule_on_ac", "false")
    host.prefs.set("network_timeout_min", "2")
    local G = h.load(INIT, host)
    G.openlid_toggle("")                                     -- manual, on AC
    env.reachable = false
    G.on_network(host.json.encode { reachable = false })
    h.eq(env.timers["netoff"], nil, "no netoff on AC")
    G.on_netoff("")                                          -- a stale fire on AC
    h.eq(state(host).active, true, "netoff fire on AC is ignored")

    env.power = "Battery Power"; batt(G, host, "Battery Power")
    assert(env.timers["netoff"], "unplug with the network gone arms netoff")
    env.power = "AC Power"; batt(G, host, "AC Power")
    h.eq(env.timers["netoff"], nil, "plug-in cancels netoff")
    env.power = "Battery Power"; batt(G, host, "Battery Power")
    G.on_netoff("")
    h.eq(state(host).active, false, "on battery the guard still turns it off")
end

-- ── #499 (d) A plugged-in hold restored on battery is released at launch ──────
do
    local held = '{"active":true,"autoActivated":true,"lidSleepDisabled":true,"lastPowerSource":"AC Power"}'
    local host, env = h.makeHost { power = "Battery Power" }
    host.prefs.set("state", held)
    local G = h.load(INIT, host)
    G.on_launch(host.json.encode { powerSource = "Battery Power" })
    h.eq(state(host).active, false, "hold unplugged while quit is released at launch")
    h.eq(env.flags.lidDisabled, false, "lid override released")
    assert(lastLog(env):find("unplugged while Prosper was not running"), "release logged with its reason")
    G.openlid_toggle("")
    h.eq(state(host).autoActivated, false, "the shortcut is not locked on battery")

    -- Busy command reports work: kept, as manual (same as a live unplug).
    local host2, env2 = h.makeHost { power = "Battery Power", shellOut = "s1\n" }
    host2.prefs.set("state", held)
    host2.prefs.set("busy_cmd", "dch -ls")
    local G2 = h.load(INIT, host2)
    G2.on_launch(host2.json.encode { powerSource = "Battery Power" })
    h.eq(state(host2).active, true, "busy: kept at launch")
    h.eq(state(host2).autoActivated, false, "busy: kept as manual")

    -- Still on AC at launch: the hold stays.
    local host3 = h.makeHost { power = "AC Power" }
    host3.prefs.set("state", held)
    local G3 = h.load(INIT, host3)
    G3.on_launch(host3.json.encode { powerSource = "AC Power" })
    h.eq(state(host3).autoActivated, true, "on AC the restored hold stays")
end

-- ── #499 (d) A stale expiry never ends an indefinite session ──────────────────
do
    local host, env = h.makeHost { power = "Battery Power" }
    local G = h.load(INIT, host)
    G.on_menu_on(host.json.encode { secs = 1800 })
    G.on_menu_off("")
    G.on_menu_on("")                                         -- indefinite now
    G.on_expiry("")                                          -- the old timer's late delivery
    h.eq(state(host).active, true, "stale expiry ignored")
end

-- ── #499 (d) Every deactivation and rule-driven activation is logged ──────────
do
    local host, env = h.makeHost { power = "Battery Power" }
    local G = h.load(INIT, host)
    env.power = "AC Power"; batt(G, host, "AC Power")
    assert(lastLog(env):find("^openlid: on %(plugged in%)"), "rule activation logged: " .. lastLog(env))
    G.on_menu_on(host.json.encode { secs = 600 })
    G.on_expiry("")
    assert(lastLog(env):find("timer expired") and lastLog(env):find("plugged%-in hold"),
        "back-to-rule logged with its reason: " .. lastLog(env))
    env.power = "Battery Power"; batt(G, host, "Battery Power")
    assert(lastLog(env):find("^openlid: off %(unplugged%)"), "deactivation logged: " .. lastLog(env))
    G.openlid_toggle("")
    G.openlid_toggle("")
    assert(lastLog(env):find("^openlid: off %(manual%)"), "manual off logged: " .. lastLog(env))
end

-- ── Lock on lid close: checked = always, awake session or not ────────────────
do
    local host, env = h.makeHost { power = "Battery Power" }
    local G = h.load(INIT, host)

    -- Idle Mac, no keep-awake session: still locks (the old gate skipped this).
    G.on_lid(host.json.encode { closed = true })
    h.eq(env.flags.locked, true, "lid close locks without an active session")

    env.flags.locked = false
    G.on_lid(host.json.encode { closed = false })
    h.eq(env.flags.locked, false, "opening the lid never locks")

    G.openlid_toggle("")                                     -- keep-awake on
    G.on_lid(host.json.encode { closed = true })
    h.eq(env.flags.locked, true, "lid close locks while keeping the Mac awake")

    -- Unchecked = never.
    env.flags.locked = false
    G.settings_action("openlid", "set:lock_on_lid_close", "false", "{}")
    G.on_lid(host.json.encode { closed = true })
    h.eq(env.flags.locked, false, "no lock when the setting is off")
end

print("ok openlid")
