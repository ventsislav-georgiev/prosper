-- currency — system extension.
--
-- Converts an amount between currencies using daily FX rates from the free,
-- key-less open.er-api.com endpoint. Mirrors the native CurrencyService.swift
-- engine (cross-rate via USD, cached once per UTC day). A good worked example of
-- the async host surface: host.http (with built-in retry/backoff), host.json,
-- host.prefs (persistent cache), and host.time (the sandbox has no `os`).
--
-- Handler contract: invoked as `currency_convert(query)` (command id
-- "currency.convert" with non-alphanumerics → '_'). Returns a TAB-delimited
-- "<formatted>\t<detail>" pair (the router splits it into the value/detail it
-- renders), or nil to decline (router falls back to native CurrencyService).
-- See docs/ADR-002-extensibility.md.
--
-- This command calls host.http, so it MUST run on the registry's off-main async
-- lane (ExtensionRegistry.invokeAsync) — never invokeSync.

local ENDPOINT = "https://open.er-api.com/v6/latest/USD"
local BASE = "USD"

-- Parse "<number> <CUR> <sep> <CUR>" (sep: to / in / -> / →), mirroring the
-- native parser. Returns amount, fromCode, toCode (uppercased) or nil.
local function parse(input)
    local t = input:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if #t == 0 then return nil end

    local lhs, rhs
    for _, sep in ipairs({ " to ", " in ", "->", " → " }) do
        local a, b = t:find(sep, 1, true)
        if a then
            lhs = t:sub(1, a - 1):gsub("^%s+", ""):gsub("%s+$", "")
            rhs = t:sub(b + 1):gsub("^%s+", ""):gsub("%s+$", "")
            break
        end
    end
    if rhs == nil then return nil end

    -- LHS: a leading number (',' and '_' are digit separators) plus a code.
    local num, code, seenDigit = {}, {}, false
    local i = 1
    while i <= #lhs do
        local c = lhs:sub(i, i)
        if c:match("%d") or c == "." then
            num[#num + 1] = c; seenDigit = true
        elseif c == "," or c == "_" then
            seenDigit = true
        elseif c:match("%s") then
            if seenDigit and #code > 0 then break end
        else
            if seenDigit then code[#code + 1] = c
            elseif c:match("%a") then code[#code + 1] = c end
        end
        i = i + 1
    end

    local amount = tonumber(table.concat(num))
    if amount == nil then return nil end
    local from = table.concat(code):upper()
    local to = rhs:upper()
    if not from:match("^%a%a%a$") or not to:match("^%a%a%a$") then return nil end
    return amount, from, to
end

-- Mirrors native Calc.format: integers "%.0f"; else "%.8f" with trailing zeros
-- (and a trailing dot) trimmed.
local function format(v)
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    if v == math.floor(v) and math.abs(v) < 1e15 then
        return string.format("%.0f", v)
    end
    local s = string.format("%.8f", v)
    s = s:gsub("0+$", ""):gsub("%.$", "")
    return s
end

-- Mixed-currency expressions ------------------------------------------------
--
-- "$30 CAD + 5 USD - 7EUR" → two or more money terms joined by +/-, result in
-- the LAST term's currency (Numi parity). Mirrors CurrencyService.swift's
-- parseExpression/evaluateExpression byte-for-byte in output.

-- Symbol → code when a term has no 3-letter code ("$30 + 5 EUR"). An explicit
-- code always wins over the symbol ("$30 CAD" → CAD).
local SYMBOL_CODES = { ["$"] = "USD", ["€"] = "EUR", ["£"] = "GBP", ["¥"] = "JPY", ["₹"] = "INR" }
-- Code → display symbol for formatting results ("€ 18.56").
local DISPLAY_SYMBOLS = { USD = "$", EUR = "€", GBP = "£", JPY = "¥", INR = "₹" }

-- Money formatting for expression results: two decimals, symbol when known.
local function format_money(v, code)
    local s = string.format("%.2f", v)
    local sym = DISPLAY_SYMBOLS[code]
    if sym then return sym .. " " .. s end
    return s .. " " .. code
end

-- UTF-8 aware scanner helpers: the symbols above are multi-byte, so iterate by
-- UTF-8 character, not by byte.
local function to_chars(s)
    local chars = {}
    for ch in s:gmatch(utf8 and utf8.charpattern or "[%z\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = ch
    end
    return chars
end

-- Parses the expression into { {sign, amount, code}, ... } or nil when the
-- input is not exactly a 2+-term mixed-currency expression.
local function parse_expression(input)
    local t = input:gsub("−", "-"):gsub("^%s+", ""):gsub("%s+$", "")
    local chars = to_chars(t)
    local i, n = 1, #chars
    local terms = {}
    local function skip_space()
        while i <= n and chars[i]:match("^%s$") do i = i + 1 end
    end

    while i <= n do
        local sign = 1.0
        if #terms > 0 then
            if chars[i] ~= "+" and chars[i] ~= "-" then return nil end
            if chars[i] == "-" then sign = -1.0 end
            i = i + 1
            skip_space()
        end
        -- Optional leading symbol ("$30").
        local symCode = nil
        if i <= n and SYMBOL_CODES[chars[i]] then
            symCode = SYMBOL_CODES[chars[i]]
            i = i + 1
            skip_space()
        end
        -- Number; ','/'_' are digit separators (same as calc).
        local num = {}
        while i <= n and (chars[i]:match("^[%d%.]$") or chars[i] == "," or chars[i] == "_") do
            if chars[i] ~= "," and chars[i] ~= "_" then num[#num + 1] = chars[i] end
            i = i + 1
        end
        local amount = tonumber(table.concat(num))
        if amount == nil then return nil end
        skip_space()
        -- Optional 3-letter code, attached or spaced ("7EUR", "5 USD").
        local code = {}
        while i <= n and chars[i]:match("^%a$") and #code < 4 do
            code[#code + 1] = chars[i]
            i = i + 1
        end
        local codeStr = table.concat(code)
        if #codeStr == 3 then
            -- explicit code wins over a symbol
        elseif #codeStr == 0 and symCode then
            codeStr = symCode
        else
            return nil
        end
        terms[#terms + 1] = { sign = sign, amount = amount, code = codeStr:upper() }
        skip_space()
    end
    if #terms < 2 then return nil end
    return terms
end

-- Evaluates parsed terms against the USD-based rate table; result in the LAST
-- term's currency. Returns "<formatted>\t<detail>" or nil.
local function evaluate_expression(terms, rates)
    local function rate(code)
        if code == BASE then return 1.0 end
        return rates[code]
    end
    local last = terms[#terms]
    local rTarget = rate(last.code)
    if rTarget == nil or rTarget <= 0 then return nil end
    local total = 0.0
    local parts = {}
    for idx, t in ipairs(terms) do
        local r = rate(t.code)
        if r == nil or r <= 0 then return nil end
        total = total + t.sign * (t.amount / r) * rTarget
        local amt = format(t.amount) .. " " .. t.code
        if idx == 1 then
            parts[#parts + 1] = (t.sign < 0) and ("-" .. amt) or amt
        else
            parts[#parts + 1] = ((t.sign < 0) and "-" or "+") .. " " .. amt
        end
    end
    local detail = table.concat(parts, " ") .. " → " .. last.code
    return format_money(total, last.code) .. "\t" .. detail
end

local function valid_rates(r)
    return type(r) == "table" and next(r) ~= nil
end

-- Today's USD-based rate table: in-prefs cache keyed by UTC day number; on miss,
-- fetch once (with retry) and persist. Degrades to a stale cache on fetch fail.
local function rates_for_today()
    local day = tostring(math.floor(host.time() / 86400))

    if host.prefs.get("ratesDay") == day then
        local cached = host.json.decode(host.prefs.get("rates") or "")
        if valid_rates(cached) then return cached end
    end

    local resp = host.http.get(ENDPOINT, { timeout = 8, retries = 2 })
    if resp and resp.ok and type(resp.json) == "table"
        and resp.json.result == "success" and valid_rates(resp.json.rates) then
        host.prefs.set("rates", host.json.encode(resp.json.rates))
        host.prefs.set("ratesDay", day)
        -- read by the runner card's "Updated N ago" subtitle
        host.prefs.set("fetchedAt", string.format("%d", math.floor(host.time())))
        return resp.json.rates
    end

    -- Fetch failed — fall back to any stale cache so the feature degrades.
    local stale = host.json.decode(host.prefs.get("rates") or "")
    if valid_rates(stale) then return stale end
    return nil
end

function currency_convert(query)
    if query == nil then return nil end

    -- Mixed-currency arithmetic first ("$30 CAD + 5 USD - 7EUR").
    local terms = parse_expression(query)
    if terms ~= nil then
        local r = rates_for_today()
        if r == nil then return nil end
        return evaluate_expression(terms, r)
    end

    local amount, from, to = parse(query)
    if amount == nil then return nil end

    local rates = rates_for_today()
    if rates == nil then return nil end

    -- Cross-rate via the USD base (rates[USD] is implicitly 1).
    local function rate(code)
        if code == BASE then return 1.0 end
        return rates[code]
    end
    local rFrom, rTo = rate(from), rate(to)
    if rFrom == nil or rTo == nil or rFrom <= 0 or rTo <= 0 then return nil end

    local result = (amount / rFrom) * rTo
    local crossRate = rTo / rFrom
    local f = format(result)
    if f == nil then return nil end

    local formatted = f .. " " .. to
    local detail = format(amount) .. " " .. from .. " → " .. to
        .. " (rate " .. string.format("%.4f", crossRate) .. ")"
    return formatted .. "\t" .. detail
end
