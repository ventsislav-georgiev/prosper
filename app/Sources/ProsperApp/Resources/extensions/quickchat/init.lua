-- quickchat — system extension.
--
-- ChatGPT-style: type a question or task, get a direct answer from the local
-- AI model (host.llm.chat), streamed inline. Uses the SAME on-device model as
-- inline autocomplete + translate — no separate download, no residency swap.
--
-- Handler contract: the host invokes the global whose name is the command id
-- with non-alphanumerics replaced by '_'. For "quickchat.run" that is
-- `quickchat_run(query)`. It returns a declarative component tree (host.ui)
-- rendered inline as native Neon cards. Returns nil to decline (empty input).
--
-- Streaming: host.llm.chat is staged — it returns the pipeline's current
-- milestone immediately (status "loading" / "generating" / "done" / "failed");
-- the host re-invokes this handler on each CoreBridge.chatProgress milestone,
-- so the answer grows in place.
--
-- Note: the runner restores the mode prefix before calling the handler, so we
-- strip a single leading "c "/"ask " prefix back off.

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function quickchat_run(query)
    if query == nil then return nil end
    -- Drop the restored mode prefix (primary "c ", or the "ask " alias).
    local text = trim((query:gsub("^[cC]%s+", ""):gsub("^[aA][sS][kK]%s+", "")))
    if text == "" then return nil end

    local result = host.llm.chat(text)
    if result == nil then return nil end

    local status = result.status or "done"
    local answer = result.text and trim(result.text) or ""
    local finished = status == "done" or status == "failed"

    -- Nothing generated yet: a single row naming the actual stage.
    if answer == "" then
        local label
        if status == "failed" then
            label = "No answer"
        elseif status == "loading" then
            label = "Loading model…"
        else
            label = "Thinking…"
        end
        return host.ui.render(host.ui.list{
            title = "Quick Chat",
            items = { {
                id = "0",
                title = label,
                icon = finished and "bubble.left.and.bubble.right" or "hourglass",
                loading = not finished,   -- host renders an inline spinner
            } },
        })
    end

    -- The answer card, plus a spinner row while more tokens are still coming.
    local items = { {
        id = "0",
        title = answer,
        icon = "bubble.left.and.bubble.right",
    } }
    if not finished then
        items[#items + 1] = {
            id = "progress",
            title = "…",
            icon = "hourglass",
            loading = true,
        }
    end
    return host.ui.render(host.ui.list{ title = "Quick Chat", items = items })
end
