-- sysprefs tests — run via scripts/test-extensions.sh.
--
-- sysprefs_open(query) strips the restored "ss " trigger, substring-filters the
-- static pane table, and renders rows whose `url` is the pane's
-- x-apple.systempreferences: URL (what the runner opens on Enter).

local h = require("harness")
local INIT = h.dir() .. "init.lua"

local PW_APP = "/System/Applications/Passwords.app"
local host, env = h.makeHost{ fsExists = { [PW_APP] = true } }
local G = h.load(INIT, host)

local function rows(query)
    G.sysprefs_open(query)
    return env.rendered
end

local function find(list, title)
    for _, it in ipairs(list.items) do
        if it.title == title then return it end
    end
    return nil
end

-- ── list_on_empty: a bare `ss ` browses every pane ───────────────────────────
local all = rows("ss ")
h.eq(all.kind, "list", "renders a list")
h.eq(all.style, "rows", "compact launcher rows")
h.eq(#all.items >= 30, true, "bare query lists the whole pane table (got " .. #all.items .. ")")
h.eq(find(all, "Wi-Fi") ~= nil, true, "Wi-Fi present")

-- Every row is openable and uniquely identified.
-- QA #145: the app-row exemption is keyed on a literal id; a typo there must
-- fail by name, not as a nil index on the exempted row's missing url.
local seen, exempted = {}, 0
for _, it in ipairs(all.items) do
    if it.id == "com.apple.Passwords-Settings.extension" then
        exempted = exempted + 1
        h.eq(it.launch, "/System/Applications/Passwords.app", "Passwords row launches the app")
    else
        h.eq(tostring(it.url):sub(1, 27), "x-apple.systempreferences:c", "row " .. it.title .. " carries a pane URL")
        h.eq(it.launch, nil, "pane row " .. it.title .. " has no launch target")
    end
    h.eq(seen[it.id], nil, "duplicate pane id: " .. tostring(it.id))
    seen[it.id] = true
    h.eq(type(it.icon), "string", "row " .. it.title .. " has an icon")
end
h.eq(exempted, 1, "the app-row exemption id names exactly one row")

-- ── Filtering ────────────────────────────────────────────────────────────────
h.eq(find(rows("ss displays"), "Displays").url,
     "x-apple.systempreferences:com.apple.Displays-Settings.extension",
     "Enter on Displays opens the Displays pane")

h.eq(find(rows("ss Full Disk"), "Full Disk Access").url,
     "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
     "permission sub-pane keeps its ?Anchor")

-- macOS 27: Screen Saver lives in the Wallpaper pane; Passwords is its own app.
local saver = find(rows("ss screen saver"), "Screen Saver")
h.eq(saver.url, "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension",
     "Screen Saver opens the Wallpaper pane")
h.eq(find(rows("ss idle"), "Screen Saver") ~= nil, true, "Screen Saver keeps its 'idle' keyword")

local pw = find(rows("ss passwords"), "Passwords")
h.eq(pw.launch, "/System/Applications/Passwords.app", "Passwords launches Passwords.app")
h.eq(pw.image, "/System/Applications/Passwords.app", "Passwords row shows the app icon")
h.eq(pw.url, nil, "Passwords row is not a URL row (runner would tag it Bookmark)")
h.eq(pw.subtitle, "App", "Passwords row is labelled as an app")
h.eq(find(rows("ss keychain"), "Passwords") ~= nil, true, "Passwords keeps its 'keychain' keyword")

h.eq(#rows("ss displays").items, 1, "specific title match is not diluted")
h.eq(find(rows("SS DISPLAYS"), "Displays") ~= nil, true, "filter is case-insensitive")

-- Bare `ss` (no trailing space) behaves like the empty query, not a search
-- for the literal "ss".
h.eq(#rows("ss").items, #all.items, "bare `ss` lists everything")

-- Keyword-only hits are found, and ranked below title hits.
local dnd = rows("ss dnd")
h.eq(dnd.items[1].title, "Focus", "keyword 'dnd' finds Focus")

local wifi = rows("ss wireless")
h.eq(wifi.items[1].title, "Wi-Fi", "keyword 'wireless' finds Wi-Fi")

local sound = rows("ss sound")   -- title hit (Sound) + keyword hit (Sharing: "screen sharing")
h.eq(sound.items[1].title, "Sound", "title match outranks keyword match")

-- No match declines, so the runner can fall through instead of showing a lie.
h.eq(G.sysprefs_open("ss zzzznope"), nil, "no match returns nil")

-- A nil query must not throw; it reads as empty and lists everything.
h.eq(#G.sysprefs_open(nil).items, #all.items, "nil query is tolerated")

-- ── QA #145: an app missing on this macOS keeps the pane row ─────────────────
-- Passwords.app is macOS 15+. Without it the row must not point at a dead path
-- (generic file icon, Enter opens nothing): it opens the Settings pane and shows
-- its own SF Symbol.
do
    local oldHost = host
    local host2, env2 = h.makeHost{}          -- fsExists = {}: no Passwords.app
    local checks = 0
    local exists = host2.fs.exists
    host2.fs.exists = function(p) checks = checks + 1; return exists(p) end
    local G2 = h.load(INIT, host2)
    G2.sysprefs_open("ss passwords")
    local old = find(env2.rendered, "Passwords")
    h.eq(old.url, "x-apple.systempreferences:com.apple.Passwords-Settings.extension",
         "missing Passwords.app: the row opens the Passwords pane")
    h.eq(old.launch, nil, "missing Passwords.app: no launch of a dead path")
    h.eq(old.image, nil, "missing Passwords.app: no Finder icon of a dead path")
    h.eq(old.icon, "key", "missing Passwords.app: the row keeps its SF Symbol")
    h.eq(old.subtitle, "System Settings", "missing Passwords.app: labelled as a pane")
    G2.sysprefs_open("ss ")
    G2.sysprefs_open("ss pass")
    h.eq(checks, 1, "the app path is checked once per VM, not per keystroke")
    G = h.load(INIT, oldHost)                 -- back to the macOS 15+ host for the rest
end

-- ── Cost: the filter runs on every keystroke ─────────────────────────────────
-- Pure Lua over a static table: no prefs, no shell, no HTTP. Any host-bridge hop
-- added here would be paid per character typed.
h.resetCalls(env)
rows("ss disp")
h.eq(env.calls.prefsGet, 0, "filter reads no prefs")
h.eq(env.calls.shell, 0, "filter shells out zero times")
h.eq(env.calls.http, 0, "filter makes no network calls")

local us = h.bench(2000, function() G.sysprefs_open("ss disp") end) * 1e6
h.le(us, 1500, string.format("filter under 1.5ms/keystroke (was %.1f us)", us))

print("ok sysprefs")
