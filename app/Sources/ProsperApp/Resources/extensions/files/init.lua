-- files — system extension.
--
-- Spotlight-backed file finder (the Alfred/Raycast "find a file and act on it"
-- flow). This Lua layer is a thin shell: it parses the typed query into a
-- structured request, calls host.files.search, and maps the ranked hits into an
-- inline launcher list. Every heavyweight, OS-integrated piece — the Spotlight
-- query + ranking (host.files.search) and the file actions (host.files.act /
-- the runner) — lives in native code. See docs/ADR-002-extensibility.md.
--
-- Each row declares the built-in file actions it offers (reserved `file.*` ids);
-- the runner renders them as Open (⏎), Reveal (⌘⏎), the ⌘K actions panel, and
-- Quick Look (⌘Y). The runner restores the "f " prefix before calling, so we
-- strip it back off.
--
-- Filter tokens in the query: `kind:pdf` `ext:png` `in:~/Documents` `content:1`.

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Parse the query into { name, kinds, exts, scope, content }. Recognised tokens
-- are `key:value`; everything else accumulates into the name.
local function parse(q)
    local kinds, exts, names = {}, {}, {}
    local scope, content = nil, false
    for token in q:gmatch("%S+") do
        local key, val = token:match("^(%a+):(.+)$")
        if key == "kind" then
            kinds[#kinds + 1] = val:lower()
        elseif key == "ext" then
            exts[#exts + 1] = (val:gsub("^%.", "")):lower()
        elseif key == "in" then
            scope = val
        elseif key == "content" then
            content = true
        else
            names[#names + 1] = token
        end
    end
    return {
        name = table.concat(names, " "),
        kinds = kinds,
        exts = exts,
        scope = scope,
        content = content,
    }
end

-- #1106: extensions of the Markdown and plain-text files the text viewer opens
-- (a subset of TextViewerRouting.isDocument, which a Swift test checks).
local VIEWABLE = {
    md = true, markdown = true, mdown = true, mkd = true, txt = true, text = true,
}

-- True for a file (not a folder) whose extension is viewable; a bare dotfile
-- (".md") has no extension. The extension is lowercased by byte range, never
-- through a locale-dependent class or string.lower.
local function is_document(f)
    if f.isDir then return false end
    local ext = (f.path or ""):match("[^/]%.([^./]+)$")
    if ext == nil then return false end
    ext = ext:gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end)
    return VIEWABLE[ext] == true
end

-- The actions a file row offers, in priority order. The first is the primary
-- (Enter); the runner maps the rest to ⌘⏎ / ⌥⏎ and the ⌘K actions panel.
-- "Open in Prosper" (file.view) comes after Reveal, on text documents only.
local function file_actions(f)
    local actions = {
        { id = "file.open",       title = "Open",            icon = "arrow.up.forward.app" },
        { id = "file.reveal",     title = "Reveal in Finder", icon = "folder" },
    }
    if is_document(f) then
        actions[#actions + 1] = { id = "file.view", title = "Open in Prosper", icon = "doc.text" }
    end
    for _, a in ipairs({
        { id = "file.quicklook",  title = "Quick Look",      icon = "eye" },
        { id = "file.copyPath",   title = "Copy Path",       icon = "doc.on.clipboard" },
        { id = "file.copyFile",   title = "Copy File",       icon = "doc.on.doc" },
        { id = "file.trash",      title = "Move to Trash",   icon = "trash" },
    }) do
        actions[#actions + 1] = a
    end
    return actions
end

function files_run(query)
    if query == nil then return nil end
    local q = trim((query:gsub("^[fF]%s+", "")))
    if q == "" then return nil end

    local opts = parse(q)
    local files = host.files.search{
        name = opts.name,
        kind = opts.kinds,
        ext = opts.exts,
        ["in"] = opts.scope,   -- `in` is a Lua keyword; quote the key
        content = opts.content,
    }

    if files == nil or #files == 0 then
        return host.ui.render(host.ui.list{
            title = "Find Files",
            items = {
                {
                    id = "0",
                    title = "No files matching \"" .. q .. "\"",
                    icon = "magnifyingglass",
                },
            },
        })
    end

    local items = {}
    for i, f in ipairs(files) do
        items[#items + 1] = {
            id = tostring(i - 1),
            title = f.name,
            subtitle = f.display or f.path,  -- containing path (home → ~)
            accessory = f.kind,              -- trailing kind chip (e.g. "PDF document")
            image = f.path,                  -- show the file's real Finder icon
            launch = f.path,                 -- carries the path for the file actions
            icon = f.isDir and "folder" or "doc",
            actions = file_actions(f),
        }
    end

    -- style "rows" => compact native-launcher rows (icon + path + kind), matching
    -- the `open` app results rather than reading-focused cards.
    return host.ui.render(host.ui.list{ title = "Find Files", style = "rows", items = items })
end
