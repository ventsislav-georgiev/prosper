-- Tests for the currency extension. Run via scripts/test-extensions.sh.
-- currency_convert(query) -> "<formatted>\t<detail>", or nil. Rates come from
-- host.http (USD-based table), cached per UTC day in host.prefs.

local h = require("harness")

-- The stub now models the real host wrapper, so fixtures are the WIRE shape
-- ({ status, body = <json string> }); the stub derives ok + json itself.
local function wire(rates)
    return { status = 200,
             body = h.encode{ result = "success", rates = rates } }
end
local RATES = wire{ EUR = 0.9, GBP = 0.8, CAD = 1.35, JPY = 150 }
local FAIL  = { status = 500 }   -- ok=false, no body → json nil

local function host_with_rates(resp)
    return h.makeHost{ httpResponse = resp or RATES }
end

-- ── Single conversion via the USD cross-rate ─────────────────────────────────
do
    local host, env = host_with_rates()
    local G = h.load(h.dir() .. "init.lua", host)
    local out = G.currency_convert("100 USD to EUR")
    local formatted, detail = out:match("^(.-)\t(.+)$")
    h.eq(formatted, "90 EUR", "100 USD → 90 EUR at 0.9")
    h.eq(detail, "100 USD → EUR (rate 0.9000)", "detail shows the cross-rate")

    -- Second call same UTC day hits the prefs cache (no second fetch).
    env.httpArgs = nil
    G.currency_convert("10 GBP to USD")
    h.eq(env.httpArgs, nil, "rates cached per day — no refetch")
end

-- ── Mixed-currency expression: result in the LAST term's currency (Numi) ─────
do
    local host = host_with_rates()
    local G = h.load(h.dir() .. "init.lua", host)
    local out = G.currency_convert("$30 CAD + 5 USD - 7 EUR")
    local formatted, detail = out:match("^(.-)\t(.+)$")
    -- 30 CAD = 20 EUR-eq, +5 USD = 4.5, -7 EUR → 17.50 in EUR.
    h.eq(formatted, "€ 17.50", "expression result in EUR with symbol")
    h.eq(detail, "30 CAD + 5 USD - 7 EUR → EUR", "detail echoes the terms")
end

-- ── Explicit code wins over a leading symbol ─────────────────────────────────
do
    local host, env = host_with_rates()
    local G = h.load(h.dir() .. "init.lua", host)
    -- "$30 CAD" must be treated as CAD, not USD.
    G.currency_convert("$30 CAD + 1 CAD")  -- both CAD → 31 CAD
    -- (asserted indirectly above; here just ensure it parses & fetches once)
    h.eq(env.httpArgs ~= nil, true, "expression triggered a rate fetch")
end

-- ── Declines ─────────────────────────────────────────────────────────────────
do
    local host = host_with_rates()
    local G = h.load(h.dir() .. "init.lua", host)
    h.eq(G.currency_convert("hello world"), nil, "non-currency declines")
    h.eq(G.currency_convert("100"), nil, "bare number declines")
    h.eq(G.currency_convert(nil), nil, "nil declines")
end

-- ── Fetch failure with no cache → decline (no result) ────────────────────────
do
    local host = host_with_rates(FAIL)
    local G = h.load(h.dir() .. "init.lua", host)
    h.eq(G.currency_convert("100 USD to EUR"), nil, "no rates → decline")
end

-- ── Fetch fails but a stale cache exists → degrade to it (no decline) ─────────
do
    local host, env = host_with_rates({ ok = false })
    -- Seed a cache from a *different* UTC day so the cache-hit branch is skipped
    -- and the fetch-failure stale fallback is what answers.
    env.prefs.ratesDay = "-1"
    env.prefs.rates = env.host.json.encode{ EUR = 0.9 }
    local G = h.load(h.dir() .. "init.lua", host)
    local out = G.currency_convert("100 USD to EUR")
    h.eq(out and out:match("^(.-)\t"), "90 EUR", "fetch fail degrades to stale cache")
end

-- ── Garbage target rate (0 or negative) → decline, never a 0/negative result ──
do
    local host = host_with_rates(wire{ EUR = 0, GBP = -1 })
    local G = h.load(h.dir() .. "init.lua", host)
    h.eq(G.currency_convert("100 USD to EUR"), nil, "zero target rate declines")
    h.eq(G.currency_convert("100 USD to GBP"), nil, "negative target rate declines")
end

print("ok currency")
