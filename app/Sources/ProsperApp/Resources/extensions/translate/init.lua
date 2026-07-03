-- translate — system extension.
--
-- Translates the typed text into the user's configured target language using
-- the local AI model (host.llm.translate). The source/target languages are this
-- extension's own Options (Settings → Extensions → Translate), read via
-- host.prefs.get — no global app preference involved.
--
-- Handler contract: the host invokes the global whose name is the command id
-- with non-alphanumerics replaced by '_'. For command "translate.run" that is
-- `translate_run(query)`. It returns a declarative component tree (built with
-- host.ui) rendered INLINE in the runner as native Neon cards: a primary
-- translation card, any alternative renderings, and a detected-language header.
-- Returns nil to decline (empty input). See docs/ADR-002-extensibility.md.
--
-- Note: the runner restores the mode prefix before calling the handler (so verb
-- parsers see the same string as in the universal launcher). Translate has no
-- verbs, so we strip a single leading "l "/"t " prefix back off.

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function translate_run(query)
    if query == nil then return nil end
    -- Drop the restored mode prefix (always the command's primary "l ", but be
    -- lenient and also accept the "t " alias), then trim surrounding space.
    local text = trim((query:gsub("^[lLtT]%s+", "")))
    if text == "" then return nil end

    local target = host.prefs.get("target")
    if target == nil or trim(target) == "" then target = "Bulgarian" end

    local source = host.prefs.get("source")
    if source ~= nil then source = trim(source) end
    -- "Auto" / empty => let the model detect (pass nil).
    if source == nil or source == "" or source:lower() == "auto" then
        source = nil
    end

    -- Staged: translate returns the pipeline's current milestone immediately
    -- (status "loading" / "translating" / "enriching" / "done"); the host
    -- re-invokes this handler on each milestone, so partial results render as
    -- they arrive — primary first, alternatives when enrichment lands.
    local result = host.llm.translate(text, target, source)
    if result == nil then return nil end

    local status = result.status or "done"
    local primary = result.primary and trim(result.primary) or ""

    -- Nothing translated yet: a single row naming the actual stage. A finished
    -- pipeline with no usable output must still render a real row — returning
    -- nil here would surface the runner's generic "(done)" placeholder.
    if primary == "" then
        local label
        if status == "done" or status == "failed" then
            label = "No translation"
        elseif status == "loading" then
            label = "Loading model…"
        else
            label = "Translating…"
        end
        local finished = status == "done" or status == "failed"
        return host.ui.render(host.ui.list{
            title = "Translation",
            items = { {
                id = "0",
                title = label,
                icon = finished and "globe" or "hourglass",
                loading = not finished,   -- host renders an inline spinner
            } },
        })
    end

    -- Build the inline result: a list whose first item is the primary
    -- translation and the rest are alternative renderings (deduped). The
    -- detected source language, if any, becomes the header chip.
    local items = {}
    items[#items + 1] = {
        id = "0",
        title = primary,
        icon = "globe",
    }
    local seen = { [primary] = true }
    for _, cand in ipairs(result.candidates or {}) do
        local t = cand.text and trim(cand.text) or ""
        if t ~= "" and not seen[t] then
            seen[t] = true
            items[#items + 1] = {
                id = tostring(#items),
                title = t,
                subtitle = cand.note,      -- explanation, wrapped under the text
                accessory = cand.label,    -- register/sense chip (e.g. "informal")
                icon = "globe",
            }
        end
    end
    if status ~= "done" then
        items[#items + 1] = {
            id = "progress",
            title = "Finding alternatives…",
            icon = "hourglass",
            loading = true,   -- host renders an inline spinner
        }
    end

    local detected = result.detected
    return host.ui.render(host.ui.list{
        title = "Translation",
        subtitle = (detected and detected ~= "") and ("Detected: " .. detected) or nil,
        items = items,
    })
end
