-- killproc — system extension.
--
-- `kill ` lists the running processes ranked by CPU (one `ps` call, parsed here)
-- and filters them as you type. `kill <pid>!` terminates (SIGTERM);
-- `kill <pid>!!` forces (SIGKILL). Both go through host.dialog.confirm first.
--
-- Why a trailing "!" instead of Enter on a row: a locked runner mode re-invokes
-- this handler on every keystroke, so a bare `kill 1234` would fire at "1", "12",
-- "123"… on the way there; and an inline list row cannot call back into Lua on
-- Enter (row `actions` dispatch natively to reserved `file.*` ids only). A
-- trailing sentinel can never be a prefix of what the user is still typing.
--
-- TRUST BOUNDARY. `killproc_guard` is the whole safety story and is exported so
-- killproc.test.lua can hammer it directly:
--   * the pid must match `^%d+$` — checked BEFORE it is ever put in a shell string
--   * pid <= 1 is refused (kernel_task / launchd)
--   * Prosper's own pid is refused
--   * a name blocklist is refused (mirrors upstream KillProcessSupport.isProtected)
--   * the process NAME is never interpolated into a command, only ever displayed

local BLOCKLIST = {
    kernel_task = true,
    launchd     = true,
    WindowServer = true,
    loginwindow = true,
    Prosper     = true,
}

-- `ps -o comm=` prints the full executable path; the blocklist is by name.
local function basename(path)
    return (tostring(path or ""):gsub("^.*/", ""))
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- Refusal reason for killing `pid` (a string or number) named `comm`, or nil when
-- the kill is allowed. `own` is Prosper's own pid. Pure — no host calls — so the
-- guard table is directly testable.
function killproc_guard(pid, comm, own)
    local s = tostring(pid or "")
    if not s:match("^%d+$") then return "not a pid" end
    local n = tonumber(s)
    if n == nil or n <= 1 then return "system pid" end
    if own and n == own then return "that's Prosper" end
    if comm == nil or trim(comm) == "" then return "no such process" end
    local name = basename(trim(comm))
    if BLOCKLIST[name] then return "protected: " .. name end
    return nil
end

-- Prosper's own pid. host.shell.run spawns `/bin/zsh -lc` as a DIRECT child of
-- the app, so the login shell's $PPID is us.
-- ponytail: one cached shell hop because the host exposes no own-pid API; add
-- host.apps.self() if anything else ever needs it.
local OWN_PID
local function own_pid()
    if OWN_PID == nil then
        OWN_PID = tonumber((host.shell.run("echo $PPID") or ""):match("%d+")) or -1
    end
    return OWN_PID
end

-- MARK: listing ---------------------------------------------------------------

local function human_rss(kb)
    if kb >= 1024 * 1024 then return string.format("%.1f GB", kb / 1024 / 1024) end
    if kb >= 1024 then return string.format("%.0f MB", kb / 1024) end
    return string.format("%d KB", kb)
end

-- One `ps` call -> { { pid, cpu, rss, comm, name }, ... } sorted by CPU desc.
local function processes()
    local out = host.shell.run("ps -Ao pid=,pcpu=,rss=,comm= -r | head -n 200") or ""
    local rows = {}
    for line in out:gmatch("[^\n]+") do
        local pid, cpu, rss, comm = line:match("^%s*(%d+)%s+([%d%.]+)%s+(%d+)%s+(.+)$")
        if pid then
            rows[#rows + 1] = {
                pid = pid, cpu = tonumber(cpu) or 0, rss = tonumber(rss) or 0,
                comm = comm, name = basename(comm),
            }
        end
    end
    -- `ps -r` already sorts by CPU, but re-sort so the order is ours, not the
    -- platform's (stable tiebreak on pid keeps the list from jittering).
    table.sort(rows, function(a, b)
        if a.cpu ~= b.cpu then return a.cpu > b.cpu end
        return a.pid < b.pid
    end)
    return rows
end

local function matches(p, q)
    if q == "" then return true end
    return p.name:lower():find(q, 1, true) ~= nil or p.pid:find(q, 1, true) ~= nil
end

local function listing(q, own)
    local items = {}
    for _, p in ipairs(processes()) do
        if matches(p, q) and #items < 50 then
            local why = killproc_guard(p.pid, p.comm, own)
            items[#items + 1] = {
                id = tostring(#items),
                title = p.name,
                subtitle = string.format("pid %s  ·  %.1f%% CPU  ·  %s",
                                         p.pid, p.cpu, human_rss(p.rss)),
                accessory = why or ("kill " .. p.pid .. "!"),
                icon = why and "lock.shield" or "xmark.octagon",
            }
        end
    end
    if #items == 0 then
        return "No process matches '" .. q .. "'"
    end
    return host.ui.render(host.ui.list{ title = "Kill Process", style = "rows", items = items })
end

-- MARK: the destructive path --------------------------------------------------

-- Name of `pid` per `ps`, or nil. Only ever called with a `^%d+$`-validated pid.
local function comm_for(pid)
    local out = host.shell.run("ps -o comm= -p " .. pid) or ""
    local first = out:match("[^\n]+")
    return first and trim(first) or nil
end

local function do_kill(pid, force)
    -- Re-validate before ANY shell use — comm_for below interpolates the pid, and
    -- it runs BEFORE killproc_guard (the guard needs the name `ps` reports). The
    -- only caller's pattern already constrains this to digits; kept as the local
    -- precondition of the interpolation so it survives a future second caller.
    if not pid:match("^%d+$") then return "Refused: not a pid" end

    local own = own_pid()
    local comm = comm_for(pid)
    local why = killproc_guard(pid, comm, own)
    if why then return "Refused (" .. pid .. "): " .. why end

    local name = basename(comm)
    local signal = force and "-9" or "-TERM"
    if not host.dialog.confirm{
        title = force and "Force kill?" or "Kill process?",
        message = string.format("Send %s to %s (pid %s)?", signal, name, pid),
        ok = force and "Force Kill" or "Kill",
        cancel = "Cancel",
    } then
        return "Cancelled"
    end

    -- Only the validated pid is interpolated; `name` is display-only.
    host.shell.run("kill " .. signal .. " " .. pid)
    host.notify("Sent " .. signal, name .. " (pid " .. pid .. ")")
    return string.format("Sent %s to %s (pid %s)", signal, name, pid)
end

-- MARK: entry point -----------------------------------------------------------

function killproc_run(query)
    -- The runner restores the "kill " prefix before calling; strip it back off.
    local q = trim((trim(query or ""):gsub("^[kK][iI][lL][lL]%s*", "", 1)))

    -- Commit forms: "<pid>!" = SIGTERM, "<pid>!!" = SIGKILL. Checked first so a
    -- pid-shaped query only ever kills with the explicit trailing sentinel.
    local pid, bangs = q:match("^(%d+)%s*(!+)$")
    if pid then
        return do_kill(pid, #bangs >= 2)
    end

    return listing(q:lower(), own_pid())
end
