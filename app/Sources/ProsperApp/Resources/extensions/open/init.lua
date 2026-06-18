-- open — system extension.
--
-- Searches the installed-application index (host.apps.search) and renders the
-- ranked matches as an inline launcher list. Each row carries the app bundle's
-- path in `launch`, so committing it (Enter / click) opens that app natively —
-- and `image` shows the app's real Finder icon. Replaces the old native
-- `.openApp` mode; the capability now lives here, on the same principles as
-- translate (see docs/ADR-002-extensibility.md).
--
-- Handler contract: the host invokes the global named after the command id with
-- non-alphanumerics replaced by '_'. For "open.run" that is `open_run(query)`.
-- The runner restores the "o " prefix before calling, so we strip it back off.

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function open_run(query)
    if query == nil then return nil end
    local q = trim((query:gsub("^[oO]%s+", "")))
    if q == "" then return nil end

    local apps = host.apps.search(q)
    if apps == nil or #apps == 0 then
        return host.ui.render(host.ui.list{
            title = "Open App",
            items = {
                {
                    id = "0",
                    title = "No app named \"" .. q .. "\"",
                    icon = "magnifyingglass",
                },
            },
        })
    end

    local items = {}
    for i, app in ipairs(apps) do
        items[#items + 1] = {
            id = tostring(i - 1),
            title = app.name,
            image = app.path,     -- show the app's real Finder icon
            launch = app.path,    -- Enter launches this app bundle natively
            icon = "square.grid.2x2",
        }
    end

    -- style "rows" => compact native-launcher rows (icon + "Application" tag),
    -- matching the old native `o ` results exactly rather than reading cards.
    return host.ui.render(host.ui.list{ title = "Open App", style = "rows", items = items })
end
