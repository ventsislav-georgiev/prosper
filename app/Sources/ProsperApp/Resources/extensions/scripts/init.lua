-- Scripts: save shell commands under a name and run them from the palette.
--
-- Verbs (sub-parsed from a single `sc` command):
--   sc                 list every saved script (list_on_empty)
--   sc <filter>        filter the list; an exact, unambiguous name runs
--   sc run <name>      run <name> explicitly (escapes the shadow guard below)
--   sc help            usage
--
-- Storage is a JSON array of {name, command, description, icon} in host.prefs,
-- the same store the Settings section edits (quicklinks pattern). Running shells
-- out through host.shell.run, so this runs on the off-main async lane.
--
-- ponytail: no streaming — host.shell.run is one blocking call with a host
-- timeout, so a long script shows nothing until it finishes. Upgrade path is a
-- host-side streaming shell API (chunk callback / progress re-invoke); until then
-- the description says "runs to completion".

local STORE_KEY = "scripts"
local USAGE = "sc <name> · sc run <name> · sc list · sc help"

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function load_scripts()
    local raw = host.prefs.get(STORE_KEY)
    if not raw or #raw == 0 then return {} end
    local t = host.json.decode(raw)
    if type(t) ~= "table" then return {} end
    -- Skip malformed entries so one bad hand-edit can't break the whole list.
    local out = {}
    for _, s in ipairs(t) do
        if type(s) == "table" and type(s.name) == "string" and #s.name > 0
            and type(s.command) == "string" and #s.command > 0 then
            out[#out + 1] = s
        end
    end
    return out
end

local function save_scripts(t)
    -- An empty Lua table encodes as an object; pin "[]" so the array shape holds.
    host.prefs.set(STORE_KEY, #t == 0 and "[]" or host.json.encode(t))
end

local function find_index(list, name)
    for i, s in ipairs(list) do
        if s.name == name then return i end
    end
    return nil
end

local function contains_ci(hay, needle)
    return hay:lower():find(needle:lower(), 1, true) ~= nil
end

-- True when a *longer* saved name starts with `name` — typing toward "deploy"
-- passes through "de", and auto-running the shorter script on the way would fire
-- the wrong shell command. Shadowed names still run via `sc run <name>`.
local function shadowed(list, name)
    for _, s in ipairs(list) do
        if #s.name > #name and s.name:sub(1, #name) == name then return true end
    end
    return false
end

local function rows(list, filter)
    local items = {}
    for _, s in ipairs(list) do
        if filter == nil or #filter == 0 or contains_ci(s.name, filter) then
            items[#items + 1] = {
                id = tostring(#items),
                title = s.name,
                subtitle = (type(s.description) == "string" and #s.description > 0)
                    and s.description or ("$ " .. s.command),
                icon = (type(s.icon) == "string" and #s.icon > 0) and s.icon or "terminal",
            }
        end
    end
    if #items == 0 then
        return #list == 0 and "No scripts yet. Add one in Settings › Scripts."
            or ("No script matching '" .. (filter or "") .. "'")
    end
    return host.ui.render(host.ui.list{ title = "Scripts", style = "rows", items = items })
end

-- Run one script and render its captured output as a compact result row —
-- same shape as the shell extension's output (see shell/init.lua).
local function run_script(s)
    local out = host.shell.run(s.command)
    out = trim(out or "")
    return host.ui.render(host.ui.list{
        title = s.name,
        style = "rows",
        items = {
            {
                id = "0",
                title = (out ~= "" and out) or "(no output)",
                subtitle = "$ " .. s.command,
                icon = (type(s.icon) == "string" and #s.icon > 0) and s.icon or "terminal",
            },
        },
    })
end

function scripts_run(query)
    if query == nil then return nil end
    -- The runner restores the "sc " prefix before calling; strip it back off.
    local rest = trim((trim(query):gsub("^[Ss][Cc]", "", 1)))
    local list = load_scripts()
    if #rest == 0 then return rows(list, nil) end

    local verb, tail = rest:match("^(%S+)%s*(.*)$")
    tail = trim(tail or "")
    local lv = verb:lower()

    if lv == "help" then
        return USAGE
    elseif lv == "list" or lv == "ls" then
        return rows(list, nil)
    elseif lv == "run" then
        if #tail == 0 then return "Usage: sc run <name>" end
        local i = find_index(list, tail)
        if not i then return "No script '" .. tail .. "'. Add it in Settings › Scripts." end
        return run_script(list[i])
    end

    -- Otherwise the typed text is a name/filter. An exact, unshadowed match runs;
    -- anything else lists the matches (Enter would only copy a row, so the query
    -- itself is what triggers the run).
    local i = find_index(list, rest)
    if i and not shadowed(list, rest) then return run_script(list[i]) end
    return rows(list, rest)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Settings (Tier B): an editable Scripts list in its own sidebar section, backed
-- by the same host.prefs store the runner reads. Copied from quicklinks'
-- settings_render / settings_action (`records` control).

local function sc_fields(name, command, description, icon)
    return {
        { id = "name", label = "Name", kind = "text",
          value = name, placeholder = "deploy" },
        { id = "command", label = "Command", kind = "text",
          value = command, placeholder = "git -C ~/app pull && make deploy" },
        { id = "description", label = "Description (optional)", kind = "text",
          value = description, placeholder = "" },
        { id = "icon", label = "Icon (optional SF Symbol)", kind = "text",
          value = icon, placeholder = "terminal" },
    }
end

local function str(v) return (type(v) == "string") and v or "" end

function settings_render(section_id, state)
    local list = load_scripts()
    local recs = {}
    for _, s in ipairs(list) do
        recs[#recs + 1] = {
            id = s.name, title = s.name, subtitle = s.command,
            icon = (#str(s.icon) > 0) and s.icon or "terminal",
            fields = sc_fields(s.name, s.command, str(s.description), str(s.icon)),
        }
    end
    return host.ui.settings.render(host.ui.settings.ui{
        title = "Scripts",
        subtitle = "Save shell commands; run them with sc <name>",
        sections = {
            host.ui.settings.section{
                id = "scripts", title = "Scripts", accent = "Scripts",
                footer = "Run one later by typing sc <name> in the runner. Each script runs "
                    .. "through your login shell to completion, then shows its captured output — "
                    .. "long-running commands show nothing until they finish.",
                rows = {
                    host.ui.settings.records{
                        id = "scripts",
                        records = recs,
                        fields = sc_fields("", "", "", ""),
                        addLabel = "Add Script",
                        emptyText = "No scripts yet. Add one below, e.g. name “deploy”, "
                            .. "command “make deploy”.",
                    },
                },
            },
        },
    })
end

function settings_action(section_id, action, value, form_json)
    local form = host.json.decode(form_json or "") or {}

    local del = action:match("^record%.delete:scripts:(.*)$")
    if del then
        local list = load_scripts()
        local i = find_index(list, del)
        if i then
            table.remove(list, i)
            save_scripts(list)
        end
        return settings_render(section_id, "{}")
    end

    -- `record.save:scripts:<oldName>` — empty <oldName> means a brand-new record.
    local old = action:match("^record%.save:scripts:(.*)$")
    if old then
        local name = trim(str(form.name))
        local command = trim(str(form.command))
        if #name > 0 and #command > 0 then
            local list = load_scripts()
            local entry = { name = name, command = command,
                            description = trim(str(form.description)),
                            icon = trim(str(form.icon)) }
            -- Rename keeps the row's position; no orphan is left behind.
            local i = find_index(list, name)
            local oi = (#old > 0 and old ~= name) and find_index(list, old) or nil
            if i then
                list[i] = entry
                if oi then table.remove(list, oi) end
            elseif oi then
                list[oi] = entry
            else
                list[#list + 1] = entry
            end
            save_scripts(list)
        end
        return settings_render(section_id, "{}")
    end

    return settings_render(section_id, "{}")
end
