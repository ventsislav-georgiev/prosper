-- Tests for the quicklinks extension. Run via scripts/test-extensions.sh.
-- quicklinks_run(query) sub-parses verbs (add/rm/list/help) and opens saved
-- links with {query}/{argument} substitution; ql_save persists the Add form.

local h = require("harness")

local function fresh()
    local opened
    local host, env = h.makeHost{ shellRouter = function(cmd) opened = cmd; return "" end }
    local G = h.load(h.dir() .. "init.lua", host)
    return G, env, function() return opened end
end

-- ── add / list / open round-trip ─────────────────────────────────────────────
local G, env, lastShell = fresh()
h.eq(G.quicklinks_run("ql add gh https://github.com/{query}"):find("Saved 'gh'") ~= nil, true, "add confirms")
h.eq(G.quicklinks_run("ql list"), "gh → https://github.com/{query}", "list shows saved link")

-- Opening substitutes the argument; '/' stays literal, spaces percent-encode.
local out = G.quicklinks_run("ql gh torvalds/linux")
h.eq(out, "Opening gh\thttps://github.com/torvalds/linux", "slash preserved in path-style target")
h.eq(lastShell(), "open 'https://github.com/torvalds/linux'", "shells `open` with the final url")

G.quicklinks_run("ql add s https://x.com/?q={query}")
G.quicklinks_run("ql s a b")
h.eq(lastShell(), "open 'https://x.com/?q=a%20b'", "spaces percent-encoded in query")

-- ── rm + unknown name ────────────────────────────────────────────────────────
h.eq(G.quicklinks_run("ql rm gh"), "Removed 'gh'", "rm confirms")
h.eq(G.quicklinks_run("ql gh x"):find("No quicklink 'gh'") ~= nil, true, "removed link is gone")

-- ── usage paths ──────────────────────────────────────────────────────────────
h.eq(G.quicklinks_run("ql"):find("ql <name>") ~= nil, true, "bare ql → usage")
h.eq(G.quicklinks_run("ql add only"):find("Usage: ql add") ~= nil, true, "add needs name+target")
h.eq(G.quicklinks_run("ql rm"):find("Usage: ql rm") ~= nil, true, "rm needs a name")

-- ── ql_save form: persists + closes, or re-renders with an error ─────────────
do
    local g, e = fresh()
    -- valid save
    g.ql_save(nil, e.host.json.encode{ name = "docs", target = "https://docs.example.com" })
    h.eq(e.windowClosed, 1, "valid save closes the window")
    h.eq(#e.notifications, 1, "valid save notifies")
    h.eq(g.quicklinks_run("ql list"), "docs → https://docs.example.com", "saved via form")

    -- invalid save re-renders the form with an error, no close
    local before = e.windowClosed
    local form = g.ql_save(nil, e.host.json.encode{ name = "", target = "" })
    h.eq(form.kind, "form", "invalid save re-renders the form")
    h.eq(form.title:find("name & link required") ~= nil, true, "error shown in title")
    h.eq(e.windowClosed, before, "invalid save does not close")
end

print("ok quicklinks")
