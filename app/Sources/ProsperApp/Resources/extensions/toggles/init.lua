-- toggles — eight one-shot system actions as parameterless palette rows.
--
-- Everything runs through host APIs that already exist: host.shell.run,
-- host.osascript.run, host.caffeinate.*, host.dialog.confirm, host.alert.show.
-- Zero native code.
--
-- No module state: a palette command is fire-and-forget, so every handler reads
-- the live system, acts, and returns one line. State flips also host.alert.show
-- so the feedback survives the panel closing.

-- MARK: helpers ---------------------------------------------------------------

local AUTOMATION_HINT =
    "Prosper needs Automation access. System Settings › Privacy & Security › Automation"
local AUTOMATION_URL =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

local function sh(cmd)
    local out = host.shell.run(cmd) or ""
    return (out:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- host.osascript.run(src) -> { ok=, output=, error= }
local function osa(src)
    local r = host.osascript.run(src) or {}
    return r.ok == true, r.output or "", r.error or ""
end

-- The bridge surfaces only errorMessage, never AppleScript's errorNumber
-- (−1743 / −1744), so a denied Automation grant is detected by substring.
local function osa_denied(err)
    err = (err or ""):lower()
    return err:find("not authorized", 1, true) ~= nil
        or err:find("not allowed", 1, true) ~= nil
end

-- One failure line for every osascript path. On a suspected consent failure it
-- also opens the Automation pane — macOS never re-prompts once denied, so the
-- deep link is the entire remedy.
local function osa_fail(err)
    if osa_denied(err) then
        host.url.open(AUTOMATION_URL)
        return AUTOMATION_HINT
    end
    return "Failed: " .. ((err ~= "" and err) or "AppleScript error")
end

-- `defaults read` prints 1/0, but a hand-edited plist can hold YES/NO/true/false.
local BOOLS = { ["1"] = true, ["yes"] = true, ["true"] = true,
                ["0"] = false, ["no"] = false, ["false"] = false }

local function finder_flag(key, dflt)
    local v = BOOLS[sh("defaults read com.apple.finder " .. key .. " 2>/dev/null"):lower()]
    if v == nil then return dflt end -- unset / read error -> caller's default
    return v
end

-- ponytail: plain `killall Finder` where upstream quits Finder via AppleScript and
-- polls pgrep — the graceful path costs a Finder Automation prompt to preserve
-- window state. Upgrade to the graceful quit only if the lost windows annoy.
-- Must stay ONE shell string: split in two, Finder can re-persist its cached prefs
-- on SIGTERM and undo the write.
local function set_finder_flag(key, on)
    sh("defaults write com.apple.finder " .. key .. " -bool " .. tostring(on)
       .. " && killall Finder")
end

-- Free read (no consent) even though the write needs System Events.
local function is_dark()
    return sh("defaults read -g AppleInterfaceStyle 2>/dev/null") == "Dark"
end

local function say(msg)
    host.alert.show(msg)
    return msg
end

-- MARK: handlers (command id with non-alphanumerics -> '_') ---------------------

function toggles_dark()
    local was_dark = is_dark()
    local ok, _, err = osa('tell application "System Events" to tell appearance '
                           .. 'preferences to set dark mode to not dark mode')
    if not ok then return osa_fail(err) end
    return say(was_dark and "Dark mode off" or "Dark mode on")
end

function toggles_hidden()
    local show = not finder_flag("AppleShowAllFiles", false) -- unset ⇒ hidden
    set_finder_flag("AppleShowAllFiles", show)
    return say((show and "Hidden files shown" or "Hidden files hidden")
               .. " — Finder restarted")
end

function toggles_desktop()
    -- CreateDesktop unset ⇒ TRUE (icons shown) — the opposite default to
    -- AppleShowAllFiles, and the classic off-by-one in this feature.
    local show = not finder_flag("CreateDesktop", true)
    set_finder_flag("CreateDesktop", show)
    return say((show and "Desktop icons shown" or "Desktop icons hidden")
               .. " — Finder restarted")
end

function toggles_trash()
    -- Irreversible: the confirm is mandatory and deliberately has no
    -- "don't ask again" pref.
    local go = host.dialog.confirm{
        title   = "Empty Trash?",
        message = "Everything in the Trash is deleted permanently.",
        ok      = "Empty Trash",
        cancel  = "Cancel",
    }
    if not go then return "Cancelled" end
    local ok, _, err = osa('tell application "Finder" to empty trash')
    if not ok then return osa_fail(err) end
    return say("Trash emptied")
end

function toggles_eject()
    -- `diskutil list -plist external` IS upstream's isLocal && !isRoot &&
    -- (!isInternal || isRemovable || isEjectable) predicate, computed by the OS.
    local raw = sh("/usr/sbin/diskutil list -plist external "
                   .. "| /usr/bin/plutil -convert json -o - -")
    local data = host.json.decode(raw)
    -- diskutil always emits AllDisksAndPartitions (empty when nothing is attached),
    -- so a missing key means unreadable output, not an empty machine.
    local disks = type(data) == "table" and data.AllDisksAndPartitions or nil
    if type(disks) ~= "table" then return "Could not read attached disks" end

    local ids, cmds = {}, {}
    for _, d in ipairs(disks) do
        local id = type(d) == "table" and d.DeviceIdentifier or nil
        if type(id) == "string" and id ~= "" then
            ids[#ids + 1] = id
            cmds[#cmds + 1] = "/usr/sbin/diskutil eject " .. id
        end
    end
    if #ids == 0 then return "Nothing to eject" end

    -- ONE shell call with the ejects joined: each eject takes seconds and
    -- host.shell.run is time-boxed per call, so N calls is N timeouts to lose.
    local out = sh(table.concat(cmds, "; ") .. " 2>&1")
    local failed = {}
    for _, id in ipairs(ids) do
        if not out:find(id .. " ejected", 1, true) then failed[#failed + 1] = id end
    end
    if #failed > 0 then
        return say("Could not eject " .. table.concat(failed, ", "))
    end
    return say("Ejected " .. #ids .. (#ids == 1 and " disk" or " disks"))
end

-- No alert for the next three: the screen is about to be gone.
function toggles_lock()
    host.caffeinate.lock_screen()
    return "Screen locked"
end

function toggles_screensaver()
    host.caffeinate.start_screensaver()
    return "Screen saver started"
end

function toggles_displayoff()
    sh("/usr/bin/pmset displaysleepnow")
    return "Display off"
end

-- MARK: settings (Tier B) ------------------------------------------------------
--
-- The three switches show LIVE system state, so they are rendered from Lua
-- rather than declared as static controls (a static toggle persists to
-- host.prefs — the wrong source of truth when any other app can flip the same
-- bit). State is read ONCE per render: on pane open and again after each action.
-- Nothing is polled; a flip made elsewhere meanwhile self-corrects on the next
-- action's re-render.

local function b2s(v) return v and "true" or "false" end

function settings_render(section_id, state)
    local s = host.ui.settings

    local live = s.section{
        id = "state", title = "System", accent = "Toggles",
        footer = "Read when this pane opens — the same switches the palette "
            .. "commands flip. Showing or hiding files restarts Finder.",
        rows = {
            s.row{ kind = "toggle", key = "dark", title = "Dark mode",
                   subtitle = "System appearance", value = b2s(is_dark()) },
            s.row{ kind = "toggle", key = "hidden", title = "Hidden files in Finder",
                   subtitle = "Show dotfiles and other hidden entries",
                   value = b2s(finder_flag("AppleShowAllFiles", false)) },
            s.row{ kind = "toggle", key = "desktop", title = "Desktop icons",
                   subtitle = "Show everything sitting on the desktop",
                   value = b2s(finder_flag("CreateDesktop", true)) },
        },
    }

    local actions = s.section{
        id = "actions", title = "Actions",
        footer = "Each runs immediately. Emptying the Trash asks first — it "
            .. "cannot be undone.",
        rows = {
            s.row{ kind = "button", key = "trash", title = "Empty Trash",
                   subtitle = "Permanently delete everything in the Trash" },
            s.row{ kind = "button", key = "eject", title = "Eject All Disks",
                   subtitle = "Eject every external disk in one go" },
            s.row{ kind = "button", key = "lock", title = "Lock Screen",
                   subtitle = "Lock the screen immediately" },
            s.row{ kind = "button", key = "screensaver", title = "Start Screen Saver",
                   subtitle = "Start the screen saver now" },
            s.row{ kind = "button", key = "displayoff", title = "Turn Display Off",
                   subtitle = "Sleep the display without locking or sleeping the Mac" },
        },
    }

    return s.render(s.ui{
        title = "Quick Toggles",
        subtitle = "One-click system actions",
        sections = { live, actions },
    })
end

-- Buttons arrive as their key, switches as "set:<key>" — both dispatch to the
-- palette handler, so the pane and the palette can never drift apart. The switch
-- value is ignored on purpose: the handlers flip against a fresh read of the
-- system, which is more current than the rendered value the user clicked.
local ACTIONS = {
    dark = toggles_dark, hidden = toggles_hidden, desktop = toggles_desktop,
    trash = toggles_trash, eject = toggles_eject, lock = toggles_lock,
    screensaver = toggles_screensaver, displayoff = toggles_displayoff,
}

function settings_action(section_id, action, value, form_json)
    local fn = ACTIONS[action:match("^set:(.+)$") or action]
    -- Always re-render, including after a no-op: that is what snaps a switch back
    -- when the action did not take (a denied Automation grant leaves dark mode
    -- exactly where it was).
    if fn then fn() end
    return settings_render(section_id, "{}")
end
