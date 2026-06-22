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

-- Only Chrome enabled; everything else off so nothing else shells out.
local function chrome_only_prefs(host)
    for _, k in ipairs({ "brave", "edge", "vivaldi", "opera", "arc",
                         "firefox", "zen", "safari" }) do
        host.prefs.set("source." .. k, "false")
    end
end

local function fresh()
    local host, env = h.makeHost{
        shellRouter = router,
        fsDirs = { [CHROME] = { "Default" } },   -- one Chrome profile
    }
    chrome_only_prefs(host)
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

print("ok bookmarks")
