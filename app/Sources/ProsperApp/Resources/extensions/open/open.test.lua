-- Tests for the open extension. Run via scripts/test-extensions.sh.
-- open_run(query) strips the "o " prefix, searches apps, renders a launcher list.

local h = require("harness")

local function run(query, apps)
    local host, env = h.makeHost{ apps = apps or {} }
    local G = h.load(h.dir() .. "init.lua", host)
    local out = G.open_run(query)
    return out, env
end

-- ── Hits render launcher rows carrying the bundle path ───────────────────────
local out, env = run("o safari", { { name = "Safari", path = "/Applications/Safari.app" } })
h.eq(env.appQuery, "safari", "prefix stripped before search")
h.eq(out.kind, "list", "renders a list")
h.eq(out.style, "rows", "compact launcher rows")
h.eq(out.items[1].title, "Safari", "row title is the app name")
h.eq(out.items[1].launch, "/Applications/Safari.app", "Enter launches the bundle")
h.eq(out.items[1].image, "/Applications/Safari.app", "shows the real Finder icon")

-- ── No matches → a single explanatory row ────────────────────────────────────
out = run("o zzz", {})
h.eq(out.items[1].title, 'No app named "zzz"', "empty result row")

-- ── Empty query declines ─────────────────────────────────────────────────────
h.eq(run("o "), nil, "bare prefix declines")
h.eq(select(1, run("o ")), nil, "trailing-space prefix declines")
h.eq((run(nil)), nil, "nil declines")

print("ok open")
