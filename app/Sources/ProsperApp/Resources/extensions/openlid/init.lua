-- openlid — system extension. Stateless port of the Hammerspoon openlid spoon and original implementation by https://github.com/openlid/openlid.
--
-- Keeps the Mac awake with the lid closed (system idle-sleep assertion + the
-- `pmset disablesleep` lid-close override), guarded by battery / network / AC.
-- There is NO resident VM: durable state lives in host.prefs, the countdown +
-- expiry run on host-owned durable timers, and every transition arrives as a
-- host event (battery/network/wake/lid) or a menubar click that re-invokes one
-- of the named handlers below. The host releases the native power assertions on
-- disable / quit, so a wedged "stay awake" can never outlive the extension.
--
-- Handler contract: command "openlid.toggle" -> global `openlid_toggle(query)`.
-- Event + timer + menu handlers are the named globals declared in extension.toml
-- / scheduled via host.timer / referenced by menu items; each receives a JSON
-- payload string decoded with host.json.

-- User-tunable settings (OpenLid settings section -> host.prefs). 0 thresholds disable a guard.
local DEFAULTS = {
    rule_on_ac            = true,  -- keep awake while the charger is connected (off on unplug)
    rule_at_launch        = false, -- turn on at every launch (manual; survives unplug)
    auto_on_ac            = true,  -- LEGACY (migrated to rule_on_ac): auto-on when plugged in
    activate_at_launch    = false, -- LEGACY (migrated to rule_at_launch): arm on every launch
    lock_on_lid_close     = true,  -- on lid close while active: lock + blank the display
    show_menu_icon        = true,  -- show the menu bar status item
    battery_threshold_pct = 20,    -- auto-off below this % on battery (0 disables)
    network_timeout_min   = 2,     -- in-transit: auto-off after this many min with no network (0 disables)
    busy_cmd              = "",    -- on AC-unplug: non-empty stdout keeps awake (e.g. `dch -ls`)
    caffeine_at_launch    = false, -- arm display-awake (☕) on every launch
    remote_wake           = false, -- opt-in: dark-wake + poll the server to wake this Mac remotely
    rw_interval_batt_min  = 5,     -- dark-wake check cadence on battery (minutes); dropdown 2..1440
    rw_interval_ac_sec    = 30,    -- dark-wake check cadence on charger (seconds; cost ~free)
    rw_battery_floor_pct  = 20,    -- refuse to wake-promote on battery below this %
    rw_device_id          = "",    -- wake handle (LAN/Tailscale IP, hostname); "" = host auto-detects
}

local STATE_KEY = "state"

local function b2s(v) return v and "true" or "false" end

local function pref_bool(key, default)
    local v = host.prefs.get(key)
    if v == nil or v == "" then return default end
    return v == "true"
end

local function pref_num(key, default)
    local v = host.prefs.get(key)
    if v == nil or v == "" then return default end
    return tonumber(v) or default
end

local function pref_str(key, default)
    local v = host.prefs.get(key)
    if v == nil then return default end
    return v
end

-- Two independent automatic rules (each a plain checkbox), decoupled so the UI can
-- show exactly which one owns the state:
--   rule_on_ac     — on while the charger is plugged in, off when you unplug (auto).
--   rule_at_launch — turn on at every launch and keep it (manual; survives unplug).
-- Both off = "restore last state". They migrate, in order, from the prior single
-- `mac_awake_mode` enum and then from the original `auto_on_ac`/`activate_at_launch`
-- pair, so upgrades keep their behaviour.
local function rule_on_ac()
    local v = host.prefs.get("rule_on_ac")
    if v == "true" or v == "false" then return v == "true" end
    local m = host.prefs.get("mac_awake_mode")
    if m == "power" then return true end
    if m == "on" or m == "restore" then return false end
    return pref_bool("auto_on_ac", DEFAULTS.auto_on_ac)
end
local function rule_at_launch()
    local v = host.prefs.get("rule_at_launch")
    if v == "true" or v == "false" then return v == "true" end
    local m = host.prefs.get("mac_awake_mode")
    if m == "on" then return true end
    if m == "power" or m == "restore" then return false end
    return pref_bool("activate_at_launch", DEFAULTS.activate_at_launch)
end

-- Read settings fresh each call (stateless VM). 0 thresholds collapse to nil = disabled.
local function cfg()
    local bt = pref_num("battery_threshold_pct", DEFAULTS.battery_threshold_pct)
    local nt = pref_num("network_timeout_min", DEFAULTS.network_timeout_min)
    return {
        enableLidCloseOverride = true, -- core feature, not user-tunable
        ruleOnAc               = rule_on_ac(),
        ruleAtLaunch           = rule_at_launch(),
        lockOnLidClose         = pref_bool("lock_on_lid_close", DEFAULTS.lock_on_lid_close),
        showMenuIcon           = pref_bool("show_menu_icon", DEFAULTS.show_menu_icon),
        batteryThreshold       = (bt > 0) and bt or nil,
        networkAutoOffSeconds  = (nt > 0) and (nt * 60) or nil,
        busyCmd                = pref_str("busy_cmd", DEFAULTS.busy_cmd),
        caffeineAtLaunch       = pref_bool("caffeine_at_launch", DEFAULTS.caffeine_at_launch),
        remoteWake             = pref_bool("remote_wake", DEFAULTS.remote_wake),
        rwIntervalBattMin      = pref_num("rw_interval_batt_min", DEFAULTS.rw_interval_batt_min),
        rwBatteryFloor         = pref_num("rw_battery_floor_pct", DEFAULTS.rw_battery_floor_pct),
        rwDeviceId             = pref_str("rw_device_id", DEFAULTS.rw_device_id),
    }
end

-- Push the current remote-wake settings to the daemon (arm if on, disarm if off).
-- The host injects the wake id + server URL; we send only cadence + battery floor.
local function apply_remote_wake()
    host.caffeinate.set_remote_wake{
        enabled       = pref_bool("remote_wake", DEFAULTS.remote_wake),
        interval_ac   = pref_num("rw_interval_ac_sec", DEFAULTS.rw_interval_ac_sec),
        interval_batt = pref_num("rw_interval_batt_min", DEFAULTS.rw_interval_batt_min) * 60,
        battery_floor = pref_num("rw_battery_floor_pct", DEFAULTS.rw_battery_floor_pct),
        device_id     = pref_str("rw_device_id", DEFAULTS.rw_device_id),
    }
end

-- ============ Durable state (host.prefs) ============
local function load_state()
    local raw = host.prefs.get(STATE_KEY)
    return (raw and host.json.decode(raw)) or { active = false }
end

local function save_state(s) host.prefs.set(STATE_KEY, host.json.encode(s)) end

-- ============ Helpers ============
local function running_on_battery() return host.battery.power_source() == "Battery Power" end
local function battery_pct() return host.battery.percentage() or 100 end

-- Custom "busy" guard: a user shell command whose non-empty stdout means
-- "something is running, stay awake" (e.g. `dch -l` listing live sessions).
-- Returns true/false, or nil when no command is configured.
-- `cmd` defaults to the configured busy command; callers that already hold a
-- cfg() pass cmd to avoid re-reading every pref just to learn one string.
local function busy_active(cmd)
    cmd = cmd or cfg().busyCmd
    if cmd == "" then return nil end
    local out = host.shell.run(cmd) or ""
    return out:match("%S") ~= nil -- any non-whitespace output = busy
end

local function fmt_remaining(endTime)
    local rem = math.floor((endTime or 0) - host.time())
    if rem <= 0 then return "0m" end
    if rem < 3600 then return string.format("%dm", math.ceil(rem / 60)) end
    local h = math.floor(rem / 3600)
    local m = math.floor((rem % 3600) / 60)
    if m == 0 then return string.format("%dh", h) end
    return string.format("%dh%dm", h, m)
end
local function format_remaining(s) return s.endTime and fmt_remaining(s.endTime) or "∞" end

-- The earliest pending expiry across both features (for the menubar countdown).
local function soonest(s)
    local a = s.active and s.endTime or nil
    local b = s.caffeine and s.caffeineEnd or nil
    local e = (a and b) and math.min(a, b) or (a or b)
    return e and fmt_remaining(e) or nil
end

-- Human-facing status text (toasts, menu, status HUD) — describes what the Mac
-- is doing now, not the internal flags. Two independent features, each named by
-- the thing it keeps awake so they read apart at a glance:
--   🔓 "Mac awake": the whole Mac stays awake when the lid is CLOSED.
--   ☕ "Display awake": the screen + screensaver stay off while the lid is OPEN.
local function awake_line(s)
    if s.endTime then return "\u{1F513} Mac awake for " .. fmt_remaining(s.endTime) .. " \u{2014} lid can close" end
    return "\u{1F513} Mac awake \u{2014} closing the lid won't sleep"
end
local SLEEP_LINE = "\u{1F4A4} Mac sleeps normally \u{2014} closing the lid sleeps it"

local function caffeine_line(s)
    if s.caffeineEnd then return "\u{2615} Display awake for " .. fmt_remaining(s.caffeineEnd) .. " \u{2014} no screensaver" end
    return "\u{2615} Display awake \u{2014} screen & screensaver stay off"
end
local CAFF_OFF_LINE = "\u{1F4A4} Display sleeps normally"

-- The REAL lid-close override, read from the system (`pmset -g` SleepDisabled) —
-- not our stored intent. This is the OR of every writer (our lid override, a
-- remote-wake session hold, anything else), so the Status section can never lie
-- about whether the lid actually keeps the Mac awake. Used in settings only (not
-- the hot menu render), so the one extra shell-out is fine.
local function real_disablesleep()
    local out = host.shell.run("/usr/bin/pmset -g") or ""
    return out:match("SleepDisabled%s+(%d)") == "1"
end

-- Is the lid-close override ON? Our stored intent (st.active, synchronous so the
-- Status pill flips live the instant a manual toggle lands) OR a real system hold
-- we didn't set. Drives the ON/OFF pill.
local function mac_awake_on(st, real)
    return st.active == true or real == true
end

-- "Who owns it" detail line for the Status row (the ON/OFF itself is the pill, so
-- this carries only the reason). Reconciles our stored intent with the real system
-- state so a hold we didn't set (or a stale one) is named, not hidden.
local function mac_awake_status(st, real)
    if st.active then
        if st.autoActivated then return "Kept awake while plugged in" end
        if st.endTime then return "On for " .. fmt_remaining(st.endTime) .. " \u{2014} turned on manually" end
        return "Turned on manually" end
    -- Held, but not by us: a live remote dch session (the DchSessionServer keep-awake
    -- hold, refreshed while a session is active), or another app / a stale override.
    -- OpenLid's own off-switch can't clear those — "Sleep this Mac now" (below) does.
    if real then return "Held by a remote session or another app \u{2014} use \u{201C}Sleep this Mac now\u{201D} below" end
    return "Mac sleeps when the lid closes"
end

-- True when the plugged-in rule currently OWNS the awake state, so manual "off"
-- (settings switch + shortcut) is refused with a reason instead of fighting it.
-- `autoActivated` is set ONLY by the on-AC rule (activate(_, true)) and any unplug
-- clears it (on_battery demotes to manual or deactivates), so an active auto session
-- ⟹ the plugged-in rule owns it and we're still on AC. That's the whole lock — pure
-- state, zero prefs/battery reads, so the hot menu render stays cheap.
local function rule_lock_active(st)
    st = st or load_state()
    return st.active == true and st.autoActivated == true
end

-- Run the 60s menu-countdown ticker ONLY while a timed session is live. The
-- common case (indefinite keep-awake) shows no changing number, so a periodic
-- redraw there is pure waste — and a stray repeating timer is one more thing to
-- leak. Indefinite => no wakeups at all; the menu still refreshes on every event.
local function tick_wanted(s)
    return (s.active and s.endTime ~= nil) or (s.caffeine and s.caffeineEnd ~= nil)
end
local function sync_tick(s)
    if tick_wanted(s) then
        host.timer.schedule { id = "tick", every = 60, handler = "on_tick" }
    else
        host.timer.cancel("tick")
    end
end

-- ============ Menubar render ============
-- Duration choices offered under each "keep awake" feature in the menu.
local DURATIONS = {
    { title = "For 30 min", secs = 30 * 60 },
    { title = "For 1 hour", secs = 3600 },
    { title = "For 2 hours", secs = 2 * 3600 },
    { title = "For 5 hours", secs = 5 * 3600 },
}

local function build_menu(s)
    local items = {}

    -- ── ☕ Display awake — screen + screensaver stay off while the lid is OPEN ──
    if s.caffeine then
        items[#items + 1] = { title = "\u{2615} Display awake" .. (s.caffeineEnd and (" \u{00B7} " .. fmt_remaining(s.caffeineEnd)) or " \u{00B7} no limit"), enabled = false }
        items[#items + 1] = { title = "Let display sleep", handler = "on_caff_off" }
    else
        items[#items + 1] = { title = "Display sleeps normally", enabled = false }
        items[#items + 1] = { title = "Keep display awake", handler = "on_caff_on" }
        for _, d in ipairs(DURATIONS) do
            items[#items + 1] = { title = "   " .. d.title, handler = "on_caff_on", payload = { secs = d.secs } }
        end
    end

    items[#items + 1] = { separator = true }

    -- ── 🔓 Mac awake — whole Mac stays awake when the lid is CLOSED ──
    if s.active then
        if rule_lock_active(s) then
            -- Plugged-in rule owns the state: match the settings pane + shortcut —
            -- no "let sleep" action, same reason shown, so the menu can't fight it.
            items[#items + 1] = { title = "\u{1F513} Mac awake \u{00B7} kept awake while plugged in", enabled = false }
            items[#items + 1] = { title = "Unplug to let it sleep", enabled = false }
        else
            items[#items + 1] = { title = "\u{1F513} Mac awake with lid closed" .. (s.endTime and (" \u{00B7} " .. fmt_remaining(s.endTime)) or " \u{00B7} no limit"), enabled = false }
            items[#items + 1] = { title = "Let Mac sleep on lid close", handler = "on_menu_off" }
        end
    else
        items[#items + 1] = { title = "Mac sleeps on lid close", enabled = false }
        items[#items + 1] = { title = "Keep Mac awake with lid closed", handler = "on_menu_on" }
        for _, d in ipairs(DURATIONS) do
            items[#items + 1] = { title = "   " .. d.title, handler = "on_menu_on", payload = { secs = d.secs } }
        end
        items[#items + 1] = { title = "   Until\u{2026}", handler = "on_menu_until" }
    end

    items[#items + 1] = { separator = true }
    items[#items + 1] = { title = "External display: " .. (host.screen.count() > 1 and "yes" or "no"), enabled = false }
    items[#items + 1] = { title = string.format("Battery: %d%% (%s)", battery_pct(), running_on_battery() and "battery" or "AC"), enabled = false }
    items[#items + 1] = { separator = true }
    items[#items + 1] = { title = "OpenLid Settings\u{2026}", handler = "on_open_settings" }
    return items
end

local function render(s)
    -- render runs on every event + countdown tick, so read only the one pref it
    -- needs (a full cfg() here was 7 prefs.get to learn one bool).
    if not pref_bool("show_menu_icon", DEFAULTS.show_menu_icon) then host.menubar.remove("main"); return end
    local title
    if not (s.active or s.caffeine) then
        title = "\u{1F4A4}" -- 💤
    else
        title = (s.caffeine and "\u{2615}" or "") .. (s.active and "\u{1F513}" or "") -- ☕ / 🔓
        local r = soonest(s)
        if r then title = title .. " " .. r end
    end
    host.menubar.set { id = "main", title = title, menu = build_menu(s) }
end

-- ============ Core ============
local function activate(durationSec, auto)
    local c = cfg()
    local s = load_state()
    if c.batteryThreshold and running_on_battery() and battery_pct() < c.batteryThreshold then
        host.alert.show(string.format("\u{1F513} Mac stays asleep \u{2014} battery < %d%%", c.batteryThreshold))
        return
    end
    s.active = true
    s.autoActivated = (auto == true)
    host.caffeinate.prevent_idle_sleep("system", true)
    if c.enableLidCloseOverride then
        host.caffeinate.set_disable_lid_sleep(true)
        s.lidSleepDisabled = true
    end
    host.timer.cancel("expiry")
    if durationSec then
        s.endTime = host.time() + durationSec
        host.timer.schedule { id = "expiry", after = durationSec, handler = "on_expiry" }
    else
        s.endTime = nil
    end
    sync_tick(s) -- refresh the countdown while either feature is on
    save_state(s)
    render(s)
    host.alert.show(awake_line(s))
end

local function deactivate(reason)
    local s = load_state()
    if not s.active then return end
    s.active = false
    s.endTime = nil
    host.timer.cancel("expiry")
    host.timer.cancel("netoff")
    host.caffeinate.prevent_idle_sleep("system", false)
    if s.lidSleepDisabled then
        host.caffeinate.set_disable_lid_sleep(false)
        s.lidSleepDisabled = false
    end
    s.autoActivated = false
    sync_tick(s) -- keep ticking if display caffeine is still on
    save_state(s)
    render(s)
    -- Show why only when it wasn't a plain manual toggle (battery, timer, unplug…).
    local why = (reason and reason ~= "manual") and ("  \u{2014} " .. reason) or ""
    host.alert.show(SLEEP_LINE .. why)
end

-- ============ Display caffeine (independent of the lid override) ============
local function caffeine_on(durationSec)
    local s = load_state()
    s.caffeine = true
    host.caffeinate.prevent_idle_sleep("display", true)
    host.timer.cancel("caffexpiry")
    if durationSec then
        s.caffeineEnd = host.time() + durationSec
        host.timer.schedule { id = "caffexpiry", after = durationSec, handler = "on_caffeine_expiry" }
    else
        s.caffeineEnd = nil
    end
    sync_tick(s)
    save_state(s)
    render(s)
    host.alert.show(caffeine_line(s))
end

local function caffeine_off(reason)
    local s = load_state()
    if not s.caffeine then return end
    s.caffeine = false
    s.caffeineEnd = nil
    host.timer.cancel("caffexpiry")
    host.caffeinate.prevent_idle_sleep("display", false)
    sync_tick(s)
    save_state(s)
    render(s)
    local why = (reason and reason ~= "manual") and ("  \u{2014} " .. reason) or ""
    host.alert.show(CAFF_OFF_LINE .. why)
end

local function activate_until(hhmm)
    local h, m = hhmm:match("^(%d%d?):(%d%d)$")
    if not h then host.alert.show("Bad time: " .. hhmm); return end
    h, m = tonumber(h), tonumber(m)
    local d = host.date()
    local now_secs = (d.hour or 0) * 3600 + (d.min or 0) * 60 + (d.sec or 0)
    local delta = (h * 3600 + m * 60) - now_secs
    if delta <= 0 then delta = delta + 86400 end -- next day
    activate(delta, false)
end

-- ============ Command ============
function openlid_toggle(query)
    local s = load_state()
    if s.active then
        if rule_lock_active(s) then
            host.alert.show("\u{1F513} Kept awake while plugged in \u{2014} unplug, or turn off the rule in Settings, to allow sleep")
            return "\u{1F513} Mac awake \u{2014} kept awake while plugged in"
        end
        deactivate("manual")
    else
        activate(nil, false)
    end
    return load_state().active and "\u{1F513} Mac awake \u{2014} lid closed" or "\u{1F4A4} Mac sleeps normally"
end

-- Toggle display caffeine (☕) — independent of the lid override.
function openlid_caffeine(query)
    local s = load_state()
    if s.caffeine then caffeine_off("manual") else caffeine_on(nil) end
    return load_state().caffeine and "\u{2615} Display awake" or "\u{1F4A4} Display sleeps normally"
end

-- Read-only status HUD (cmd+alt+ctrl+shift+L). No state change.
function openlid_status(query)
    local s = load_state()
    local head = s.active and awake_line(s) or SLEEP_LINE
    local msg = string.format("%s\nBattery: %d%% (%s)\nExt display: %s",
        head, battery_pct(), running_on_battery() and "battery" or "AC",
        host.screen.count() > 1 and "yes" or "no")
    local busyCmd = cfg().busyCmd
    if busyCmd ~= "" then
        msg = msg .. "\nSessions: " .. (busy_active(busyCmd) and "active (holds awake on unplug)" or "none")
    end
    host.alert.show(msg, 2.5)
    return msg
end

-- ============ Timer handlers ============
function on_expiry(payload) deactivate("timer expired") end
function on_tick(payload) render(load_state()) end
function on_netoff(payload) deactivate("no network (in transit)") end
function on_caffeine_expiry(payload) caffeine_off("timer expired") end

-- ============ Menu handlers ============
function on_menu_off(payload)
    -- Guard a stale menu (plugged in between render and click): respect the lock.
    if rule_lock_active() then
        host.alert.show("\u{1F513} Kept awake while plugged in \u{2014} unplug, or turn off the rule in Settings, to allow sleep")
        return
    end
    deactivate("menu")
end
function on_caff_off(payload) caffeine_off("menu") end

function on_caff_on(payload)
    local p = host.json.decode(payload) or {}
    caffeine_on(p.secs) -- secs nil => no limit
end

-- Open this extension's pane in the Prosper Settings window.
function on_open_settings(payload) host.settings.open("openlid") end

function on_menu_on(payload)
    local p = host.json.decode(payload) or {}
    activate(p.secs, false) -- secs nil => indefinite
end

function on_menu_until(payload)
    local d = host.date()
    local default = string.format("%02d:%02d", d.hour or 0, d.min or 0)
    local text = host.dialog.prompt {
        title = "OpenLid", message = "Stay awake until (HH:MM):",
        default = default, ok = "OK", cancel = "Cancel",
    }
    if text and text ~= "" then activate_until(text) end
end

-- ============ Event handlers ============
function on_launch(payload)
    local s = load_state()
    -- Re-apply native assertions for a session that was active before a restart
    -- (the host released them on quit). The durable expiry/tick timers were
    -- already restored by the host's TimerScheduler.
    if s.active then
        host.caffeinate.prevent_idle_sleep("system", true)
        if s.lidSleepDisabled then host.caffeinate.set_disable_lid_sleep(true) end
    end
    if s.caffeine then host.caffeinate.prevent_idle_sleep("display", true) end
    local src = host.battery.power_source()
    s.lastPowerSource = src
    save_state(s)
    render(s)
    local c = cfg()
    if not s.active then
        if c.ruleAtLaunch then
            activate(nil, false)              -- manual; survives unplug
        elseif c.ruleOnAc and src == "AC Power" then
            activate(nil, true)               -- auto; releases on unplug
        end
    end
    if not s.caffeine and c.caffeineAtLaunch then caffeine_on(nil) end
    -- Re-arm remote-wake so the app side re-establishes the daemon XPC connection and
    -- its in-memory remote-wake flag. The daemon stays armed across restarts via its
    -- root config, but the APP forgets — and the session keep-awake hold is gated on
    -- the app knowing the daemon is resident, so without this the hold no-ops and a
    -- remotely-woken Mac sleeps mid-session despite a live dch client.
    if c.remoteWake then apply_remote_wake() end
end

function on_battery(payload)
    local p = host.json.decode(payload) or {}
    local c = cfg()
    local s = load_state()
    local src = p.powerSource or host.battery.power_source()
    local changed = (src ~= s.lastPowerSource)
    -- Persist the new source only when it actually moved — a battery event with an
    -- unchanged source (frequent: % updates) shouldn't trigger a UserDefaults write.
    if changed then s.lastPowerSource = src; save_state(s) end

    -- AC plugged in -> auto-enable (marked auto, so the unplug below turns it off)
    if changed and c.ruleOnAc and src == "AC Power" and not s.active then
        activate(nil, true); return
    end
    -- Battery threshold ALWAYS wins (runaway-with-lid-closed protection): check it
    -- before the session-hold so a critically low unplug just sleeps — no "stay
    -- awake / now sleeping" toast whiplash. Runs on every battery event (incl.
    -- unchanged-source % drops), so it also catches the battery draining past the
    -- line while we sit unplugged.
    if s.active and c.batteryThreshold and src == "Battery Power" then
        local pct = (p.percentage and p.percentage >= 0) and p.percentage or battery_pct()
        if pct < c.batteryThreshold then
            deactivate(string.format("battery < %d%%", c.batteryThreshold)); return
        end
    end
    -- AC unplugged while auto-on: keep awake if the busy command reports sessions
    -- (demote to manual so it won't auto-off later); else turn off.
    if changed and src == "Battery Power" and s.active and s.autoActivated then
        if busy_active(c.busyCmd) then
            s.autoActivated = false; save_state(s)  -- now manual; survives unplug
            host.alert.show("\u{1F513} Mac awake \u{2014} active sessions")
        else
            deactivate("unplugged")
        end
    end
end

function on_network(payload)
    local p = host.json.decode(payload) or {}
    local c = cfg()
    local s = load_state()
    if not s.active or not c.networkAutoOffSeconds then return end
    if p.reachable then
        host.timer.cancel("netoff") -- network back: cancel pending shutdown
    else
        host.timer.schedule { id = "netoff", after = c.networkAutoOffSeconds, handler = "on_netoff" }
    end
end

function on_wake(payload)
    -- Reset a stale lid override left set if we are no longer active.
    local s = load_state()
    if not s.active and s.lidSleepDisabled then
        host.caffeinate.set_disable_lid_sleep(false)
        s.lidSleepDisabled = false
        save_state(s)
    end
end

function on_lid(payload)
    local p = host.json.decode(payload) or {}
    local s = load_state()
    if p.closed and s.active and pref_bool("lock_on_lid_close", DEFAULTS.lock_on_lid_close) then
        host.caffeinate.lock_screen()
        host.shell.run("/usr/bin/pmset displaysleepnow")
    end
end

-- ============ Settings (dynamic; persists to host.prefs, applies live) ============
function settings_render(section_id, state)
    local s = host.ui.settings
    local c = cfg()
    local st = load_state()
    local on_ac = not running_on_battery()
    local real = real_disablesleep()

    -- Live remote-terminal (dch) sessions + which ones Prosper currently counts as
    -- active (stamped output within the keep-awake window). Lets you see exactly when
    -- a dch session is holding the Mac awake. Collapsed into ONE info row (a variable
    -- row count would jump the scroll like the remote-wake subtitle did).
    local sessions = host.dch.sessions()
    local sess_active, sess_parts = 0, {}
    for _, se in ipairs(sessions) do
        if se.active then sess_active = sess_active + 1 end
        local label = (se.alias ~= nil and se.alias ~= "") and se.alias or se.name
        sess_parts[#sess_parts + 1] = label .. (se.active and " \u{00B7} active" or " \u{00B7} idle")
    end
    local sess_value, sess_subtitle
    if #sessions == 0 then
        sess_value, sess_subtitle = "none", "No remote terminal (dch) sessions"
    else
        sess_value = sess_active > 0 and string.format("%d active", sess_active)
                                      or string.format("%d idle", #sessions)
        sess_subtitle = table.concat(sess_parts, ", ")
    end

    -- ── STATUS (read-only) — what the Mac is ACTUALLY doing now ────────────────
    -- Separate from the controls (the prior single "Right now" section mixed live
    -- state with the switches, and showed our stored intent instead of the real
    -- pmset state — so it could claim "off" while disablesleep was still held).
    local status = s.section{
        id = "status", title = "Status",
        footer = "What's happening right now. Use the controls below to change it.",
        rows = {
            s.row{ kind = "info", title = "\u{1F513} Mac awake (lid closed)",
                   value = mac_awake_on(st, real) and "on" or "off",
                   subtitle = mac_awake_status(st, real) },
            s.row{ kind = "info", title = "\u{2615} Display awake (no screensaver)",
                   value = st.caffeine and "on" or "off",
                   -- Subtitle drops the title's ☕ + the redundant "Display awake"
                   -- (caffeine_line keeps both — it's reused standalone in the alert
                   -- toast). Status just needs the remaining time / detail.
                   subtitle = st.caffeine
                       and (st.caffeineEnd and (fmt_remaining(st.caffeineEnd) .. " remaining \u{2014} screen & screensaver stay off")
                                            or "Screen & screensaver stay off")
                       or "Display sleeps normally" },
            -- STATIC subtitle: a per-state string changes its wrapped line count,
            -- which shifts content height and bumps the scroll on every toggle. The
            -- pill shows on/off; the wording stays put.
            s.row{ kind = "info", title = "\u{1F4E1} Remote wake",
                   value = c.remoteWake and "on" or "off",
                   subtitle = "Wake this Mac from another device while it sleeps" },
            s.row{ kind = "info", title = "\u{1F5A5}\u{FE0F} Remote sessions",
                   value = sess_value, subtitle = sess_subtitle },
            s.row{ kind = "info", title = "\u{1F50B} Power",
                   subtitle = string.format("Battery %d%% \u{00B7} %s \u{00B7} External display: %s",
                        battery_pct(), on_ac and "on charger" or "on battery",
                        host.screen.count() > 1 and "yes" or "no") },
        },
    }
    -- Keeping the Mac awake with the lid closed needs a root-level sleep override,
    -- which Prosper does through a privileged background helper (no sudo). macOS
    -- asks you to approve it once in System Settings → Login Items. This permission
    -- row reports that grant live + offers an Open button — same pattern as the
    -- Accessibility/Input-Monitoring rows. ALWAYS shown (the renderer floats it to
    -- the top and collapses it once granted): a conditional gate made the whole
    -- section appear/disappear when a feature toggled, jumping the scroll position.
    local permissions = s.section{
        id = "permissions", title = "Permissions",
        rows = { s.row{
            kind = "permission", name = "lid-helper",
            title = "Background helper (keep awake with lid closed)",
        } },
    }
    -- ── CONTROLS — the manual on/off switches. When the plugged-in rule owns the
    -- state, the Mac-awake switch becomes a locked info row (turning it off would
    -- just fight the rule), naming exactly how to release it. ──────────────────
    local lid_control
    if rule_lock_active(st) then
        lid_control = s.row{ kind = "info", title = "Mac awake (lid closed)",
            subtitle = "Locked on \u{2014} kept awake while plugged in. Unplug, or turn off "
                .. "\u{201C}Keep awake while plugged in\u{201D} below, to allow sleep." }
    else
        lid_control = s.row{ kind = "toggle", key = "lid_now", title = "Mac awake (lid closed)",
            subtitle = "Keep the whole Mac running with the lid shut", value = b2s(st.active) }
    end
    local controls = s.section{
        id = "controls", title = "Controls",
        footer = "🔓 Mac awake keeps the whole Mac running when the lid is CLOSED. "
            .. "☕ Display awake keeps the screen and screensaver off while the lid is OPEN. "
            .. "Independent — use either or both.",
        rows = {
            lid_control,
            s.row{ kind = "toggle", key = "caffeine_now", title = "Display awake (no screensaver)",
                   subtitle = "Keep the screen + screensaver off while the lid is open",
                   value = b2s(st.caffeine) },
            -- The hard off-switch: releases EVERY keep-awake hold (incl. a remote
            -- dch-session hold that the toggles above can't reach) and sleeps now.
            s.row{ kind = "button", key = "sleep_now", title = "Sleep this Mac now",
                   subtitle = "Release every keep-awake hold (incl. remote sessions) and sleep immediately" },
        },
    }
    -- ── AUTOMATIC — two independent rules, each its own checkbox (replaces the
    -- old 3-way "at launch" enum) so it's clear which can be on together. ───────
    local general = s.section{
        id = "general", title = "Turn on automatically",
        footer = "Both off = nothing automatic; the last state is restored at launch. "
            .. "“Keep awake while plugged in” turns off when you unplug (unless the Sessions command "
            .. "below still reports work) and locks the manual switch while charging. "
            .. "“Turn on at every launch” arms it each start and keeps it on until you turn it off.",
        rows = {
            s.row{ kind = "toggle", key = "rule_on_ac", title = "Keep awake while plugged in",
                   subtitle = "On when the charger is connected, off when you unplug",
                   value = b2s(c.ruleOnAc) },
            s.row{ kind = "toggle", key = "rule_at_launch", title = "Turn on at every launch",
                   subtitle = "Arm Mac awake each time Prosper starts", value = b2s(c.ruleAtLaunch) },
            s.row{ kind = "toggle", key = "caffeine_at_launch", title = "Display awake at launch",
                   subtitle = "Arm Display awake on every start", value = b2s(c.caffeineAtLaunch) },
            s.row{ kind = "toggle", key = "show_menu_icon", title = "Show menu bar icon",
                   subtitle = "Hide to run without the status item", value = b2s(c.showMenuIcon) },
        },
    }
    local safeguards = s.section{
        id = "safeguards", title = "Safeguards",
        footer = "Set a threshold to 0 to disable that guard.",
        rows = {
            s.row{ kind = "number", key = "battery_threshold_pct", title = "Turn off below battery %",
                   value = tostring(c.batteryThreshold or 0), min = 0, max = 100, step = 5 },
            s.row{ kind = "number", key = "network_timeout_min", title = "Auto-off after no network (min)",
                   subtitle = "In-transit guard: off after this long with no network",
                   value = tostring((c.networkAutoOffSeconds or 0) // 60), min = 0, max = 120, step = 1 },
            s.row{ kind = "toggle", key = "lock_on_lid_close", title = "Lock & turn off display on lid close",
                   value = b2s(c.lockOnLidClose) },
        },
    }
    local busy = s.section{
        id = "busy", title = "Keep awake on unplug",
        footer = "Only used with “Keep awake while plugged in”. When you unplug, this command runs once: "
            .. "non-empty output keeps the Mac awake (work still running); empty lets it sleep. "
            .. "Leave blank to disable. Example: dch -ls",
        rows = {
            s.row{ kind = "text", key = "busy_cmd", title = "Sessions command",
                   subtitle = "Non-empty stdout = stay awake on unplug", value = c.busyCmd,
                   placeholder = "dch -ls" },
        },
    }
    -- Remote wake (opt-in, default off). The ⓘ button pops a native help popover
    -- (button `help` field; dismissed on outside click) — no appended section.
    -- Wake-address dropdown: host auto-detects this Mac's reachable addresses
    -- (Tailscale/LAN IPs + hostname). The user picks one or types any address in
    -- the field below; the SAME handle is what the remote app uses to wake + reach
    -- this Mac. Empty = "Auto" (host picks the hostname). Build with appends (no nil
    -- holes — those truncate ipairs).
    local addr_opts, addr_labels, seen = { "" }, { "Auto-detect (hostname)" }, { [""] = true }
    for _, a in ipairs(host.network.addresses()) do
        if a.address and not seen[a.address] then
            seen[a.address] = true
            local tag = a.kind == "tailscale" and " — Tailscale (recommended)"
                     or a.kind == "lan" and " — local network"
                     or " — hostname"
            addr_opts[#addr_opts + 1] = a.address
            addr_labels[#addr_labels + 1] = a.address .. tag
        end
    end
    if c.rwDeviceId ~= "" and not seen[c.rwDeviceId] then  -- keep a typed custom value selectable
        addr_opts[#addr_opts + 1] = c.rwDeviceId
        addr_labels[#addr_labels + 1] = c.rwDeviceId .. " — custom"
    end
    local remotewake = s.section{
        id = "remotewake", title = "Remote wake",
        footer = "Off by default. Lets you wake this Mac from another device while it sleeps. "
            .. "Pick or type the address the remote app uses to reach this Mac (Tailscale recommended; "
            .. "a local-network IP works if you only ever wake it from the same network). Tap ⓘ for "
            .. "how it works and its limits.",
        rows = {
            -- subtitle is STATIC: a per-state string changed its wrapped line count,
            -- which shifted total content height and bumped the scroll position on
            -- every toggle. The switch itself shows on/off; the footer explains.
            s.row{ kind = "toggle", key = "remote_wake", title = "Wake this Mac remotely",
                   subtitle = "Dark-wakes on a timer to check for a wake request while asleep",
                   value = b2s(c.remoteWake) },
            s.row{ kind = "enum", key = "rw_interval_batt_min", title = "Check every (on battery)",
                   subtitle = "Less often = less battery, slower wake. On charger it checks every 30s.",
                   value = tostring(c.rwIntervalBattMin),
                   options      = { "2", "5", "10", "30", "60", "1440" },
                   optionLabels = { "2 minutes", "5 minutes", "10 minutes", "30 minutes", "1 hour", "1 day" } },
            s.row{ kind = "enum", key = "rw_device_pick", title = "Wake address",
                   subtitle = "How the remote app reaches this Mac",
                   value = c.rwDeviceId, options = addr_opts, optionLabels = addr_labels },
            s.row{ kind = "text", key = "rw_device_id", title = "…or type an address",
                   value = c.rwDeviceId, placeholder = "e.g. 100.92.1.4 or 192.168.1.5 or my-mac.local" },
            s.row{ kind = "number", key = "rw_battery_floor_pct", title = "Don't wake below battery %",
                   value = tostring(c.rwBatteryFloor), min = 0, max = 100, step = 5 },
            s.row{ kind = "button", key = "rw_info",
                   title = "ⓘ How it works & limitations",
                   help =
                "While asleep your Mac briefly dark-wakes on a timer (~5 min on battery, ~30s on charger), "
                .. "makes ONE tiny encrypted check to Prosper's server, and either wakes fully (if you "
                .. "asked it to remotely) or goes right back to sleep. The CPU is up only a few seconds "
                .. "per check.\n\n"
                .. "Limitations:\n"
                .. "• Latency: up to one interval (~5 min on battery) before it wakes after you request it.\n"
                .. "• macOS may stretch the interval in deep standby (occasionally ~20–25 min after hours "
                .. "idle); each macOS update can shift this.\n"
                .. "• Needs Wi-Fi reachable on wake; if the network isn't ready in a few seconds the check "
                .. "is skipped (stays asleep) and retries next interval.\n"
                .. "• Won't wake below your battery floor, to protect against drain.\n"
                .. "• The Mac must be asleep — not shut down or out of battery. Lid-closed on battery works.\n"
                .. "• Only someone signed into YOUR Prosper account can trigger a wake (the request is "
                .. "rejected otherwise), and it exposes only what dch already gates (whois). Checking "
                .. "for a request needs no sign-in and only ever reads (it can't change or cancel anything). "
                .. "Your Mac acts on each request once, never repeatedly (a ~25h backstop expires an unseen request).\n"
                .. "• Drain is negligible in testing (≈0 over a full night) but not zero in theory." },
        },
    }
    local sections = {}
    sections[#sections + 1] = status
    sections[#sections + 1] = permissions
    sections[#sections + 1] = controls
    sections[#sections + 1] = general
    sections[#sections + 1] = safeguards
    sections[#sections + 1] = busy
    sections[#sections + 1] = remotewake
    return s.render(s.ui{
        title = "OpenLid", subtitle = "Keep your Mac awake with the lid closed",
        sections = sections,
    })
end

function settings_action(section_id, action, value, form_json)
    if action == "sleep_now" then
        -- Clear OUR holds (state + lid override + display) so the UI reflects off,
        -- then hand off to the host to drop the remote-session hold and sleep — the
        -- host orders the daemon releases before the sleep on the shared apply chain.
        deactivate("sleep now")
        if load_state().caffeine then caffeine_off("sleep now") end
        host.caffeinate.sleep_now()
        return render(load_state())
    end
    local key = action:match("^set:(.+)$")
    if key == "lid_now" then
        if value == "true" then activate(nil, false) else deactivate("manual") end
    elseif key == "caffeine_now" then
        if value == "true" then caffeine_on(nil) else caffeine_off("manual") end
    elseif key == "rule_on_ac" then
        host.prefs.set(key, value)
        local st = load_state()
        if value == "true" and not running_on_battery() and not st.active then
            activate(nil, true)                  -- begin the plugged-in hold immediately
        elseif value ~= "true" and st.active and st.autoActivated then
            deactivate("plugged-in rule off")    -- release the rule-held session
        else
            render(load_state())
        end
    elseif key == "rw_device_pick" then
        -- The dropdown is just a picker for the canonical rw_device_id pref.
        host.prefs.set("rw_device_id", value)
        apply_remote_wake()
    elseif key then
        host.prefs.set(key, value)  -- toggle "true"/"false", number = string
        if key == "remote_wake" or key:match("^rw_") then
            apply_remote_wake()     -- arm/disarm/re-tune the daemon poll loop
        else
            render(load_state())    -- apply live (menu-icon show/hide, title)
        end
    end
    return settings_render(section_id, "{}")
end
