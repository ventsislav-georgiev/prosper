-- menus — system extension.
--
-- Lists the frontmost app's menu-bar commands and presses the chosen one, so
-- "menu export pdf" reaches Safari › File › Export as PDF… without touching the
-- mouse. The AX walk itself is native and cached (host.menus.list reads the
-- in-process index the palette already warms), so this file is pure filtering +
-- row shaping — no Accessibility calls of its own.
--
-- Enter runs the row's only action, the reserved `menus.press` id: the runner
-- intercepts it natively, re-activates the app the palette stole focus from and
-- then performs the AX press. `value` carries the row id from host.menus.list;
-- it embeds the cache generation, so a stale id presses nothing rather than the
-- wrong item.
--
-- Handler contract: the host invokes the global named after the command id with
-- non-alphanumerics replaced by '_' — for "menus.run" that is `menus_run(query)`
-- — and restores the "menu " prefix first, so we strip the verb back off.

-- The menu bar of a big app (VS Code, Xcode) walks to ~400 items. Rendering all
-- of them on a bare `menu ` is unreadable and pointless; the query narrows it.
local MAX_ROWS = 50

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Strips the verb the runner restored: "menu ", "m ", or a bare "menu"/"m".
local function strip_verb(query)
    local q = trim(query)
    local rest = q:match("^[mM][eE][nN][uU]%s+(.*)$") or q:match("^[mM]%s+(.*)$")
    if rest then return trim(rest) end
    if q:lower() == "menu" or q:lower() == "m" then return "" end
    return q
end

local function breadcrumb(cmd)
    return table.concat(cmd.path or {}, " \u{203A} ")
end

-- Every whitespace-separated token must appear in the haystack, in any order, so
-- "export pdf" finds "Export as PDF…" and "file export" finds it via the path.
local function matches(hay, tokens)
    for _, t in ipairs(tokens) do
        if not hay:find(t, 1, true) then return false end
    end
    return true
end

local function empty_row(title, subtitle)
    return { id = "0", title = title, subtitle = subtitle, icon = "magnifyingglass" }
end

local function render(items)
    -- style "rows" => compact launcher rows (icon + breadcrumb + shortcut chip),
    -- matching the native menu hits in the universal launcher.
    return host.ui.render(host.ui.list{ title = "Menu Commands", style = "rows", items = items })
end

function menus_run(query)
    if query == nil then return nil end
    local q = strip_verb(query)

    local cmds = host.menus.list()
    if cmds == nil or #cmds == 0 then
        -- Either nothing was frontmost when the palette opened, or Accessibility
        -- is not granted — the AX walk fails silently in that case, so name both.
        return render{ empty_row("No menu commands",
                                 "Focus an app first, or grant Accessibility in Settings \u{203A} Extensions") }
    end

    local tokens = {}
    for t in q:lower():gmatch("%S+") do tokens[#tokens + 1] = t end

    -- Two tiers so a title hit ("Bold") outranks a path-only hit ("Format ›
    -- Font › …"); menu order is preserved inside each tier, which is the order
    -- the user sees in the real menu bar.
    local titled, pathed = {}, {}
    for _, cmd in ipairs(cmds) do
        if #tokens == 0 then
            titled[#titled + 1] = cmd
        elseif matches(cmd.title:lower(), tokens) then
            titled[#titled + 1] = cmd
        elseif matches((breadcrumb(cmd) .. " " .. cmd.title):lower(), tokens) then
            pathed[#pathed + 1] = cmd
        end
        if #titled >= MAX_ROWS then break end
    end

    local items = {}
    local function add(cmd)
        if #items >= MAX_ROWS then return end
        items[#items + 1] = {
            id = tostring(#items),
            title = cmd.title,
            subtitle = breadcrumb(cmd),
            accessory = cmd.shortcut,      -- trailing shortcut chip (e.g. "⇧⌘E")
            icon = "filemenu.and.selection",
            actions = {
                {
                    id = "menus.press",    -- reserved; the runner presses natively
                    title = "Press",
                    icon = "cursorarrow.click",
                    value = cmd.id,
                },
            },
        }
    end
    for _, cmd in ipairs(titled) do add(cmd) end
    for _, cmd in ipairs(pathed) do add(cmd) end

    if #items == 0 then
        return render{ empty_row("No menu command matching \"" .. q .. "\"") }
    end
    return render(items)
end
