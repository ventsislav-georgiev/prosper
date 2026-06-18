-- calc — system extension.
--
-- Deterministic arithmetic, mirroring the native Calc.swift evaluator:
--   * operators: + - * / % ^  (and unicode × ÷)
--   * digit separators _ and , between digits (1_000, 1,000)
--   * unary minus/plus, right-associative ^
--   * division / modulo by zero  -> nil (not a result)
--   * a bare number (no binary operator) -> nil  (so "42" is not "calc")
--
-- Handler contract: the host invokes the global whose name is the command id
-- with non-alphanumerics replaced by '_'. For command "calc.eval" that is
-- `calc_eval(query)`. Returns the formatted result string, or nil to decline
-- (the router then falls back to the native implementation / next command).
-- See docs/ADR-002-extensibility.md.

local PREC = { ["+"] = 1, ["-"] = 1, ["*"] = 2, ["/"] = 2, ["%"] = 2, ["^"] = 4 }
local RIGHT = { ["^"] = true }
local UNARY_PREC = 3

local function tokenize(s)
    s = s:gsub("×", "*"):gsub("÷", "/")
    local tokens = {}
    local i, n = 1, #s
    local prev = nil -- previous token type, for unary detection
    while i <= n do
        local c = s:sub(i, i)
        if c == " " or c == "\t" then
            i = i + 1
        elseif c:match("[0-9.]") then
            local digits, j = {}, i
            while j <= n do
                local d = s:sub(j, j)
                if d:match("[0-9.]") then
                    digits[#digits + 1] = d
                    j = j + 1
                elseif (d == "_" or d == ",")
                    and s:sub(j + 1, j + 1):match("[0-9]")
                    and s:sub(j - 1, j - 1):match("[0-9]") then
                    j = j + 1 -- skip a separator that sits between two digits
                else
                    break
                end
            end
            local v = tonumber(table.concat(digits))
            if v == nil then return nil end
            tokens[#tokens + 1] = { t = "num", v = v }
            prev, i = "num", j
        elseif c == "(" then
            tokens[#tokens + 1] = { t = "lp" }; prev, i = "lp", i + 1
        elseif c == ")" then
            tokens[#tokens + 1] = { t = "rp" }; prev, i = "rp", i + 1
        elseif c:match("[%+%-%*/%%%^]") then
            local unary = (c == "-" or c == "+")
                and (prev == nil or prev == "op" or prev == "uop" or prev == "lp")
            tokens[#tokens + 1] = { t = unary and "uop" or "op", v = c }
            prev, i = unary and "uop" or "op", i + 1
        else
            return nil -- any other character: not an arithmetic expression
        end
    end
    return tokens
end

-- Shunting-yard to RPN. Returns rpn, hasBinaryOp (or nil on imbalance).
local function to_rpn(tokens)
    local out, ops, hasBinary = {}, {}, false
    local function top() return ops[#ops] end
    for _, tk in ipairs(tokens) do
        if tk.t == "num" then
            out[#out + 1] = tk
        elseif tk.t == "uop" then
            ops[#ops + 1] = tk
        elseif tk.t == "op" then
            hasBinary = true
            while top() and (top().t == "op" or top().t == "uop") do
                local o = top()
                local op = o.t == "uop" and UNARY_PREC or PREC[o.v]
                local cur = PREC[tk.v]
                if op > cur or (op == cur and not RIGHT[tk.v]) then
                    out[#out + 1] = o; ops[#ops] = nil
                else
                    break
                end
            end
            ops[#ops + 1] = tk
        elseif tk.t == "lp" then
            ops[#ops + 1] = tk
        elseif tk.t == "rp" then
            while top() and top().t ~= "lp" do
                out[#out + 1] = top(); ops[#ops] = nil
            end
            if not top() then return nil end -- unbalanced ')'
            ops[#ops] = nil                  -- pop '('
        end
    end
    while top() do
        if top().t == "lp" then return nil end -- unbalanced '('
        out[#out + 1] = top(); ops[#ops] = nil
    end
    return out, hasBinary
end

local function eval_rpn(rpn)
    local st = {}
    for _, tk in ipairs(rpn) do
        if tk.t == "num" then
            st[#st + 1] = tk.v
        elseif tk.t == "uop" then
            local a = st[#st]; if a == nil then return nil end
            st[#st] = (tk.v == "-") and -a or a
        else
            local b = st[#st]; st[#st] = nil
            local a = st[#st]; st[#st] = nil
            if a == nil or b == nil then return nil end
            local r
            if tk.v == "+" then r = a + b
            elseif tk.v == "-" then r = a - b
            elseif tk.v == "*" then r = a * b
            elseif tk.v == "/" then if b == 0 then return nil end; r = a / b
            elseif tk.v == "%" then if b == 0 then return nil end; r = a % b
            elseif tk.v == "^" then r = a ^ b
            else return nil end
            st[#st + 1] = r
        end
    end
    if #st ~= 1 then return nil end
    return st[1]
end

-- Mirrors native Calc.format (Calc.swift): integers as "%.0f"; otherwise
-- "%.8f" with trailing zeros (and a trailing dot) trimmed. Kept byte-identical
-- so the golden parity test holds for repeating decimals (e.g. 1/3).
local function format(v)
    if v ~= v or v == math.huge or v == -math.huge then return nil end -- nan/inf
    if v == math.floor(v) and math.abs(v) < 1e15 then
        return string.format("%.0f", v)
    end
    local s = string.format("%.8f", v)
    s = s:gsub("0+$", "")
    s = s:gsub("%.$", "")
    return s
end

-- Percentage shorthands (Raycast calculator parity). These are NOT expressible
-- in the arithmetic grammar above (they use the words "of"/"off" or a trailing
-- "%"), so they are matched up front and computed directly:
--   N% of M      -> N/100 * M        ("52% of 900" = 468, "3% of $123" = 3.69)
--   N% off M     -> M - N/100 * M    ("20% off 50"  = 40)
--   M + N%       -> M + N/100 * M    ("120 + 10%"   = 132)
--   M - N%       -> M - N/100 * M    ("120 - 10%"   = 108)
-- A leading "what is" / "what's" is stripped. The native Calc fallback does not
-- implement these, so they require the calc extension to be enabled.
local NUMC = "(%$?[%-%+]?%d[%d_,]*%.?%d*)"
local function tonum(s)
    if not s then return nil end
    return tonumber((s:gsub("[%$_,]", "")))
end

local function percent_eval(query)
    local q = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
    q = q:gsub("^what'?s%s+", ""):gsub("^what%s+is%s+", "")

    local a, b = q:match("^" .. NUMC .. "%%%s+of%s+" .. NUMC .. "$")
    if a and b then
        local x, y = tonum(a), tonum(b)
        if x and y then return x / 100 * y end
    end

    a, b = q:match("^" .. NUMC .. "%%%s+off%s+" .. NUMC .. "$")
    if a and b then
        local x, y = tonum(a), tonum(b)
        if x and y then return y - x / 100 * y end
    end

    local m, op, p = q:match("^" .. NUMC .. "%s*([%+%-])%s*" .. NUMC .. "%%$")
    if m and op and p then
        local mm, pp = tonum(m), tonum(p)
        if mm and pp then
            local delta = mm / 100 * pp
            return (op == "+") and (mm + delta) or (mm - delta)
        end
    end
    return nil
end

function calc_eval(query)
    if query == nil then return nil end
    local pct = percent_eval(query)
    if pct ~= nil then return format(pct) end
    local tokens = tokenize(query)
    if tokens == nil or #tokens == 0 then return nil end
    local rpn, hasBinary = to_rpn(tokens)
    if rpn == nil or not hasBinary then return nil end -- require a binary operator
    local v = eval_rpn(rpn)
    if v == nil then return nil end
    return format(v)
end
