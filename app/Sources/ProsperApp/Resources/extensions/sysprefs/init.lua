-- sysprefs — open a System Settings pane from the palette.
--
-- `ss ` locks the runner into this command; the rest of the query substring-
-- filters a curated pane table and the result is a host.ui.list. Each row
-- carries `url = "x-apple.systempreferences:<id>"`, so Enter goes through the
-- runner's native URL-open path (dismiss + NSWorkspace.open) — the same route
-- Bookmarks and Quicklinks rows use. Nothing here touches host.shell, and the
-- filter is pure Lua, so a keystroke costs zero host-bridge hops.
--
-- Handler contract: the host invokes the global named after the command id with
-- non-alphanumerics replaced by '_'. For "sysprefs.open" that is
-- `sysprefs_open(query)`. The runner restores the "ss " prefix before calling,
-- so strip it back off. Returns nil to decline (no pane matched).
--
-- ponytail: the pane table is hardcoded and therefore frozen per macOS release.
-- The thorough version enumerates /System/Library/ExtensionKit/Extensions/*.appex
-- and reads EXAppExtensionAttributes.SettingsExtensionAttributes
-- .allowsXAppleSystemPreferencesURLScheme, which means a `plutil` shell-out per
-- bundle on every launch. Not worth it: a renamed/absent pane id simply no-ops
-- when opened. Upgrade path if Apple starts churning ids — enumerate once and
-- cache the result in host.prefs, refreshed on system.launch.

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- { title, pane id, extra keywords (lowercase, space-separated), SF Symbol }.
-- Ids are the macOS 13+ Settings extension bundle ids; `?Anchor` selects a
-- sub-pane. Keywords carry the old System Preferences names and the words people
-- actually type, since the titles alone miss most of them.
local PANES = {
    { "Wi-Fi",                 "com.apple.wifi-settings-extension",                          "wifi wireless network airport",       "wifi" },
    { "Bluetooth",             "com.apple.BluetoothSettings",                                "bt pair devices",                     "dot.radiowaves.right" },
    { "Network",               "com.apple.Network-Settings.extension",                       "ethernet dns proxy tcp ip",           "network" },
    { "VPN",                   "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension",  "vpn tunnel",                          "lock.shield" },
    { "Displays",              "com.apple.Displays-Settings.extension",                      "monitor screen resolution scaling",   "display" },
    { "Sound",                 "com.apple.Sound-Settings.extension",                         "audio volume output input speakers",  "speaker.wave.2" },
    { "Focus",                 "com.apple.Focus-Settings.extension",                         "do not disturb dnd",                  "moon" },
    { "Notifications",         "com.apple.Notifications-Settings.extension",                 "alerts banners badges",               "bell" },
    { "Screen Time",           "com.apple.Screen-Time-Settings.extension",                   "limits downtime parental",            "hourglass" },
    { "General",               "com.apple.systempreferences.GeneralSettings",                "about",                               "gear" },
    { "Software Update",       "com.apple.Software-Update-Settings.extension",               "macos upgrade patch",                 "arrow.down.circle" },
    { "Storage",               "com.apple.settings.Storage",                                 "disk space free purgeable",           "internaldrive" },
    { "Startup Disk",          "com.apple.Startup-Disk-Settings.extension",                  "boot volume",                         "power" },
    { "Time Machine",          "com.apple.Time-Machine-Settings.extension",                  "backup restore",                      "clock.arrow.circlepath" },
    { "Sharing",               "com.apple.Sharing-Settings.extension",                       "screen sharing file remote login ssh", "shared.with.you" },
    { "Login Items",           "com.apple.LoginItems-Settings.extension",                    "startup launch agents open at login", "arrow.right.square" },
    { "Date & Time",           "com.apple.Date-Time-Settings.extension",                     "clock timezone ntp",                  "calendar" },
    { "Language & Region",     "com.apple.Localization-Settings.extension",                  "locale translate format",             "globe" },
    { "Appearance",            "com.apple.Appearance-Settings.extension",                    "dark light mode accent theme",        "paintbrush" },
    { "Desktop & Dock",        "com.apple.Desktop-Settings.extension",                       "hot corners mission control spaces stage manager", "dock.rectangle" },
    { "Control Center",        "com.apple.ControlCenter-Settings.extension",                 "menu bar",                            "switch.2" },
    { "Wallpaper",             "com.apple.Wallpaper-Settings.extension",                     "desktop picture background",          "photo" },
    { "Screen Saver",          "com.apple.ScreenSaver-Settings.extension",                   "screensaver idle",                    "sparkles.tv" },
    { "Lock Screen",           "com.apple.Lock-Screen-Settings.extension",                   "require password idle screensaver",   "lock.display" },
    { "Touch ID & Password",   "com.apple.Touch-ID-Settings.extension",                      "fingerprint biometric",               "touchid" },
    { "Users & Groups",        "com.apple.Users-Groups-Settings.extension",                  "accounts admin guest",                "person.2" },
    { "Passwords",            "com.apple.Passwords-Settings.extension",                      "keychain autofill 2fa otp",           "key" },
    { "Internet Accounts",     "com.apple.Internet-Accounts-Settings.extension",             "mail icloud google exchange",         "at" },
    { "Apple Account",         "com.apple.systempreferences.AppleIDSettings",                "apple id icloud",                     "person.crop.circle" },
    { "Keyboard",              "com.apple.Keyboard-Settings.extension",                      "shortcuts key repeat text replacement modifier", "keyboard" },
    { "Trackpad",              "com.apple.Trackpad-Settings.extension",                      "gestures scroll tap to click",        "rectangle.and.hand.point.up.left" },
    { "Mouse",                 "com.apple.Mouse-Settings.extension",                         "pointer scroll tracking",             "computermouse" },
    { "Printers & Scanners",   "com.apple.Print-Scan-Settings.extension",                    "printer scanner cups",                "printer" },
    { "Battery",               "com.apple.Battery-Settings.extension",                       "power energy low power mode sleep",   "battery.100" },
    { "Accessibility",         "com.apple.Accessibility-Settings.extension",                 "voiceover zoom display contrast",     "figure.arms.open" },
    { "Privacy & Security",    "com.apple.settings.PrivacySecurity.extension",               "gatekeeper firewall filevault permissions", "hand.raised" },
    -- Permission sub-panes: the reason most people open Settings at all.
    { "Accessibility Access",  "com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility", "privacy permission control my computer automation", "figure.arms.open" },
    { "Full Disk Access",      "com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",      "privacy permission fda",           "externaldrive.badge.person.crop" },
    { "Screen Recording",      "com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture", "privacy permission capture",       "rectangle.dashed.badge.record" },
    { "Input Monitoring",      "com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",   "privacy permission keylogger keys", "keyboard.badge.eye" },
    { "Camera Access",         "com.apple.settings.PrivacySecurity.extension?Privacy_Camera",        "privacy permission webcam",        "camera" },
    { "Microphone Access",     "com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",    "privacy permission mic",           "mic" },
    { "Automation Access",     "com.apple.settings.PrivacySecurity.extension?Privacy_Automation",    "privacy permission apple events osascript", "gearshape.2" },
}

local function row(p)
    return {
        id       = p[2],
        title    = p[1],
        subtitle = "System Settings",
        icon     = p[4] or "gearshape",
        -- The runner opens this natively on Enter and dismisses itself.
        url      = "x-apple.systempreferences:" .. p[2],
    }
end

function sysprefs_open(query)
    -- Drop the restored "ss " trigger, then match case-insensitively.
    local q = trim((trim(query or ""):gsub("^[Ss][Ss]", "", 1))):lower()

    local items, byKeyword = {}, {}
    for _, p in ipairs(PANES) do
        if q == "" or p[1]:lower():find(q, 1, true) then
            items[#items + 1] = row(p)
        elseif p[3]:find(q, 1, true) then
            -- Title misses are still useful ("dnd" → Focus), just ranked below.
            byKeyword[#byKeyword + 1] = row(p)
        end
    end
    for _, r in ipairs(byKeyword) do items[#items + 1] = r end

    if #items == 0 then return nil end

    return host.ui.render(host.ui.list{
        title = "System Settings",
        style = "rows",
        items = items,
    })
end
