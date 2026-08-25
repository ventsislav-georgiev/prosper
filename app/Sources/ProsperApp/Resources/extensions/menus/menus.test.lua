-- Tests for the menus extension. Run via scripts/test-extensions.sh.
-- menus_run(query) strips the "menu " verb, filters host.menus.list() and
-- renders rows whose only action is the reserved `menus.press` id.

local h = require("harness")

-- A small stand-in menu bar: three items under File (whose *path*, not title,
-- carries "file"), one deep Format item, and one item whose *title* carries
-- "file" — the pair that pins the title-beats-path ranking.
local BAR = {
    { id = "3:0", path = { "File" },   title = "New Window",        shortcut = "\u{2318}N" },
    { id = "3:1", path = { "File" },   title = "Export as PDF\u{2026}", shortcut = nil },
    { id = "3:2", path = { "Format", "Font" }, title = "Bold",      shortcut = "\u{2318}B" },
    { id = "3:3", path = { "File", "Share" },  title = "Mail",      shortcut = nil },
    { id = "3:4", path = { "View" },   title = "Show File Info",    shortcut = "\u{2318}I" },
}

local function run(query, opts)
    opts = opts or {}
    opts.menus = opts.menus or BAR
    local host, env = h.makeHost(opts)
    local G = h.load(h.dir() .. "init.lua", host)
    return G.menus_run(query), env
end

-- ── Row shape: breadcrumb subtitle, shortcut chip, reserved press action ──────
local out, env = run("menu new window")
h.eq(out.kind, "list", "renders a list")
h.eq(out.style, "rows", "compact launcher rows, like the native menu hits")
h.eq(#out.items, 1, "one hit")
local row = out.items[1]
h.eq(row.title, "New Window", "row title is the menu item title")
h.eq(row.subtitle, "File", "subtitle is the breadcrumb above the item")
h.eq(row.accessory, "\u{2318}N", "shortcut rides the trailing accessory chip")
h.eq(row.icon, "filemenu.and.selection", "menu glyph")
-- The press itself is native: the runner intercepts this reserved id, restores
-- the previous app, then performs the AX press. The extension only carries the id.
h.eq(#row.actions, 1, "exactly one action")
h.eq(row.actions[1].id, "menus.press", "reserved native action id")
h.eq(row.actions[1].value, "3:0", "value is the host row id (generation:index)")
h.eq(env.calls.menusList, 1, "one host bridge hop per keystroke")

-- A shortcut-less item leaves the chip empty rather than inventing one.
out = run("menu export")
h.eq(out.items[1].title, "Export as PDF\u{2026}", "matches on a title token")
h.eq(out.items[1].accessory, nil, "no shortcut => no chip")

-- ── Verb stripping: locked prefix, match route, bare verb ────────────────────
h.eq(run("menu bold").items[1].title, "Bold", '"menu " prefix stripped')
h.eq(run("m bold").items[1].title, "Bold", '"m " match route stripped')
h.eq(#run("menu").items, #BAR, "bare verb lists the whole menu bar")
h.eq(#run("menu ").items, #BAR, "trailing-space verb lists the whole menu bar")
h.eq(#run("m").items, #BAR, "bare m lists the whole menu bar")
h.eq(run(nil), nil, "nil declines")

-- ── Matching: order-independent tokens, path hits, deep breadcrumbs ──────────
h.eq(run("menu pdf export").items[1].title, "Export as PDF\u{2026}",
     "tokens match in any order")
h.eq(run("menu format bold").items[1].subtitle, "Format \u{203A} Font",
     "path tokens match, breadcrumb joined with \u{203A}")
h.eq(run("menu font").items[1].title, "Bold", "a path-only token still finds the item")

-- Title hits rank above path-only hits: "file" titles one item and paths three,
-- and the titled one must lead even though it sits last in menu order.
out = run("menu file")
h.eq(#out.items, 4, "one title hit + three items under File")
h.eq(out.items[1].title, "Show File Info", "title-tier hit leads the path-tier ones")
h.eq(out.items[2].title, "New Window", "path-tier keeps menu order behind it")

-- ── Empty states ─────────────────────────────────────────────────────────────
out = run("menu zzz")
h.eq(out.items[1].title, 'No menu command matching "zzz"', "explanatory miss row")
h.eq(out.items[1].actions, nil, "a miss row presses nothing")

out, env = run("menu ", { menus = {} })
h.eq(out.items[1].title, "No menu commands", "no walk => explanatory row")
h.eq(out.items[1].subtitle,
     "Focus an app first, or grant Accessibility in Settings \u{203A} Extensions",
     "names both causes: no frontmost app, or no Accessibility grant")
h.eq(out.items[1].actions, nil, "nothing to press")

-- ── Big menu bars are capped, not dumped ─────────────────────────────────────
local big = {}
for i = 1, 400 do
    big[i] = { id = "7:" .. (i - 1), path = { "View" }, title = "Item " .. i }
end
out = run("menu ", { menus = big })
h.eq(#out.items, 50, "400-item menu bar renders at most 50 rows")
h.eq(out.items[1].title, "Item 1", "menu order preserved")
h.eq(out.items[1].actions[1].value, "7:0", "capped rows still carry their real id")
h.eq(#run("menu item", { menus = big }).items, 50, "a broad query is capped too")

print("ok menus")
