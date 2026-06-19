-- Tests for the quickdirs extension. Run via scripts/test-extensions.sh.
-- quickdirs_run(query) handles the management verbs (add/rm/list/help) the host
-- delegates here; storage is a JSON ARRAY of objects in host.prefs `dirs`.

local h = require("harness")

local function fresh()
    local host, env = h.makeHost{}
    local G = h.load(h.dir() .. "init.lua", host)
    return G, env
end

-- ── add with a trailing prefix token, then list ──────────────────────────────
local G, env = fresh()
local msg = G.quickdirs_run("qd add work ~/work p")
h.eq(msg:find("Saved quickdir 'work'") ~= nil, true, "add confirms")
h.eq(msg:find("prefix 'p'") ~= nil, true, "prefix captured")

-- Stored as an array of objects (exercises the recursive JSON codec).
local dirs = env.host.json.decode(env.prefs.dirs)
h.eq(#dirs, 1, "one entry stored")
h.eq(dirs[1].name, "work", "name persisted")
h.eq(dirs[1].path, "~/work", "path persisted")
h.eq(dirs[1].prefix, "p", "prefix persisted")

-- add without a prefix
G.quickdirs_run("qd add proj ~/projects")
h.eq(#env.host.json.decode(env.prefs.dirs), 2, "second entry added")

h.eq(G.quickdirs_run("qd list"):find("work %[p%] → ~/work") ~= nil, true, "list shows entries")

-- ── re-add preserves a previously configured action ──────────────────────────
do
    local g, e = fresh()
    e.prefs.dirs = e.host.json.encode{
        { name = "work", path = "~/old", prefix = "", action = "code {path}", actionLabel = "VS Code" },
    }
    g.quickdirs_run("qd add work ~/new")  -- re-register, no action given
    local d = e.host.json.decode(e.prefs.dirs)
    h.eq(d[1].path, "~/new", "path updated on re-add")
    h.eq(d[1].action, "code {path}", "existing action preserved")
    h.eq(d[1].actionLabel, "VS Code", "existing action label preserved")
end

-- ── rm + unknown ─────────────────────────────────────────────────────────────
h.eq(G.quickdirs_run("qd rm work"), "Removed quickdir 'work'", "rm confirms")
h.eq(G.quickdirs_run("qd rm work"):find("No quickdir") ~= nil, true, "second rm misses")

-- ── usage paths ──────────────────────────────────────────────────────────────
h.eq(G.quickdirs_run("qd"):find("qd <name>") ~= nil, true, "bare qd → usage")
h.eq(G.quickdirs_run("qd add only"):find("Usage: qd add") ~= nil, true, "add needs name+path")
h.eq(G.quickdirs_run("qd nope"):find("No quickdir 'nope'") ~= nil, true, "unknown name")

-- ── qd_save form: persists action fields + closes ────────────────────────────
do
    local g, e = fresh()
    g.qd_save(nil, e.host.json.encode{ name = "dl", path = "~/Downloads",
        action = "open {path}", actionLabel = "Open" })
    h.eq(e.windowClosed, 1, "valid save closes the window")
    local d = e.host.json.decode(e.prefs.dirs)
    h.eq(d[1].action, "open {path}", "action saved from the form")

    local form = g.qd_save(nil, e.host.json.encode{ name = "", path = "" })
    h.eq(form.kind, "form", "invalid save re-renders the form")
    h.eq(e.windowClosed, 1, "invalid save does not close again")
end

print("ok quickdirs")
