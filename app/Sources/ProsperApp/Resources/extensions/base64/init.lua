-- base64 — system extension.
--
-- A command (NOT a runner mode): invoking `base64.open` LAUNCHES a standalone
-- split-pane window (host.window.open + host.ui.converter) with live two-way
-- conversion — left pane = plain text, right pane = Base64. Typing in either
-- pane updates the other through the `b64_encode` / `b64_decode` transform
-- globals the converter declares.
--
-- Handler contract: the host invokes the global whose name is the command id
-- with non-alphanumerics replaced by '_'. For "base64.open" that is
-- `base64_open(query)`. The window's converter then calls the named globals
-- `b64_encode` / `b64_decode` directly. See docs/ADR-002-extensibility.md.

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- char -> 6-bit value (reverse alphabet), built once.
local REV = {}
for i = 1, #ALPHABET do REV[ALPHABET:sub(i, i)] = i - 1 end

-- Encode a raw byte string to standard Base64 with '=' padding (no line breaks),
-- matching Foundation's `Data.base64EncodedString()`.
local function encode(s)
    local out, n, i = {}, #s, 1
    while i <= n do
        local b1 = s:byte(i)
        local b2 = s:byte(i + 1)
        local b3 = s:byte(i + 2)
        local n1 = b1 >> 2
        local n2 = ((b1 & 0x03) << 4) | ((b2 or 0) >> 4)
        local n3 = (((b2 or 0) & 0x0f) << 2) | ((b3 or 0) >> 6)
        local n4 = (b3 or 0) & 0x3f
        out[#out + 1] = ALPHABET:sub(n1 + 1, n1 + 1)
        out[#out + 1] = ALPHABET:sub(n2 + 1, n2 + 1)
        out[#out + 1] = b2 and ALPHABET:sub(n3 + 1, n3 + 1) or "="
        out[#out + 1] = b3 and ALPHABET:sub(n4 + 1, n4 + 1) or "="
        i = i + 3
    end
    return table.concat(out)
end

-- Strict Base64 decode. Returns the raw byte string, or nil if the input is not
-- well-formed Base64 (matching Foundation's `Data(base64Encoded:)` rejection of
-- bad length / illegal characters / misplaced padding).
local function decode(s)
    s = s:gsub("%s", "") -- Foundation ignores whitespace
    if #s == 0 then return "" end -- empty input decodes to empty (matches Foundation)
    if #s % 4 ~= 0 then return nil end
    local out, i = {}, 1
    while i <= #s do
        local c1, c2 = s:sub(i, i), s:sub(i + 1, i + 1)
        local c3, c4 = s:sub(i + 2, i + 2), s:sub(i + 3, i + 3)
        local v1, v2 = REV[c1], REV[c2]
        if v1 == nil or v2 == nil then return nil end
        local pad3, pad4 = (c3 == "="), (c4 == "=")
        -- Padding is only legal in the final quartet, and '=' in c3 forces '=' in c4.
        if (pad3 or pad4) and i + 4 <= #s then return nil end
        if pad3 and not pad4 then return nil end
        local v3 = pad3 and 0 or REV[c3]
        local v4 = pad4 and 0 or REV[c4]
        if v3 == nil or v4 == nil then return nil end
        out[#out + 1] = string.char((v1 << 2) | (v2 >> 4))
        if not pad3 then out[#out + 1] = string.char(((v2 & 0x0f) << 4) | (v3 >> 2)) end
        if not pad4 then out[#out + 1] = string.char(((v3 & 0x03) << 6) | v4) end
        i = i + 4
    end
    return table.concat(out)
end

-- Strip the first matching prefix (case-insensitive), preserving the original
-- (non-lowercased) body. Returns the body or nil.
local function strip(query, prefixes)
    local lower = query:lower()
    for _, p in ipairs(prefixes) do
        if lower:sub(1, #p) == p then
            return query:sub(#p + 1)
        end
    end
    return nil
end

-- Converter transform globals (called live by the window's converter control).

-- Plain text -> Base64. nil/empty -> "".
function b64_encode(text)
    return encode(text or "")
end

-- Base64 -> plain text. Invalid Base64 or non-UTF-8 decoded bytes -> "" (the
-- pane simply stays empty while the user is mid-typing), rather than a sentinel.
function b64_decode(text)
    local raw = decode(text or "")
    if raw == nil or utf8.len(raw) == nil then
        return ""
    end
    return raw
end

-- Command handler: open the Base64 window. An optional `base64 <text>` /
-- `b64 <text>` argument pre-fills the plain-text pane (and the Base64 pane is
-- derived from it); a bare verb opens an empty window. Side-effect only — the
-- host dismisses the runner and presents the window.
function base64_open(query)
    -- Strip whichever verb triggered us; the remainder (if any) seeds the input.
    local body = strip(query or "", { "base64 ", "b64 ", "unbase64 ", "base64d ", "b64d " })
        or ""

    host.window.open(host.ui.converter {
        title = "Base64",
        left = {
            label = "Plain Text",
            placeholder = "Type or paste text to encode…",
            value = body,
        },
        right = {
            label = "Base64",
            placeholder = "Paste Base64 to decode…",
            value = (body ~= "" and encode(body) or ""),
        },
        forward = "b64_encode",   -- left -> right
        backward = "b64_decode",  -- right -> left
        mono = true,
    })
end
