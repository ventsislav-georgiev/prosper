-- sysprefs tests — run via scripts/test-extensions.sh.
--
-- sysprefs_open(query) strips the restored "ss " trigger, substring-filters the
-- static pane table, and renders rows whose `url` is the pane's
-- x-apple.systempreferences: URL (what the runner opens on Enter).

local h = require("harness")
local INIT = h.dir() .. "init.lua"

local host, env = h.makeHost{}
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
local seen = {}
for _, it in ipairs(all.items) do
    h.eq(it.url:sub(1, 27), "x-apple.systempreferences:c", "row " .. it.title .. " carries a pane URL")
    h.eq(seen[it.id], nil, "duplicate pane id: " .. tostring(it.id))
    seen[it.id] = true
    h.eq(type(it.icon), "string", "row " .. it.title .. " has an icon")
end

-- ── Filtering ────────────────────────────────────────────────────────────────
h.eq(find(rows("ss displays"), "Displays").url,
     "x-apple.systempreferences:com.apple.Displays-Settings.extension",
     "Enter on Displays opens the Displays pane")

h.eq(find(rows("ss Full Disk"), "Full Disk Access").url,
     "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
     "permission sub-pane keeps its ?Anchor")

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
