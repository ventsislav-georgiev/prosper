-- Quickdirs: register directory roots, browse their subfolders from the palette,
-- and run an action on the chosen directory.
--
-- Browsing and the picker are handled NATIVELY (the host intercepts `qd`,
-- `qd <name>`, and per-quickdir prefixes, rendering folder rows). This Lua
-- command only handles the management verbs the host delegates here:
--   qd add <name> <path> [prefix]   register a quickdir (action set in Settings)
--   qd rm <name>                    remove one
--   qd list                         show all
--   qd help                         usage
--
-- Storage is shared with the native side: host.prefs `dirs` holds a JSON ARRAY
-- of { name, path, prefix, action, actionLabel } objects (same shape the native
-- QuickdirStore reads/writes), so edits from either side stay in sync.

local STORE_KEY = "dirs"
local USAGE = "qd <name> [filter] · qd add <name> <path> [prefix] · qd rm <name> · qd list"

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Load the configs as an array of objects. Tolerates an empty / malformed store.
local function load_dirs()
    local raw = host.prefs.get(STORE_KEY)
    if not raw or #raw == 0 then return {} end
    local t = host.json.decode(raw)
    if type(t) ~= "table" then return {} end
    return t
end

local function save_dirs(t)
    host.prefs.set(STORE_KEY, host.json.encode(t))
end

local function find_index(dirs, name)
    local lname = name:lower()
    for i, d in ipairs(dirs) do
        if type(d) == "table" and d.name and d.name:lower() == lname then return i end
    end
    return nil
end

-- Build the "Add Quickdir" form node (reused by the opener and the
-- validation re-render path so typed values survive a failed submit).
local function qd_form(name, path, prefix, action, action_label, err)
    return host.ui.form{
        title = err and ("Add Quickdir — " .. err) or "Add Quickdir",
        fields = {
            { id = "name", label = "Name", kind = "text",
              value = name or "", placeholder = "projects" },
            { id = "path", label = "Directory", kind = "text",
              value = path or "", placeholder = "~/projects" },
            { id = "prefix", label = "Prefix (optional)", kind = "text",
              value = prefix or "", placeholder = "p" },
            { id = "action", label = "Action (optional)", kind = "text",
              value = action or "", placeholder = "code {path}" },
            { id = "actionLabel", label = "Action label (optional)", kind = "text",
              value = action_label or "", placeholder = "Open in VS Code" },
        },
        actions = {
            { id = "qd_save", title = "Save", icon = "checkmark.circle.fill" },
        },
    }
end

-- `qd add [name]` launcher: open the dialog, pre-filling name from trailing text.
function quickdirs_add(query)
    local rest = trim((trim(query or ""):gsub("^[Qq][Dd]%s+[Aa][Dd][Dd]", "", 1)))
    local name = rest:match("^(%S+)") or ""
    host.window.open(qd_form(name, "", "", "", ""))
    return ""
end

-- Submit handler: persist + close, or re-render the form with an error.
-- Action fields left blank fall back to an existing entry's values on re-add,
-- so re-registering a quickdir never silently wipes its configured action.
function qd_save(_, form_json)
    local form = host.json.decode(form_json or "") or {}
    local name = trim(form.name or "")
    local path = trim(form.path or "")
    local prefix = trim(form.prefix or "")
    local action = trim(form.action or "")
    local action_label = trim(form.actionLabel or "")
    if #name == 0 or #path == 0 then
        return host.ui.render(qd_form(name, path, prefix, action, action_label,
                                      "name & directory required"))
    end
    local dirs = load_dirs()
    local idx = find_index(dirs, name)
    local entry = { name = name, path = path, prefix = prefix,
                    action = action, actionLabel = action_label }
    if idx then
        if #action == 0 then entry.action = dirs[idx].action or "" end
        if #action_label == 0 then entry.actionLabel = dirs[idx].actionLabel or "" end
        dirs[idx] = entry
    else
        dirs[#dirs + 1] = entry
    end
    save_dirs(dirs)
    host.notify("Quickdir saved", name .. " → " .. path)
    host.window.close()
    return nil
end

function quickdirs_run(query)
    query = trim(query or "")
    local rest = trim((query:gsub("^[Qq][Dd]", "", 1)))
    if #rest == 0 then return USAGE end

    local verb, tail = rest:match("^(%S+)%s*(.*)$")
    tail = trim(tail or "")
    local lv = verb:lower()

    if lv == "add" then
        local name, path_and_prefix = tail:match("^(%S+)%s+(.+)$")
        if not name then return "Usage: qd add <name> <path> [prefix]" end
        -- Optional trailing prefix token: "qd add work ~/work p" → prefix "p".
        local path, prefix = path_and_prefix:match("^(.-)%s+(%S+)$")
        if not path then path, prefix = trim(path_and_prefix), "" end
        path = trim(path)
        local dirs = load_dirs()
        local idx = find_index(dirs, name)
        local entry = {
            name = name, path = path, prefix = prefix or "",
            action = "", actionLabel = "",
        }
        if idx then
            -- Preserve an existing action/label on re-add.
            entry.action = dirs[idx].action or ""
            entry.actionLabel = dirs[idx].actionLabel or ""
            dirs[idx] = entry
        else
            dirs[#dirs + 1] = entry
        end
        save_dirs(dirs)
        local pfx = (#entry.prefix > 0) and ("  (prefix '" .. entry.prefix .. "')") or ""
        return "Saved quickdir '" .. name .. "' → " .. path .. pfx
            .. "\tSet an action in Settings › Quickdirs."

    elseif lv == "rm" or lv == "remove" or lv == "del" or lv == "delete" then
        local name = tail:match("^(%S+)")
        if not name then return "Usage: qd rm <name>" end
        local dirs = load_dirs()
        local idx = find_index(dirs, name)
        if not idx then return "No quickdir: " .. name end
        table.remove(dirs, idx)
        save_dirs(dirs)
        return "Removed quickdir '" .. name .. "'"

    elseif lv == "list" or lv == "ls" then
        local dirs = load_dirs()
        if #dirs == 0 then return "No quickdirs yet. Add one: qd add <name> <path> [prefix]" end
        local lines = {}
        for _, d in ipairs(dirs) do
            local pfx = (d.prefix and #d.prefix > 0) and (" [" .. d.prefix .. "]") or ""
            lines[#lines + 1] = d.name .. pfx .. " → " .. (d.path or "")
        end
        return table.concat(lines, "\n")

    elseif lv == "help" then
        return USAGE
    end

    -- Any other verb is a quickdir name; the host normally intercepts browsing,
    -- so reaching here means no such quickdir / no match.
    return "No quickdir '" .. verb .. "'. Add it: qd add " .. verb .. " <path>"
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Settings (Tier B): an editable QuickDirs list in its own sidebar section, over
-- the same host.prefs `dirs` store the runner reads. Replaces the native
-- QuickdirsPane — 1:1 via the `records` control.

-- Field schema for one quickdir (reused for existing rows, with values, and as the
-- blank template the Add button opens).
local function qd_fields(name, path, prefix, action, action_label)
    return {
        { id = "name", label = "Name", kind = "text",
          value = name, placeholder = "projects" },
        { id = "path", label = "Directory", kind = "text",
          value = path, placeholder = "~/projects" },
        { id = "prefix", label = "Prefix (optional)", kind = "text",
          value = prefix, placeholder = "p" },
        { id = "action", label = "Action (optional)", kind = "text",
          value = action, placeholder = "code {path}" },
        { id = "actionLabel", label = "Action label (optional)", kind = "text",
          value = action_label, placeholder = "Open in VS Code" },
    }
end

function settings_render(section_id, state)
    local dirs = load_dirs()
    local recs = {}
    for _, d in ipairs(dirs) do
        if type(d) == "table" and d.name then
            local pfx = (d.prefix and #d.prefix > 0) and ("[" .. d.prefix .. "]  ") or ""
            recs[#recs + 1] = {
                id = d.name, title = d.name, subtitle = pfx .. (d.path or ""),
                icon = "folder.fill",
                fields = qd_fields(d.name, d.path or "", d.prefix or "",
                                   d.action or "", d.actionLabel or ""),
            }
        end
    end
    return host.ui.settings.render(host.ui.settings.ui{
        title = "QuickDirs",
        subtitle = "Browse a directory's subfolders and run an action on the one you pick",
        sections = {
            host.ui.settings.section{
                id = "quickdirs", title = "QuickDirs", accent = "Dirs",
                footer = "Type qd to pick one, or its prefix (e.g. “p ”) to jump straight in. "
                    .. "The action runs on the selected subfolder — a shell command (e.g. code {path}) "
                    .. "or a URL (e.g. https://example.com/?repo={name}). Tokens: {path} {name} {query}. "
                    .. "Leave the action empty to reveal the folder in Finder.",
                rows = {
                    host.ui.settings.records{
                        id = "dirs",
                        records = recs,
                        fields = qd_fields("", "", "", "", ""),
                        addLabel = "Add Quickdir",
                        revealFile = "~/.config/prosper/quickdirs.json",
                        revealLabel = "Reveal quickdirs.json",
                        emptyText = "No quickdirs yet. Add one below, e.g. name “projects”, "
                            .. "path “~/projects”, prefix “p”.",
                    },
                },
            },
        },
    })
end

function settings_action(section_id, action, value, form_json)
    local form = host.json.decode(form_json or "") or {}

    local del = action:match("^record%.delete:dirs:(.*)$")
    if del then
        local dirs = load_dirs()
        local idx = find_index(dirs, del)
        if idx then table.remove(dirs, idx); save_dirs(dirs) end
        return settings_render(section_id, "{}")
    end

    -- `record.save:dirs:<oldName>` — empty <oldName> means a brand-new record.
    local old = action:match("^record%.save:dirs:(.*)$")
    if old then
        local name = trim(form.name or "")
        local path = trim(form.path or "")
        if #name > 0 and #path > 0 then
            local dirs = load_dirs()
            local entry = {
                name = name, path = path,
                prefix = trim(form.prefix or ""),
                action = trim(form.action or ""),
                actionLabel = trim(form.actionLabel or ""),
            }
            -- Rename: drop the old entry first so no orphan key survives.
            if #old > 0 and old:lower() ~= name:lower() then
                local oidx = find_index(dirs, old)
                if oidx then table.remove(dirs, oidx) end
            end
            local idx = find_index(dirs, name)
            if idx then dirs[idx] = entry else dirs[#dirs + 1] = entry end
            save_dirs(dirs)
        end
        return settings_render(section_id, "{}")
    end

    return settings_render(section_id, "{}")
end
