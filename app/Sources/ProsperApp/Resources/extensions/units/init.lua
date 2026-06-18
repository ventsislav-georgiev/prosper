-- units — system extension.
--
-- Deterministic unit conversion, mirroring the native UnitConvert.swift engine
-- (which is built on Foundation's `Measurement`/`Dimension`). Parses
-- "<n> <unit> to <unit>" (also "in", "->", "→"). Conversion only succeeds when
-- both units share a category. Pure and synchronous.
--
-- Handler contract: the host invokes the global whose name is the command id
-- with non-alphanumerics replaced by '_'. For "unit.convert" that is
-- `unit_convert(query)`. It returns a TAB-delimited triple
-- "<fromDisplay>\t<toDisplay>\t<formatted>" (the router splits it back into the
-- title/value it renders), or nil to decline (router falls back to native /
-- next command). See docs/ADR-002-extensibility.md.
--
-- Coefficients are Foundation's shipped (rounded) `UnitConverterLinear` values,
-- kept byte-identical so the golden parity test against the native engine holds.

-- Every handled category is linear (a fixed coefficient to the category base):
--   result = value * coeff_from / coeff_to
-- Temperature, the one affine case, is deliberately not handled here (see below).
local registry = {}

local function add(aliases, category, coeff, display)
    for _, a in ipairs(aliases) do
        registry[a] = { category = category, coeff = coeff, display = display }
    end
end

-- Length (base: meter)
add({ "mm", "millimeter", "millimetre" }, "length", 0.001, "mm")
add({ "cm", "centimeter", "centimetre" }, "length", 0.01, "cm")
add({ "m", "meter", "metre" }, "length", 1, "m")
add({ "km", "kilometer", "kilometre" }, "length", 1000, "km")
add({ "in", "inch", "\"" }, "length", 0.0254, "in")
add({ "ft", "foot", "feet" }, "length", 0.3048, "ft")
add({ "yd", "yard" }, "length", 0.9144, "yd")
add({ "mi", "mile" }, "length", 1609.344, "mi")
add({ "nmi", "nauticalmile" }, "length", 1852, "nmi")

-- Mass (base: kilogram)
add({ "mg", "milligram" }, "mass", 0.000001, "mg")
add({ "g", "gram", "gramme" }, "mass", 0.001, "g")
add({ "kg", "kilogram" }, "mass", 1, "kg")
add({ "t", "tonne", "metricton" }, "mass", 1000, "t")
add({ "oz", "ounce" }, "mass", 0.0283495, "oz")
add({ "lb", "pound" }, "mass", 0.453592, "lb")
add({ "st", "stone" }, "mass", 6.35029, "st")

-- Duration (base: second)
add({ "ns", "nanosecond" }, "duration", 1e-9, "ns")
add({ "us", "µs", "microsecond" }, "duration", 1e-6, "µs")
add({ "ms", "millisecond" }, "duration", 0.001, "ms")
add({ "s", "sec", "second" }, "duration", 1, "seconds")
add({ "min", "minute" }, "duration", 60, "minutes")
add({ "h", "hr", "hour" }, "duration", 3600, "hours")
add({ "day", "d" }, "duration", 86400, "days")
add({ "week", "wk" }, "duration", 604800, "weeks")
add({ "month", "mo" }, "duration", 2629800, "months")
add({ "year", "yr", "y" }, "duration", 31557600, "years")

-- Data (base: bit)
add({ "bit" }, "data", 1, "bit")
add({ "byte", "b" }, "data", 8, "B")
add({ "kb", "kilobyte" }, "data", 8000, "KB")
add({ "mb", "megabyte" }, "data", 8e6, "MB")
add({ "gb", "gigabyte" }, "data", 8e9, "GB")
add({ "tb", "terabyte" }, "data", 8e12, "TB")
add({ "kib" }, "data", 8192, "KiB")
add({ "mib" }, "data", 8388608, "MiB")
add({ "gib" }, "data", 8589934592, "GiB")

-- Temperature is intentionally NOT handled here: Foundation's affine
-- Fahrenheit conversion uses internal constants whose last-digit rounding the
-- Lua port cannot reproduce byte-for-byte (and the result formatting would
-- diverge by an epsilon / sign). Temperature units are absent from this
-- registry, so the handler declines them and the native UnitConvert engine
-- (Foundation Measurement) converts temperature instead.

-- Speed (base: m/s)
add({ "mps", "m/s" }, "speed", 1, "m/s")
add({ "kph", "kmh", "km/h" }, "speed", 0.277778, "km/h")
add({ "mph" }, "speed", 0.44704, "mph")
add({ "knot", "kn" }, "speed", 0.514444, "kn")

-- Area (base: m²)
add({ "sqm", "m2", "squaremeter" }, "area", 1, "m²")
add({ "sqkm", "km2" }, "area", 1000000, "km²")
add({ "sqft", "ft2" }, "area", 0.09290304, "ft²")
add({ "acre" }, "area", 4046.8564224, "acres")
add({ "hectare", "ha" }, "area", 10000, "ha")

-- Volume (base: liter)
add({ "ml", "milliliter", "millilitre" }, "volume", 0.001, "mL")
add({ "l", "liter", "litre" }, "volume", 1, "L")
add({ "gal", "gallon" }, "volume", 3.78541, "gal")
add({ "pt", "pint" }, "volume", 0.473176, "pt")
add({ "cup" }, "volume", 0.24, "cups")

-- Strip a trailing plural "s" so "minutes" matches "minute" (only when the
-- singular form actually exists, mirroring native normalizeUnit).
local function normalize(raw)
    local k = raw:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if #k > 2 and k:sub(-1) == "s" and registry[k:sub(1, #k - 1)] ~= nil then
        return k:sub(1, #k - 1)
    end
    return k
end

local function lookup(raw)
    return registry[normalize(raw)]
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

-- Parse "<number> <unit> <sep> <unit>". Returns value, fromRaw, toRaw or nil.
local function parse(input)
    local trimmed = input:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if #trimmed == 0 then return nil end

    local lhs, rhs
    for _, sep in ipairs({ " to ", " in ", "->", " → " }) do
        local a, b = trimmed:find(sep, 1, true)
        if a then
            lhs = trimmed:sub(1, a - 1):gsub("^%s+", ""):gsub("%s+$", "")
            rhs = trimmed:sub(b + 1):gsub("^%s+", ""):gsub("%s+$", "")
            break
        end
    end
    if rhs == nil or #rhs == 0 then return nil end

    -- Pull a leading number off the LHS (allowing , and _ as digit separators).
    local num, idx, n = {}, 1, #lhs
    while idx <= n do
        local c = lhs:sub(idx, idx)
        if c:match("[0-9%.%-%+]") then
            num[#num + 1] = c
            idx = idx + 1
        elseif (c == "," or c == "_") then
            idx = idx + 1 -- skip separator, do not append
        else
            break
        end
    end
    local value = tonumber(table.concat(num))
    if value == nil then return nil end
    local fromRaw = lhs:sub(idx):gsub("^%s+", ""):gsub("%s+$", "")
    if #fromRaw == 0 then return nil end
    return value, fromRaw, rhs
end

function unit_convert(query)
    if query == nil then return nil end
    local value, fromRaw, toRaw = parse(query)
    if value == nil then return nil end
    local from, to = lookup(fromRaw), lookup(toRaw)
    if from == nil or to == nil or from.category ~= to.category then return nil end

    local result = value * from.coeff / to.coeff
    local f = format(result)
    if f == nil then return nil end
    local formatted = f .. " " .. to.display
    return from.display .. "\t" .. to.display .. "\t" .. formatted
end
