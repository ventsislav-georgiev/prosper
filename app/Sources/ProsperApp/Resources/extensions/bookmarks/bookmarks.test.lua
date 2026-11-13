-- Tests for the bookmarks extension. Run via scripts/test-extensions.sh.
-- bookmarks_run(query) imports from browsers (host.shell + host.fs), caches the
-- flattened result in host.prefs, and searches it. We drive only the Chrome
-- (Chromium JSON) source — the others are disabled so the import is hermetic.

local h = require("harness")

local HOME = "/Users/test"
local CHROME = HOME .. "/Library/Application Support/Google/Chrome"

local CHROMIUM_JSON = [[{
  "roots": {
    "bookmark_bar": { "type": "folder", "name": "Bar", "children": [
      { "type": "url", "name": "GitHub", "url": "https://github.com" },
      { "type": "folder", "name": "Dev", "children": [
        { "type": "url", "name": "MDN", "url": "https://developer.mozilla.org" }
      ]}
    ]},
    "other":  { "type": "folder", "name": "Other", "children": [] },
    "synced": { "type": "folder", "name": "Synced", "children": [] }
  }
}]]

local function router(cmd)
    if cmd:find("printf", 1, true) then return HOME end
    if cmd:find("Default/Bookmarks", 1, true) then return CHROMIUM_JSON end
    return ""   -- every other source's file read comes back empty
end

-- One source enabled (Chrome unless `only` names another); everything else off so
-- nothing else shells out.
local function only_prefs(host, only)
    for _, k in ipairs({ "chrome", "brave", "edge", "vivaldi", "opera", "arc",
                         "firefox", "zen", "safari" }) do
        if k ~= only then host.prefs.set("source." .. k, "false") end
    end
end

-- The shared harness has no host.log; record it per host into env.logs.
-- opts: { only = source name, fsDirs = ..., perms = ... } (default: Chrome, one profile).
local function fresh(r, opts)
    opts = opts or {}
    local host, env = h.makeHost{
        shellRouter = r or router,
        fsDirs = opts.fsDirs or { [CHROME] = { "Default" } },   -- one Chrome profile
        perms = opts.perms,
    }
    env.logs = {}
    local function rec(m) env.logs[#env.logs + 1] = m end
    host.log = { info = rec, warn = rec, error = rec }
    only_prefs(host, opts.only or "chrome")
    local G = h.load(h.dir() .. "init.lua", host)
    return G, env
end

-- ── import walks the Chromium tree (nested folders included) ──────────────────
local G, env = fresh()
local summary = G.bookmarks_run("bm import")
h.eq(summary, "Imported 2 bookmarks (Chrome 2).", "import counts every bookmark, recursing folders")

-- cache persisted as a JSON array of {title,url,browser,folder}
local cache = env.host.json.decode(env.prefs.cache)
h.eq(#cache, 2, "two bookmarks cached")

h.eq(#env.logs, 0, "a good read logs nothing")

-- ── search matches the folded title/url/folder haystack ──────────────────────
local out = G.bookmarks_run("bm github")
h.eq(out.kind, "list", "search renders a list")
h.eq(out.items[1].title, "GitHub", "matched the bookmark")
h.eq(out.items[1].url, "https://github.com", "row carries the url for native open")

-- nested folder folded into the haystack → searchable by folder name
h.eq(#G.bookmarks_run("bm Dev").items, 1, "folder name is searchable")

-- ── browsers + no-match + help ───────────────────────────────────────────────
h.eq(G.bookmarks_run("bm browsers"), "Chrome — 2 bookmarks", "per-browser counts")
h.eq(G.bookmarks_run("bm zzzz").items[1].title:find("No bookmarks match") ~= nil, true, "no-match row")
h.eq(G.bookmarks_run("bm help"), "bm <query> · bm import · bm browsers · bm help", "help is usage")

-- ── max_results clamps a bad / oversized pref ────────────────────────────────
do
    local g, e = fresh()
    g.bookmarks_run("bm import")
    e.prefs.max_results = "9999"        -- over the 500 hard cap
    -- 2 bookmarks < cap, so just assert it still returns (no crash) and is bounded
    h.eq(#g.bookmarks_run("bm").items, 2, "returns all when under the cap")
    e.prefs.max_results = "abc"         -- non-numeric → default
    h.eq(#g.bookmarks_run("bm").items, 2, "bad pref falls back to default")
end

-- ── inline launcher fallback is opt-in and silent on miss ────────────────────
do
    local g, e = fresh()
    g.bookmarks_run("bm import")
    h.eq(g.bookmarks_inline("github"), "", "off by default → declines with empty string")
    e.prefs.show_in_launcher = "true"
    h.eq(g.bookmarks_inline("g"), "", "single char → declines")
    local node = g.bookmarks_inline("github")
    h.eq(node.kind, "list", "enabled + match → renders a compact list")
    h.eq(#node.items, 1, "only the matching bookmark")
end

-- ── bookmarks_search: raw JSON rows for the unified launcher (opt-in) ─────────
do
    local g, e = fresh()
    g.bookmarks_run("bm import")
    h.eq(g.bookmarks_search("github", "200"), "", "off by default → empty")
    e.prefs.show_in_launcher = "true"
    h.eq(g.bookmarks_search("g", "200"), "", "single char → empty")
    h.eq(g.bookmarks_search("zzzz", "200"), "", "no match → empty")

    local rows = e.host.json.decode(g.bookmarks_search("github", "200"))
    h.eq(#rows, 1, "one matching row")
    h.eq(rows[1].title, "GitHub", "title present")
    h.eq(rows[1].url, "https://github.com", "url present for native open")
    h.eq(rows[1].hay ~= nil and #rows[1].hay > 0, true, "precomputed hay present for Swift scorer")
    h.eq(rows[1].hay:find("github", 1, true) ~= nil, true, "hay is lowercased + matchable")

    -- limit arg caps the row count
    local capped = e.host.json.decode(g.bookmarks_search("https", "1"))
    h.eq(#capped <= 1, true, "limit arg caps rows")
end

-- ── #211: a file that is there but unreadable is logged; a missing one is not ──
-- host.shell.run merges stderr and drops the exit status, so a failed read prints
-- the marker and the shell's reason for re-opening the path (`: <`).
local FAIL = "__prosper_read_failed__\n"
local BM = CHROME .. "/Default/Bookmarks"
local function failing(reason)
    local sent = {}
    return function(cmd)
        if cmd:find("printf", 1, true) then return HOME end
        sent[#sent + 1] = cmd
        if cmd:find("Default/Bookmarks", 1, true) then return FAIL .. "zsh:1: " .. reason .. ": " .. BM end
        return ""
    end, sent
end
do  -- a macOS privacy / XProtect denial (EPERM)
    local r, sent = failing("operation not permitted")
    local g, e = fresh(r)
    h.eq(g.bookmarks_run("bm import"), "No bookmarks found.", "the returned list is as before: empty")
    h.eq(#e.host.json.decode(e.prefs.cache), 0, "nothing cached")
    h.eq(#e.logs, 1, "the denial is logged once")
    h.eq(e.logs[#e.logs], "bookmarks: Chrome read failed (permission denied)", "names the browser and the kind")
    h.eq((e.logs[#e.logs] or ""):find(HOME, 1, true), nil, "never the path")
    local cmd = sent[#sent] or ""
    h.eq(cmd:find("|| { echo; echo __prosper_read_failed__; : < '" .. BM .. "'; }", 1, true) ~= nil, true,
         "the failure branch re-opens the same path")
    h.eq(cmd:find("^setopt pipefail; ") ~= nil, true, "a pipeline's first stage counts")
end
do  -- EACCES reads the same as a denial
    local r = failing("permission denied")
    local g, e = fresh(r)
    g.bookmarks_run("bm import")
    h.eq(e.logs[#e.logs], "bookmarks: Chrome read failed (permission denied)", "EACCES is a denial too")
end
do  -- the file is there and opens, but the reader rejected it
    local g, e = fresh(function(cmd)
        if cmd:find("printf", 1, true) then return HOME end
        if cmd:find("Default/Bookmarks", 1, true) then return "{partial" .. "\n" .. FAIL end
        return ""
    end)
    h.eq(g.bookmarks_run("bm import"), "No bookmarks found.", "partial output before a failure is dropped")
    h.eq(#e.logs, 1, "logged once")
    h.eq(e.logs[#e.logs], "bookmarks: Chrome read failed (unreadable)", "not called a denial")
end
do  -- a browser profile without the file (or not installed at all): silent, as before
    local r = failing("no such file or directory")
    local g, e = fresh(r)
    h.eq(g.bookmarks_run("bm import"), "No bookmarks found.", "missing file: no bookmarks")
    h.eq(#e.logs, 0, "a missing file logs nothing")
end

-- ── #211 r2: every other call site re-opens its own path and names its browser ──
local SUPPORT = HOME .. "/Library/Application Support"
local function denied_at(needle, path)
    local sent = {}
    return function(cmd)
        if cmd:find("printf", 1, true) then return HOME end
        sent[#sent + 1] = cmd
        if cmd:find(needle, 1, true) then
            return FAIL .. "zsh:1: operation not permitted: " .. path
        end
        return ""
    end, sent
end
local function reopens(sent, path)
    local cmd = sent[#sent] or ""
    return cmd:find("|| { echo; echo __prosper_read_failed__; : < '" .. path .. "'; }", 1, true) ~= nil
end
for _, c in ipairs({
    { only = "firefox", label = "Firefox", root = SUPPORT .. "/Firefox/Profiles" },
    { only = "zen",     label = "Zen",     root = SUPPORT .. "/zen/Profiles" },
}) do
    -- the plain places.sqlite path is re-opened, not the file: URI sqlite3 gets
    local db = c.root .. "/p1.default/places.sqlite"
    local r, sent = denied_at("places.sqlite", db)
    local g, e = fresh(r, { only = c.only, fsDirs = { [c.root] = { "p1.default" } } })
    h.eq(g.bookmarks_run("bm import"), "No bookmarks found.", c.label .. ": nothing imported")
    h.eq(#e.logs, 1, c.label .. ": logged once")
    h.eq(e.logs[#e.logs], "bookmarks: " .. c.label .. " read failed (permission denied)", c.label .. " label")
    h.eq(reopens(sent, db), true, c.label .. ": re-opens the plain places.sqlite path")
end
do  -- Safari (Full Disk Access granted, so the read is attempted)
    local plist = HOME .. "/Library/Safari/Bookmarks.plist"
    local r, sent = denied_at("Bookmarks.plist", plist)
    local g, e = fresh(r, { only = "safari", fsDirs = {}, perms = { ["full-disk-access"] = true } })
    h.eq(g.bookmarks_run("bm import"), "No bookmarks found.", "Safari: nothing imported")
    h.eq(#e.logs, 1, "Safari: logged once")
    h.eq(e.logs[#e.logs], "bookmarks: Safari read failed (permission denied)", "Safari label")
    h.eq(reopens(sent, plist), true, "Safari: re-opens the plist path")
end
do  -- Arc
    local arc = SUPPORT .. "/Arc/StorableSidebar.json"
    local r, sent = denied_at("StorableSidebar.json", arc)
    local g, e = fresh(r, { only = "arc", fsDirs = {} })
    h.eq(g.bookmarks_run("bm import"), "No bookmarks found.", "Arc: nothing imported")
    h.eq(#e.logs, 1, "Arc: logged once")
    h.eq(e.logs[#e.logs], "bookmarks: Arc read failed (permission denied)", "Arc label")
    h.eq(reopens(sent, arc), true, "Arc: re-opens StorableSidebar.json")
end

-- ── #211 r2: the marker counts only alone on its own line ────────────────────
-- Every reader prints JSON, and a JSON string cannot hold a raw newline, so
-- content can never put the marker on a line by itself.
do
    local MARK = "__prosper_read_failed__"
    local json = [[{"roots":{"bookmark_bar":{"type":"folder","name":"Bar","children":[
      {"type":"url","name":"]] .. MARK .. [[","url":"https://example.com/a"},
      {"type":"url","name":"Plain","url":"https://example.com/]] .. MARK .. [["}
    ]}}}]]
    local g, e = fresh(function(cmd)
        if cmd:find("printf", 1, true) then return HOME end
        if cmd:find("Default/Bookmarks", 1, true) then return json end
        return ""
    end)
    h.eq(g.bookmarks_run("bm import"), "Imported 2 bookmarks (Chrome 2).", "marker inside a title and a url imports")
    h.eq(#e.logs, 0, "marker inside content logs nothing")
end
do  -- the marker as the whole output (nothing printed before the failure)
    local g, e = fresh(function(cmd)
        if cmd:find("printf", 1, true) then return HOME end
        if cmd:find("Default/Bookmarks", 1, true) then return "__prosper_read_failed__" end
        return ""
    end)
    h.eq(g.bookmarks_run("bm import"), "No bookmarks found.", "bare marker: nothing imported")
    h.eq(e.logs[#e.logs], "bookmarks: Chrome read failed (unreadable)", "bare marker is a failure")
end

-- ── #1085: a profile dir that cannot be listed is logged; a missing one is not ─
-- host.fs.list_dirs gives {} either way, so an empty listing asks `ls` why.
local function listing(root, answer)
    local sent = {}
    return function(cmd)
        if cmd:find("printf", 1, true) then return HOME end
        sent[#sent + 1] = cmd
        if cmd == "ls '" .. root .. "' 2>&1 >/dev/null" then return answer end
        return ""
    end, sent
end
for _, c in ipairs({
    { only = "chrome",  label = "Chrome",  root = CHROME },
    { only = "firefox", label = "Firefox", root = SUPPORT .. "/Firefox/Profiles" },
}) do
    local r, sent = listing(c.root, "ls: " .. c.root .. ": Operation not permitted")
    local g, e = fresh(r, { only = c.only, fsDirs = {} })
    h.eq(g.bookmarks_run("bm import"), "No bookmarks found.", c.label .. " unlistable: nothing imported")
    h.eq(#e.logs, 1, c.label .. " unlistable: logged once")
    h.eq(e.logs[#e.logs], "bookmarks: " .. c.label .. " profile list failed (permission denied)",
         c.label .. " unlistable: names the browser and the kind")
    h.eq((e.logs[#e.logs] or ""):find(HOME, 1, true), nil, c.label .. " unlistable: never the path")
    h.eq(sent[#sent], "ls '" .. c.root .. "' 2>&1 >/dev/null", c.label .. ": ls stderr only, same path")
end
do  -- not installed (ENOENT), or there and empty (ls says nothing): silent
    for _, answer in ipairs({ "ls: " .. CHROME .. ": No such file or directory", "" }) do
        local g, e = fresh(listing(CHROME, answer), { fsDirs = {} })
        h.eq(g.bookmarks_run("bm import"), "No bookmarks found.", "no profiles: nothing imported")
        h.eq(#e.logs, 0, "no profiles logs nothing: '" .. answer .. "'")
    end
end
do  -- a listing that worked never shells out to ls
    local r, sent = listing(CHROME, "ls: x: Operation not permitted")
    local g, e = fresh(r)
    g.bookmarks_run("bm import")
    for _, cmd in ipairs(sent) do h.eq(cmd:find("^ls ") , nil, "no ls probe after a good listing") end
    h.eq(#e.logs, 0, "a good listing logs nothing")
end

print("ok bookmarks")
