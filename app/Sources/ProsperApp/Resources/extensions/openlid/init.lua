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
    auto_on_ac            = true,  -- LEGACY (migrated to mac_awake_mode): auto-on when plugged in
    activate_at_launch    = false, -- LEGACY (migrated to mac_awake_mode): arm on every launch
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

-- One mode replaces the old activate_at_launch + auto_on_ac toggle pair (4 combos,
-- one of them self-contradictory). The mode decides what happens at launch and when
-- power changes; the "Right now" toggle is still the manual live switch.
--   "restore" — do nothing automatic; the last live state is restored.
--   "on"      — turn Mac-awake on at launch and keep it (manual; survives unplug).
--   "power"   — on while plugged in, off when unplugged (the only mode that auto-offs).
-- Legacy prefs are mapped on first read so upgrades keep their behaviour.
local function mac_awake_mode()
    local m = host.prefs.get("mac_awake_mode")
    if m == "on" or m == "power" or m == "restore" then return m end
    if pref_bool("activate_at_launch", false) then return "on" end
    if pref_bool("auto_on_ac", DEFAULTS.auto_on_ac) then return "power" end
    return "restore"
end

-- Read settings fresh each call (stateless VM). 0 thresholds collapse to nil = disabled.
local function cfg()
    local bt = pref_num("battery_threshold_pct", DEFAULTS.battery_threshold_pct)
    local nt = pref_num("network_timeout_min", DEFAULTS.network_timeout_min)
    return {
        enableLidCloseOverride = true, -- core feature, not user-tunable
        macAwakeMode           = mac_awake_mode(),
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
        items[#items + 1] = { title = "\u{1F513} Mac awake with lid closed" .. (s.endTime and (" \u{00B7} " .. fmt_remaining(s.endTime)) or " \u{00B7} no limit"), enabled = false }
        items[#items + 1] = { title = "Let Mac sleep on lid close", handler = "on_menu_off" }
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
    if s.active then deactivate("manual") else activate(nil, false) end
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
function on_menu_off(payload) deactivate("menu") end
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
        if c.macAwakeMode == "on" then
            activate(nil, false)
        elseif c.macAwakeMode == "power" and src == "AC Power" then
            activate(nil, true)
        end
    end
    if not s.caffeine and c.caffeineAtLaunch then caffeine_on(nil) end
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
    if changed and c.macAwakeMode == "power" and src == "AC Power" and not s.active then
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
    -- Live on/off for both features (flip here = flip now), plus arm-at-launch.
    local now_rows = {
        s.row{ kind = "toggle", key = "lid_now", title = "Mac awake (lid closed)",
               subtitle = st.active and awake_line(st) or "Off — Mac sleeps on lid close",
               value = b2s(st.active) },
        s.row{ kind = "toggle", key = "caffeine_now", title = "Display awake (no screensaver)",
               subtitle = st.caffeine and caffeine_line(st) or "Off — display sleeps normally",
               value = b2s(st.caffeine) },
    }
    -- Keeping the Mac awake with the lid closed needs a root-level sleep override,
    -- which Prosper does through a privileged background helper (no sudo). macOS
    -- asks you to approve it once in System Settings → Login Items. This permission
    -- row reports that grant live + offers an Open button — same pattern as the
    -- Accessibility/Input-Monitoring rows. Only shown when the lid-closed feature
    -- is actually engaged (on now, or armed at launch), so it's silent otherwise.
    local permissions = nil
    if st.active or c.macAwakeMode == "on" or c.macAwakeMode == "power" or c.remoteWake then
        permissions = s.section{
            id = "permissions", title = "Permissions",
            rows = { s.row{
                kind = "permission", name = "lid-helper",
                title = "Background helper (keep awake with lid closed)",
            } },
        }
    end
    local now = s.section{
        id = "now", title = "Right now",
        footer = "🔓 Mac awake keeps the whole Mac running when the lid is CLOSED. "
            .. "☕ Display awake keeps the screen and screensaver off while the lid is OPEN. "
            .. "Independent — use either or both.",
        rows = now_rows,
    }
    local general = s.section{
        id = "general", title = "At launch",
        footer = "Mac awake at launch — “Restore last state” brings back whatever was on when you quit; "
            .. "“Turn on” arms it every launch and keeps it on; "
            .. "“On while plugged in” keeps it awake only while the charger is connected and turns it off when you unplug "
            .. "(unless the Sessions command below still reports work).",
        rows = {
            s.row{ kind = "enum", key = "mac_awake_mode", title = "Mac awake at launch",
                   value = c.macAwakeMode,
                   options      = { "restore", "on", "power" },
                   optionLabels = { "Restore last state", "Turn on", "On while plugged in" } },
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
        footer = "Only used in “On while plugged in” mode. When you unplug, this command runs once: "
            .. "non-empty output keeps the Mac awake (work still running); empty lets it sleep. "
            .. "Leave blank to disable. Example: dch -ls",
        rows = {
            s.row{ kind = "text", key = "busy_cmd", title = "Sessions command",
                   subtitle = "Non-empty stdout = stay awake on unplug", value = c.busyCmd,
                   placeholder = "dch -ls" },
        },
    }
    -- Remote wake (opt-in, default off). The ⓘ button expands a detail section
    -- with how-it-works + every caveat — a "pops up on click" affordance built from
    -- the existing button + section primitives (no new control kind).
    local rw_open = pref_bool("rw_info_open", false)
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
            s.row{ kind = "toggle", key = "remote_wake", title = "Wake this Mac remotely",
                   subtitle = c.remoteWake and "On — dark-wakes on a timer to check for a wake request"
                                            or "Off — Mac is unreachable while asleep",
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
                   title = rw_open and "ⓘ Hide details" or "ⓘ How it works & limitations" },
        },
    }
    local rw_details = nil
    if rw_open then
        rw_details = s.section{
            id = "remotewake_info", title = "Remote wake — how it works & limits",
            footer =
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
                .. "• Drain is negligible in testing (≈0 over a full night) but not zero in theory.",
            rows = {},
        }
    end
    local sections = {}
    if permissions then sections[#sections + 1] = permissions end
    sections[#sections + 1] = now
    sections[#sections + 1] = general
    sections[#sections + 1] = safeguards
    sections[#sections + 1] = busy
    sections[#sections + 1] = remotewake
    if rw_details then sections[#sections + 1] = rw_details end
    return s.render(s.ui{
        title = "OpenLid", subtitle = "Keep your Mac awake with the lid closed",
        sections = sections,
    })
end

function settings_action(section_id, action, value, form_json)
    -- Button (no "set:" prefix): the ⓘ details expander toggles its own pref.
    if action == "rw_info" then
        host.prefs.set("rw_info_open", b2s(not pref_bool("rw_info_open", false)))
        return settings_render(section_id, "{}")
    end
    local key = action:match("^set:(.+)$")
    if key == "lid_now" then
        if value == "true" then activate(nil, false) else deactivate("manual") end
    elseif key == "caffeine_now" then
        if value == "true" then caffeine_on(nil) else caffeine_off("manual") end
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
