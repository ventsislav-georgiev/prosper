-- Unit tests for toggles/init.lua. Shared harness (real JSON codec, recorded
-- shell/osascript/dialog calls) so scripts/test-extensions.sh runs it.
--
-- Guards the two things that actually bite: the defaults-read parser (unset
-- CreateDesktop ⇒ TRUE, unset AppleShowAllFiles ⇒ false, six boolean spellings)
-- and the destructive paths (cancelled Trash must run ZERO AppleScript; eject
-- must issue exactly one shell call).

local h = require("harness")

-- Build a host whose shell answers per-command. `reads` maps a probe fragment to
-- its canned stdout; every other command returns "" and is recorded in `log`.
local function makeToggles(reads, osaRouter)
    local log = {}
    local host, env = h.makeHost{
        osaRouter = osaRouter,
        shellRouter = function(cmd)
            log[#log + 1] = cmd
            for frag, out in pairs(reads or {}) do
                if cmd:find(frag, 1, true) then return out end
            end
            return ""
        end,
    }
    local G = h.load(h.dir() .. "init.lua", host)
    return G, env, log
end

local DARK_SRC = "set dark mode to not dark mode"

-- 1. dark mode on -> off
do
    local G, env = makeToggles{ ["AppleInterfaceStyle"] = "Dark" }
    h.eq(G.toggles_dark(), "Dark mode off", "dark: on -> off")
    h.eq(#env.osaCalls, 1, "dark: exactly one AppleScript")
    h.eq(env.osaCalls[1]:find(DARK_SRC, 1, true) ~= nil, true, "dark: flips via System Events")
    h.eq(h.lastAlert(env), "Dark mode off", "dark: alert survives the panel closing")
end

-- 2. dark mode off -> on (probe returns nothing = light)
do
    local G, env = makeToggles{}
    h.eq(G.toggles_dark(), "Dark mode on", "dark: off -> on")
    h.eq(#env.osaCalls, 1, "dark: exactly one AppleScript")
end

-- 3. Automation denied -> hint + deep link, no crash
do
    local G, env = makeToggles({}, function()
        return { ok = false, output = "",
                 error = "Not authorized to send Apple events to System Events." }
    end)
    local msg = G.toggles_dark()
    h.eq(msg:find("Automation", 1, true) ~= nil, true, "denied: names Automation")
    h.eq(msg:find("System Settings", 1, true) ~= nil, true, "denied: names System Settings")
    h.eq(env.urlOpened and env.urlOpened.url:find("Privacy_Automation", 1, true) ~= nil, true,
         "denied: opens the Automation pane")
    h.eq(#env.alerts, 0, "denied: no success alert")
end

-- 4. hidden files unset ⇒ default false ⇒ first toggle shows them
do
    local G, _, log = makeToggles{}
    h.eq(G.toggles_hidden(), "Hidden files shown — Finder restarted", "hidden: unset -> show")
    local w = log[#log]
    h.eq(w:find("AppleShowAllFiles -bool true", 1, true) ~= nil, true, "hidden: writes -bool true")
    h.eq(w:find("killall Finder", 1, true) ~= nil, true, "hidden: restarts Finder in the SAME call")
end

-- 5. all six boolean spellings of a defaults read, plus the unset default
for _, c in ipairs{ { "1", false }, { "YES", false }, { "true", false },
                    { "0", true }, { "NO", true }, { "false", true } } do
    local G, _, log = makeToggles{ ["AppleShowAllFiles"] = c[1] }
    G.toggles_hidden()
    h.eq(log[#log]:find("AppleShowAllFiles -bool " .. tostring(c[2]), 1, true) ~= nil, true,
         "hidden: read '" .. c[1] .. "' flips to " .. tostring(c[2]))
end

-- 6. desktop icons unset ⇒ default TRUE (opposite default) ⇒ first toggle hides
do
    local G, _, log = makeToggles{}
    h.eq(G.toggles_desktop(), "Desktop icons hidden — Finder restarted", "desktop: unset -> hide")
    h.eq(log[#log]:find("CreateDesktop -bool false", 1, true) ~= nil, true,
         "desktop: unset means icons ARE shown, so the first flip writes false")
end

-- 7. empty Trash confirmed
do
    local G, env = makeToggles{}
    env.confirmReply = true
    h.eq(G.toggles_trash(), "Trash emptied", "trash: confirmed")
    h.eq(#env.osaCalls, 1, "trash: one AppleScript")
    h.eq(env.osaCalls[1]:find("empty trash", 1, true) ~= nil, true, "trash: empties via Finder")
    h.eq(env.dialogConfirm ~= nil, true, "trash: asked first")
end

-- 8. empty Trash cancelled ⇒ ZERO AppleScript. The destructive-path guard.
do
    local G, env = makeToggles{}
    env.confirmReply = false
    h.eq(G.toggles_trash(), "Cancelled", "trash: cancelled")
    h.eq(env.calls.osascript, 0, "trash: cancel runs NOTHING")
    h.eq(#env.alerts, 0, "trash: cancel is silent")
end

-- 9. eject two disks -> one enumerate + one joined eject call
local TWO_DISKS = [[{"AllDisksAndPartitions":[{"DeviceIdentifier":"disk4"},
                                              {"DeviceIdentifier":"disk6"}]}]]
do
    local G, env, log = makeToggles{
        ["diskutil list"] = TWO_DISKS,
        ["diskutil eject"] = "Disk disk4 ejected\nDisk disk6 ejected",
    }
    h.resetCalls(env)
    h.eq(G.toggles_eject(), "Ejected 2 disks", "eject: both gone")
    h.eq(env.calls.shell, 2, "eject: enumerate + ONE eject call")
    h.eq(log[2]:find("disk4", 1, true) ~= nil and log[2]:find("disk6", 1, true) ~= nil, true,
         "eject: both identifiers in the same call")
end

-- 9b. one disk refuses -> named, not swallowed
do
    local G = makeToggles{
        ["diskutil list"] = TWO_DISKS,
        ["diskutil eject"] = "Disk disk4 ejected\nUnmount of disk6 failed",
    }
    h.eq(G.toggles_eject(), "Could not eject disk6", "eject: names the disk that refused")
end

-- 10. nothing attached -> no eject call at all
do
    local G, env = makeToggles{ ["diskutil list"] = [[{"AllDisksAndPartitions":[]}]] }
    h.resetCalls(env)
    h.eq(G.toggles_eject(), "Nothing to eject", "eject: empty list")
    h.eq(env.calls.shell, 1, "eject: enumerate only")
end

-- 11. malformed plutil output -> graceful message, no Lua error
do
    local G, env = makeToggles{ ["diskutil list"] = "not json <<<" }
    h.resetCalls(env)
    h.eq(G.toggles_eject(), "Could not read attached disks", "eject: garbage JSON")
    h.eq(env.calls.shell, 1, "eject: no eject attempted on unreadable output")
end

-- 12. lock / screensaver go through the host API, never the shell
do
    local G, env = makeToggles{}
    h.resetCalls(env)
    h.eq(G.toggles_lock(), "Screen locked", "lock: result")
    h.eq(G.toggles_screensaver(), "Screen saver started", "screensaver: result")
    h.eq(env.flags.locked, true, "lock: host.caffeinate.lock_screen")
    h.eq(env.flags.screensaver, true, "screensaver: host.caffeinate.start_screensaver")
    h.eq(env.calls.shell, 0, "lock/screensaver: no shell out")
end

-- 13. display off
do
    local G, env, log = makeToggles{}
    h.resetCalls(env)
    h.eq(G.toggles_displayoff(), "Display off", "displayoff: result")
    h.eq(env.calls.shell, 1, "displayoff: one shell call")
    h.eq(log[1], "/usr/bin/pmset displaysleepnow", "displayoff: pmset")
end

-- 14. call budgets — every handler ≤ 3 host hops (shell + osascript)
do
    local G, env = makeToggles{
        ["diskutil list"] = TWO_DISKS,
        ["diskutil eject"] = "Disk disk4 ejected\nDisk disk6 ejected",
    }
    env.confirmReply = true
    for _, name in ipairs{ "toggles_dark", "toggles_hidden", "toggles_desktop", "toggles_trash",
                           "toggles_eject", "toggles_lock", "toggles_screensaver",
                           "toggles_displayoff" } do
        h.resetCalls(env)
        G[name]()
        h.le(env.calls.shell + env.calls.osascript, 3, name .. " within 3 host hops")
    end
end

-- MARK: settings pane (Tier B) -------------------------------------------------

-- Flatten a rendered settings tree to { [row key] = row }.
local function rowsOf(node)
    local t = {}
    for _, sec in ipairs(node.sections or {}) do
        for _, r in ipairs(sec.rows or {}) do t[r.key] = r end
    end
    return t
end

-- 15. render reads LIVE state — never a pref — and costs 3 reads, no AppleScript
do
    local G, env = makeToggles{ ["AppleInterfaceStyle"] = "Dark",
                                ["AppleShowAllFiles"] = "1", ["CreateDesktop"] = "0" }
    h.resetCalls(env)
    local ui = G.settings_render("toggles", "{}")
    local r = rowsOf(ui)
    h.eq(env.settingsRendered, ui, "render: goes through s.render")
    h.eq(r.dark.value, "true", "render: dark mode read from defaults")
    h.eq(r.hidden.value, "true", "render: hidden files read from defaults")
    h.eq(r.desktop.value, "false", "render: desktop icons read from defaults")
    h.eq(env.calls.shell, 3, "render: one read per switch")
    h.eq(env.calls.osascript, 0, "render: opening the pane runs NO AppleScript")
    h.eq(env.calls.prefsGet, 0, "render: system state never comes from host.prefs")
end

-- 16. unset defaults keep the palette's asymmetric fallbacks (icons ON, dotfiles OFF)
do
    local G = makeToggles{}
    local r = rowsOf(G.settings_render("toggles", "{}"))
    h.eq(r.dark.value, "false", "render: unset appearance is light")
    h.eq(r.hidden.value, "false", "render: unset AppleShowAllFiles is hidden")
    h.eq(r.desktop.value, "true", "render: unset CreateDesktop means icons ARE shown")
    h.eq(r.trash.kind, "settings.row", "render: Trash is a row")
    h.eq(r.eject ~= nil and r.lock ~= nil and r.screensaver ~= nil and r.displayoff ~= nil,
         true, "render: every non-toggle command has a button row")
end

-- 17. a switch dispatches the palette handler and re-renders the new state
do
    local G, env, log = makeToggles{}
    local ui = G.settings_action("toggles", "set:hidden", "true", "{}")
    h.eq(rowsOf(ui).hidden ~= nil, true, "action: returns a fresh render")
    h.eq(env.calls.prefsSet, 0, "action: system state is never persisted to prefs")
    h.eq(h.lastAlert(env), "Hidden files shown — Finder restarted",
         "action: same feedback as the palette command")
    h.eq(log[2]:find("AppleShowAllFiles -bool true", 1, true) ~= nil, true,
         "action: writes through the palette handler")
end

-- 18. buttons arrive as their bare key and reach the same handler
do
    local G, env = makeToggles{}
    G.settings_action("toggles", "displayoff", "", "{}")
    h.eq(env.flags.locked, false, "button: displayoff does not lock")
    G.settings_action("toggles", "lock", "", "{}")
    h.eq(env.flags.locked, true, "button: lock reaches host.caffeinate.lock_screen")
end

-- 19. a cancelled Trash from the pane still runs ZERO AppleScript, then re-renders
do
    local G, env = makeToggles{}
    env.confirmReply = false
    h.resetCalls(env)
    local ui = G.settings_action("toggles", "trash", "", "{}")
    h.eq(env.calls.osascript, 0, "pane trash: cancel runs NOTHING")
    h.eq(rowsOf(ui).dark ~= nil, true, "pane trash: cancel still re-renders")
end

-- 20. an unknown action is inert but still returns a render (never nil to the pane)
do
    local G, env = makeToggles{}
    h.resetCalls(env)
    local ui = G.settings_action("toggles", "set:bogus", "true", "{}")
    h.eq(rowsOf(ui).dark ~= nil, true, "unknown action: re-renders")
    h.eq(env.calls.osascript, 0, "unknown action: does nothing")
    h.eq(env.calls.shell, 3, "unknown action: only the render's three reads")
end

print("toggles: ALL PASS")
