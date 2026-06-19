-- Hot-path performance + cost budgets for the per-keystroke command handlers.
-- Run via scripts/test-extensions.sh (stock `lua`, no app build).
--
-- Two kinds of budget, in priority order:
--   1. HOST-BRIDGE CALL COUNTS (env.calls.*) — deterministic, machine-independent.
--      Every real call is a Lua→Swift hop (often a UserDefaults/network syscall),
--      so a keystroke handler that must stay cheap has a hard ceiling here. These
--      are the actual hot-path *requirements*; they never flake.
--   2. WALL-CLOCK CEILINGS (h.bench + h.le) — coarse, loose. A backstop that trips
--      only on order-of-magnitude (algorithmic) regressions. Ceilings are set well
--      above observed cost so slow CI machines don't flake. NOTE: timings include
--      the harness's *Lua* JSON codec, which is slower than the native host's, so
--      they are stub-relative, not production absolutes.

local h = require("harness")
local E = h.dir()                     -- this file's dir = the extensions/ root

-- Per-call wall-clock ceilings (seconds, amortized). Loose on purpose.
local PURE_BUDGET   = 3e-4             -- pure parsers (no bridge, no codec); ~15µs observed
local CACHED_BUDGET = 6e-4            -- currency cache-hit (decodes rates each call)
local INLINE_BUDGET = 6e-4            -- bookmarks inline search over the warm cache

-- ── calc: pure arithmetic, zero host bridge ──────────────────────────────────
do
    local host, env = h.makeHost{}
    local G = h.load(E .. "calc/init.lua", host)
    h.eq(G.calc_eval("2 + 3 * 4 - 1"), "13", "sanity: calc still computes")

    h.resetCalls(env)
    G.calc_eval("2 + 3 * 4 - 1")
    h.eq(env.calls.prefsGet, 0, "calc touches no prefs")
    h.eq(env.calls.shell, 0, "calc shells out nothing")
    h.eq(env.calls.http, 0, "calc makes no network call")

    local per = h.bench(2000, function() G.calc_eval("12 + 34 * (5 - 6) / 7 + 89 % 3") end)
    h.le(per, PURE_BUDGET, "calc_eval per-call within hot-path budget")
end

-- ── units: pure conversion, zero host bridge ─────────────────────────────────
do
    local host, env = h.makeHost{}
    local G = h.load(E .. "units/init.lua", host)
    h.eq(G.unit_convert("1 km to m"), "km\tm\t1000 m", "sanity: units still converts")

    h.resetCalls(env)
    G.unit_convert("1 km to m")
    h.eq(env.calls.prefsGet, 0, "units touches no prefs")
    h.eq(env.calls.shell + env.calls.http, 0, "units makes no bridge call")

    local per = h.bench(2000, function() G.unit_convert("42 miles to km") end)
    h.le(per, PURE_BUDGET, "unit_convert per-call within hot-path budget")
end

-- ── base64: pure codec, zero host bridge ─────────────────────────────────────
do
    local host, env = h.makeHost{}
    local G = h.load(E .. "base64/init.lua", host)
    h.eq(G.b64_encode("hello"), "aGVsbG8=", "sanity: base64 still encodes")

    h.resetCalls(env)
    G.b64_encode("hello")
    G.b64_decode("aGVsbG8=")
    h.eq(env.calls.prefsGet + env.calls.shell + env.calls.http, 0, "base64 makes no bridge call")

    local per = h.bench(2000, function() G.b64_encode("the quick brown fox jumps over") end)
    h.le(per, PURE_BUDGET, "b64_encode per-call within hot-path budget")
end

-- ── currency: warm-cache hit must NOT hit the network ────────────────────────
do
    local RATES = { status = 200,
        body = h.encode{ result = "success", rates = { EUR = 0.9, GBP = 0.8 } } }
    local host, env = h.makeHost{ httpResponse = RATES }
    local G = h.load(E .. "currency/init.lua", host)

    -- First call warms the per-day cache (one fetch allowed).
    h.eq(G.currency_convert("100 USD to EUR"):match("^(.-)\t"), "90 EUR", "sanity: currency converts")
    h.eq(env.calls.http, 1, "cold path fetches exactly once")

    -- Every subsequent same-day call is the hot path: zero network, zero writes.
    h.resetCalls(env)
    G.currency_convert("50 GBP to EUR")
    h.eq(env.calls.http, 0, "HOT PATH: cached day never refetches")
    h.eq(env.calls.prefsSet, 0, "HOT PATH: cached day never writes prefs")
    h.eq(env.calls.shell, 0, "currency shells out nothing")

    local per = h.bench(1000, function() G.currency_convert("100 USD to EUR") end)
    h.le(per, CACHED_BUDGET, "currency cached convert within hot-path budget")
end

-- ── bookmarks inline: warm cache, no re-import on each keystroke ──────────────
do
    local HOME = "/Users/test"
    local CHROME = HOME .. "/Library/Application Support/Google/Chrome"
    local JSON = [[{ "roots": { "bookmark_bar": { "type":"folder","name":"Bar","children":[
        { "type":"url","name":"GitHub","url":"https://github.com" },
        { "type":"url","name":"MDN","url":"https://developer.mozilla.org" } ]},
        "other":{"type":"folder","name":"O","children":[]},
        "synced":{"type":"folder","name":"S","children":[]} } }]]
    local function router(cmd)
        if cmd:find("printf", 1, true) then return HOME end
        if cmd:find("Default/Bookmarks", 1, true) then return JSON end
        return ""
    end
    local host, env = h.makeHost{ shellRouter = router, fsDirs = { [CHROME] = { "Default" } } }
    for _, k in ipairs({ "brave","edge","vivaldi","opera","arc","firefox","zen","safari" }) do
        host.prefs.set("source." .. k, "false")
    end
    local G = h.load(E .. "bookmarks/init.lua", host)
    G.bookmarks_run("bm import")              -- populate + cache (shells out here)
    host.prefs.set("show_in_launcher", "true")

    h.resetCalls(env)
    local node = G.bookmarks_inline("github")
    h.eq(node.kind, "list", "sanity: inline returns a list")
    h.eq(env.calls.shell, 0, "HOT PATH: inline search never re-imports (no shell)")
    h.eq(env.calls.prefsSet, 0, "HOT PATH: inline search never writes the cache")

    local per = h.bench(1000, function() G.bookmarks_inline("git") end)
    h.le(per, INLINE_BUDGET, "bookmarks_inline per-call within hot-path budget")
end

print("ok perf")
