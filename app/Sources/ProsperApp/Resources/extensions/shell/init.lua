-- shell — system extension.
--
-- Runs the typed text as a shell command through host.shell.run (a login shell,
-- so PATH additions from ~/.zprofile / brew shellenv are available) and renders
-- the captured output inline in the runner. Replaces the old native `.shell`
-- mode; the capability now lives here, on the same principles as translate.
--
-- Handler contract: the host invokes the global named after the command id with
-- non-alphanumerics replaced by '_'. For "shell.run" that is `shell_run(query)`.
-- The runner restores the command's primary prefix ("! ") before calling, so we
-- strip a single leading shell trigger (`!` / `>`, with optional space) back off.
-- Returns nil to decline (empty command). See docs/ADR-002-extensibility.md.

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function shell_run(query)
    if query == nil then return nil end
    -- Drop the restored mode trigger (`! ` / `> ` / `!`), then trim.
    local cmd = trim((query:gsub("^%s*[!>]+%s*", "")))
    if cmd == "" then return nil end

    local out = host.shell.run(cmd)
    if out == nil then out = "" end
    out = trim(out)

    -- style "rows" => one compact native-style result row (icon + "Shell" tag),
    -- matching the old native `.shell` output exactly rather than a reading card.
    return host.ui.render(host.ui.list{
        title = "Shell",
        style = "rows",
        items = {
            {
                id = "0",
                title = (out ~= "" and out) or "(no output)",
                subtitle = "$ " .. cmd,
                icon = "terminal",
            },
        },
    })
end
