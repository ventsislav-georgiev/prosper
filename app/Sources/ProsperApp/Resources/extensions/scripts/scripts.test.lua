-- Tests for the scripts extension. Run via scripts/test-extensions.sh.
-- scripts_run(query) lists/filters saved scripts and runs one by exact name;
-- settings_action adds / edits / renames / removes records in the prefs array.

local h = require("harness")

local SCRIPTS = {
    { name = "deploy", command = "make deploy", description = "Ship it", icon = "shippingbox" },
    { name = "de",     command = "echo short" },
    { name = "logs",   command = "tail -n 20 /var/log/app.log" },
}

local function setup(opts)
    opts = opts or {}
    local host, env = h.makeHost{ shellOut = opts.shellOut or "" }
    if opts.scripts ~= false then
        host.prefs.set("scripts", host.json.encode(opts.scripts or SCRIPTS))
    end
    local G = h.load(h.dir() .. "init.lua", host)
    return G, env, host
end

-- ── Listing: empty query lists all saved scripts ─────────────────────────────
local G, env = setup()
local out = G.scripts_run("sc")
h.eq(out.kind, "list", "empty query renders a list")
h.eq(out.style, "rows", "compact rows")
h.eq(#out.items, 3, "all three scripts listed")
h.eq(out.items[1].title, "deploy", "name is the row title")
h.eq(out.items[1].subtitle, "Ship it", "description preferred as subtitle")
h.eq(out.items[1].icon, "shippingbox", "custom icon kept")
h.eq(out.items[2].subtitle, "$ echo short", "no description falls back to the command")
h.eq(out.items[2].icon, "terminal", "default icon")
h.eq(env.calls.shell, 0, "listing never shells")

-- ── Filtering by name ────────────────────────────────────────────────────────
out = G.scripts_run("sc log")
h.eq(#out.items, 1, "filters by substring")
h.eq(out.items[1].title, "logs", "filtered to logs")
h.eq(G.scripts_run("sc zzz"), "No script matching 'zzz'", "no match message")

-- ── Exact name runs the command and renders its output ───────────────────────
G, env = setup{ shellOut = "deployed\n" }
out = G.scripts_run("sc deploy")
h.eq(env.calls.shell, 1, "shells exactly once")
h.eq(out.items[1].title, "deployed", "captured output, trimmed")
h.eq(out.items[1].subtitle, "$ make deploy", "command echoed")
h.eq(out.title, "deploy", "titled with the script name")

-- Empty output gets the placeholder (same as the shell extension).
G, env = setup{ shellOut = "" }
h.eq(G.scripts_run("sc logs").items[1].title, "(no output)", "empty output placeholder")

-- ── Shadow guard: "de" does not fire while typing toward "deploy" ────────────
G, env = setup()
out = G.scripts_run("sc de")
h.eq(env.calls.shell, 0, "shadowed exact match does not run")
h.eq(out.kind, "list", "shows the matches instead")
h.eq(#out.items, 2, "both 'deploy' and 'de' listed")
-- …but `sc run de` forces it.
out = G.scripts_run("sc run de")
h.eq(env.calls.shell, 1, "explicit run escapes the guard")
h.eq(out.items[1].subtitle, "$ echo short", "ran the shadowed script")
h.eq(G.scripts_run("sc run nope"):find("No script 'nope'") ~= nil, true, "unknown name reports")
h.eq(G.scripts_run("sc run"), "Usage: sc run <name>", "run needs a name")

-- ── Verbs / no store ─────────────────────────────────────────────────────────
h.eq(G.scripts_run("sc help"):find("sc run <name>") ~= nil, true, "help shows usage")
h.eq(G.scripts_run("sc list").kind, "list", "explicit list verb")
h.eq(G.scripts_run(nil), nil, "nil declines")
local empty = setup{ scripts = false }
h.eq(empty.scripts_run("sc"):find("No scripts yet") ~= nil, true, "empty store hint")
-- A malformed entry is skipped rather than breaking the list.
local bad = setup{ scripts = { { name = "ok", command = "true" }, { name = "no-cmd" }, { command = "orphan" } } }
h.eq(#bad.scripts_run("sc").items, 1, "malformed entries skipped")

-- ── Settings: render + add / edit / rename / delete round-trip ───────────────
local host
G, env, host = setup()
local node = G.settings_render("scripts", "{}")
h.eq(node.kind, "settings.ui", "renders settings ui")
local recs = node.sections[1].rows[1]
h.eq(recs.kind, "settings.records", "records control")
h.eq(#recs.records, 3, "one record per script")
h.eq(recs.records[1].fields[2].value, "make deploy", "command pre-filled")

-- Add
G.settings_action("scripts", "record.save:scripts:", nil, host.json.encode{
    name = "brew", command = "brew upgrade", description = "Update formulae", icon = "cube" })
local stored = host.json.decode(env.prefs.scripts)
h.eq(#stored, 4, "new record appended")
h.eq(stored[4].name, "brew", "name stored")
h.eq(stored[4].command, "brew upgrade", "command stored")
h.eq(G.scripts_run("sc brew").items[1].subtitle, "$ brew upgrade", "runner sees it immediately")

-- Rename (deploy → ship): the old key is gone, the new one carries the edit.
G.settings_action("scripts", "record.save:scripts:deploy", nil, host.json.encode{
    name = "ship", command = "make ship" })
stored = host.json.decode(env.prefs.scripts)
h.eq(#stored, 4, "rename does not duplicate")
h.eq(stored[1].name, "ship", "renamed in place")
h.eq(stored[1].command, "make ship", "command updated")

-- Delete
G.settings_action("scripts", "record.delete:scripts:logs", nil, "{}")
stored = host.json.decode(env.prefs.scripts)
h.eq(#stored, 3, "record removed")
for _, s in ipairs(stored) do h.eq(s.name ~= "logs", true, "logs gone") end

-- A save with a missing name/command is ignored (no half record).
local before = env.prefs.scripts
G.settings_action("scripts", "record.save:scripts:", nil, host.json.encode{ name = "x" })
h.eq(env.prefs.scripts, before, "incomplete record not saved")

-- Deleting the last one pins the empty JSON array (not "{}").
local one = h.makeHost{}
one.prefs.set("scripts", one.json.encode{ { name = "solo", command = "true" } })
local G2 = h.load(h.dir() .. "init.lua", one)
G2.settings_action("scripts", "record.delete:scripts:solo", nil, "{}")
h.eq(one.prefs.get("scripts"), "[]", "empty store stays an array")

print("ok scripts")
