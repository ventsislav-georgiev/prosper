-- agent — system extension (fix-it).
--
-- Sends the typed text to the local coding agent as a goal. The agent runs in the
-- repository configured in this extension's "Repository path" setting, in its own
-- window — so progress is visible and tool approvals can be answered. Mirrors the
-- shell extension's shape: a no-view runner command over a host capability, here
-- host.agent instead of host.shell.
--
-- Handler contract: the host invokes the global named after the command id with
-- non-alphanumerics replaced by '_'. For "agent.run" that is `agent_run(query)`.
-- The runner restores the command's primary prefix ("g ") before calling, so we
-- strip a single leading `g ` trigger back off. See docs/ADR-002-extensibility.md.

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function agent_run(query)
    if query == nil then return nil end
    -- Drop the restored mode trigger ("g "), then trim.
    local goal = trim((query:gsub("^%s*g%s+", "")))
    if goal == "" then return nil end

    local repo = host.prefs.get("repo")
    if repo == nil or repo == "" then repo = "~" end

    local res = host.agent.run(goal, { cwd = repo })

    local title, subtitle
    if res and res.runId then
        title = "Coding agent started"
        subtitle = "in " .. repo .. " — watch the agent window"
    else
        title = "Could not start agent"
        subtitle = (res and res.error) or "unknown error"
    end

    -- style "rows" => one compact native-style result row, matching the shell
    -- extension's output rather than a reading card.
    return host.ui.render(host.ui.list{
        title = "Coding Agent",
        style = "rows",
        items = {
            { id = "0", title = title, subtitle = subtitle, icon = "sparkles" },
        },
    })
end
