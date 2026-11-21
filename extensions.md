# Writing Prosper extensions

A fast, lightweight **Lua extension system** (Neovim-style) — no recompile, no webviews, a strict native surface. Drop a folder in `~/.config/prosper/extensions` and it shows up in Prosper's universal launcher, contributes a Settings pane, drives system automation, or paints a theme.

Everything in this guide is shipped and has a **worked example you can read**. Links throughout point at the exact extension that exercises each feature:

- Bundled (system) extensions → [`app/Sources/ProsperApp/Resources/extensions/`](app/Sources/ProsperApp/Resources/extensions/)
- Trust-gated automation showcase → [`app/Examples/extensions/hammerspoon-compat/`](app/Examples/extensions/hammerspoon-compat/)

---

## 1. Anatomy of an extension

**One directory per extension:**

```
my-ext/
├── extension.toml   # manifest: identity, host gate, contributions
├── init.lua         # entry script: command + event + settings handlers
└── theme.json       # optional, only if you contribute a theme
```

Minimal manifest + handler — the [`base64`](app/Sources/ProsperApp/Resources/extensions/base64/) extension is the smallest real one:

```toml
# extension.toml
[extension]
id          = "com.example.shout"   # reverse-DNS, globally unique
name        = "shout"               # short slug
title       = "Shout"               # display name
description = "Uppercase the query."
version     = "1.0.0"               # semver — bump it; updates/reset key off it
author      = "you"
icon        = "textformat"          # optional SF Symbol name
license     = "MIT"                 # optional

[extension.host]
min_version = "2.0.0"   # lowest Prosper that may load this extension
api_level   = 1         # host API generation this targets

[extension.entry]
main = "init.lua"

[[contributes.commands]]
id    = "shout.run"
title = "Shout"
mode  = "no-view"        # "no-view" (scalar result) | "view" (a host.ui tree) | "background"
match = "^shout "        # cheap native pre-filter: the query must match before Lua runs
```

```lua
-- init.lua
-- The handler is the global named after the command id with every non-alphanumeric
-- replaced by '_': command "shout.run" → shout_run(query). Return a string
-- (or "value\tdetail"), a host.ui.render(...) tree, or nil to decline.
function shout_run(query)
    return (query:gsub("^shout ", "")):upper()
end
```

### `[extension]` — identity & lifecycle

| Field | Meaning |
| ----- | ------- |
| `id` `name` `title` `description` `version` `author` | Identity. `version` is semver and **gates updates, Marketplace, and Reset-to-original — bump it on every change.** |
| `icon` | Optional SF Symbol name shown in the launcher/Settings. |
| `license` | Optional SPDX string. |
| `system` | `true` only for bundled extensions — editable + **resettable**, never uninstallable. You never set this. |
| `default_disabled` | Ship **opt-in**: the extension is live only after the user turns it on. Use it whenever mere activation changes system behaviour or adds chrome. Bundled examples: [`menubar`](app/Sources/ProsperApp/Resources/extensions/menubar/), [`inputswitch`](app/Sources/ProsperApp/Resources/extensions/inputswitch/), [`url-dispatcher`](app/Sources/ProsperApp/Resources/extensions/url-dispatcher/). |
| `permissions` | macOS privacy grants the extension can use, surfaced in Settings → Extensions. Only `"full-disk-access"` is recognized today ([`bookmarks`](app/Sources/ProsperApp/Resources/extensions/bookmarks/) needs it for its Safari source; degrades gracefully without). |
| `update_url` | Where auto-update polls. Optional — a GitHub install writes its origin here automatically. A pinned ref (`/tree/v1.2.3`) never updates; a branch/root install tracks it. |

### `[extension.host]` — version gate

`min_version` is the lowest Prosper that may load this extension; `api_level` is the host-API generation it targets. A local dev bundle runs as host `0.0.0`, so a `min_version` above that hides every extension — drop `min_version` to `0.0.0` if extensions vanish in a local build.

### `[extension.activation]` — lazy-load triggers (optional)

```toml
[extension.activation]
on_event = ["system.launch"]   # non-command triggers that spin the VM
eager    = false               # eager startup load — reserved for core, discouraged
```

Commands and settings sections auto-generate their own activation triggers, so you only declare `on_event` for background work that no command covers. VMs are built **lazily on first trigger** — an extension nobody invokes costs nothing.

---

## 2. Commands & the universal launcher

Each `[[contributes.commands]]` row adds an entry to Prosper's launcher.

```toml
[[contributes.commands]]
id              = "ql.run"
title           = "Quick Links"
description      = "Open a saved link."
mode            = "no-view"
icon            = "link"
keywords        = ["bookmark", "url"]   # extra launcher discovery terms
match           = "^ql "                 # native regex pre-filter (hot path stays native)
prefix          = "ql "                   # leading prefix locks the runner into this command as a mode
prefixes        = ["link "]               # extra aliases that lock the same mode
when            = ""                      # context expression gating palette visibility (empty = always)
requires        = ["model"]               # hidden until the local LLM is downloaded AND loaded
list_on_empty   = true                    # run on an empty query so the mode opens pre-populated
launches_window = false                   # surface as a row that opens a window on Enter (no per-keystroke run)
runs_on_select  = false                   # discovery-list pick runs immediately (for parameterless toggles)
bindable_items  = true                    # each listed row becomes its own bindable global shortcut
phone           = true                    # offer it on the iPhone's Commands screen (plain no-view commands only, see below)
phone_argument  = "github"                # argument hint the phone shows (absent = tap to run)
```

| Field | Effect |
| ----- | ------ |
| `mode` | `"no-view"` returns a string/`"value\tdetail"`; `"view"` returns a `host.ui.*` tree; `"background"` is a scheduled/background job. |
| `match` | Cheap native regex the query must satisfy **before** the Lua handler is dispatched — keeps hot routing native. |
| `keywords` | Extra discovery terms for fuzzy launcher matching. |
| `prefix` / `prefixes` | A leading token (e.g. `"ql "`) that locks the runner into this command as a labelled mode, stripping the prefix from the visible query — exactly like the built-in `l `/`o ` modes. `prefixes` are aliases (e.g. [`translate`](app/Sources/ProsperApp/Resources/extensions/translate/) ships `l ` primary + `t ` alias). |
| `when` | Context expression controlling palette visibility (empty = always visible). |
| `requires = ["model"]` | Hide the command until the local AI model is downloaded **and** loaded — used by LLM-backed commands like [`translate`](app/Sources/ProsperApp/Resources/extensions/translate/). |
| `list_on_empty` | Run the handler on an empty query so a listing mode opens pre-populated then filters as you type ([`bookmarks`](app/Sources/ProsperApp/Resources/extensions/bookmarks/)). Off = clear the result on empty input (right default for a scalar like Translate). |
| `launches_window` | Surface as a row that opens its own window on Enter instead of running per keystroke. |
| `runs_on_select` | Picking the command from the discovery list runs the handler immediately rather than entering its input mode. Reserve for **parameterless, non-destructive** actions (toggles/status, e.g. [`openlid`](app/Sources/ProsperApp/Resources/extensions/openlid/)'s "Toggle Mac Awake"). It never auto-fires on a keystroke — only on an explicit Enter on the selected row. |
| `bindable_items` | With `list_on_empty`, expand the command in Settings › Shortcuts into **one bindable global shortcut per listed row**, so a hotkey can open one specific [`sysprefs`](app/Sources/ProsperApp/Resources/extensions/sysprefs/) pane or run one saved [`scripts`](app/Sources/ProsperApp/Resources/extensions/scripts/) entry. Firing sends `prefix + row title` to the handler and then performs that row's `url` / `launch` / first action. Opt in only when the rows are **stable and individually addressable** — a listing of live processes or of thousands of bookmarks makes for dead or unusable bindings. |
| `phone` | Offer the command on the iPhone's Commands screen (Remote Terminal). It shows there only while **Run commands from iPhone** is on and the user ticks **Allow on iPhone** on your extension's row in Settings › Extensions (off by default). The phone sends `"<extension id>/<command id>"`, asks before running it, and runs your handler headless on your extension's async lane with the phone's argument (your `prefix`, if any, goes back on first, like the locked runner mode). The handler must return text (`"value"` or `"value\tdetail"`); a view tree is refused. Ignored, with a load-log warning, on a command that is not `mode = "no-view"`, or sets `launches_window`, `requires = ["model"]` or `list_on_empty`. Ignored on system extensions. **An update that adds, removes or renames a phone command, or changes a `phone_argument`, turns Allow on iPhone off** until the user ticks it again. |
| `phone_argument` | The argument hint the phone shows (e.g. `"2+2"`). Absent or `""` = the command takes no argument: a tap runs it. Ignored without `phone = true`. |

Other contribution arrays under `[contributes]`: `keybindings` (`{ command, key, when }` — a default global hotkey that runs the command with no visible runner; every one of them is listed, rebindable, and clearable in Settings › Shortcuts › Extension Commands, where the user's override wins over the manifest key), `views`, `placeholders` (snippet tokens, §6), `events` (§5), `themes` (§7), `settings_sections` (§8).

Any installed extension whose `match` accepts the query is dispatched on its own **off-main async lane** — that is how [`quicklinks`](app/Sources/ProsperApp/Resources/extensions/quicklinks/) and your own extensions surface as palette commands. [`currency`](app/Sources/ProsperApp/Resources/extensions/currency/) is the canonical async example: it fetches daily FX over `host.http` (with retry), caches via `host.prefs`/`host.time`, and never blocks the main thread.

---

## 3. The host API (`host.*`)

The host surface is strict, time-boxed, and assembled per-extension. **Reads are open to every extension; side-effecting calls are tiered (§9).** Full Swift surface: [`ExtensionHostAPI.swift`](app/Sources/ProsperApp/Extensions/ExtensionHostAPI.swift) and [`LiveExtensionHostServices.swift`](app/Sources/ProsperApp/Extensions/LiveExtensionHostServices.swift).

### Core (every extension)

- `host.clipboard.{read,write,history}` — `write("")` clears the pasteboard (no empty-string item left behind)
- `host.prefs.{get,set}` — durable per-extension key/value store
- `host.time()` → wall-clock epoch seconds · `host.sleep(seconds)` → for backoff (capped)
- `host.date()` → `{ epoch, year, month, day, hour, min, sec, wday }` (the sandbox has no `os.date`)
- `host.notify(...)` · `host.log.{info,warn,error}` → os_log · `host.env.get(name)`
- `host.json.{encode,decode}` — native JSON (decode returns nil on malformed input); also powers `host.ui.render`
- `host.perms.has(name)` → bool — read a macOS privacy grant (`"accessibility"`, `"full-disk-access"`, …). Surface a missing grant with a `permission` settings row (§8).
- `host.fs.list_dirs(path)` → immediate subdirectory names (tilde-expanded, hidden skipped, sorted) — the only **open** filesystem capability. Powers [`quickdirs`](app/Sources/ProsperApp/Resources/extensions/quickdirs/).
- `host.fs.{exists,attributes}` → `exists(path)` bool; `attributes(path)` → `{ exists, isDir, size, mtime }`
- `host.apps.search(query)` → ranked `{ { name=, path= }, … }`. Powers the [`open`](app/Sources/ProsperApp/Resources/extensions/open/) launcher.
- Read sensors: `host.battery.{power_source,percentage}` (percentage nil when no battery) · `host.network.{reachable,addresses}` · `host.screen.{all,count,lid_closed}` (lid_closed = true/false/nil)
- `host.llm.complete(...)` · `host.llm.translate(text, target [, source])` → `{ primary, detected, candidates = { { text=, label=, note= }, … } }` (nil on empty/failed) — feeds a result view directly.
- `host.snippets.*` — native snippet store + placeholder engine, the hackable surface behind [`snippets`](app/Sources/ProsperApp/Resources/extensions/snippets/): `all()`, `get(name)`, `save{ name=, keyword=, text=, … }` (upsert), `remove(name)`, `expand(keyword [, args])` → resolved text (dates/clipboard/arguments applied), plus config/collections/ignored getters+setters and `import_file`.

### `host.http` — outbound HTTP (automation tier)

```lua
local resp, err = host.http.get(url [, opts])
-- host.http.request{ url=, method=, headers=, body=, timeout=, ... }
-- host.http.post(url, body [, opts])
```

Built-in **retry + exponential backoff** on transient failures (no response / 5xx / 408 / 429); http/https only, time-boxed, response capped at 5 MB. Returns `{ status, body, headers, ok, json }`. Worked example: [`currency`](app/Sources/ProsperApp/Resources/extensions/currency/).

### `host.window` + `host.ui` — declarative native UI

- `host.window.frame()` → `{ x, y, w, h, screen = { x, y, w, h } } | nil` — focused-window geometry via Accessibility; nil when no window is focused, Accessibility permission is missing, or macOS reports a non-finite frame · `host.window.set(x,y,w,h)` → bool (move/resize). A missing argument becomes 0; a non-finite one makes it return false. Powers [`window`](app/Sources/ProsperApp/Resources/extensions/window/).
- `host.window.open(node)` opens a standalone host-rendered window from a `host.ui.*` node; `host.window.close()` dismisses it (used by form/dialog submit handlers).
- `host.ui.{list,detail,form,grid,converter,loading,render}` build native SwiftUI trees — **no HTML, the host owns every pixel.** Renderer: [`ExtensionViewRenderer.swift`](app/Sources/ProsperApp/Extensions/ExtensionViewRenderer.swift).
- `host.ui.chooseApp()` → `{ bundleID=, name= }` | nil — native app picker (used by [`inputswitch`](app/Sources/ProsperApp/Resources/extensions/inputswitch/)).
- `host.ui.settings.*` — the Settings-pane builders (§8).

A list item's `actions` are the per-row verbs the runner surfaces (Enter runs the first, ⌘K lists them all). An action `id` is either a **reserved** `file.*` id the host runs natively (`file.open`, `file.reveal`, `file.quicklook`, `file.copyPath`, `file.copyFile`, `file.openWith`, `file.enclosingFolder`, `file.trash` — see [`FileActions.swift`](app/Sources/ProsperApp/Commands/FileActions.swift)) or **any other id**, which dispatches back into your extension: the host calls the global `<command>_action(actionID, value, formJSON)` — `<command>` being your command id with non-alphanumerics replaced by `_` — and dismisses the runner. `value` defaults to the row's payload and can be overridden per action, so one handler can fan out over rows (e.g. a per-package `upgrade` action carrying the package name).

`host.ui.loading{ title=, subtitle=, progress= }` renders an Apple-style loading state — an **infinite** spinner when `progress` is absent, a **progressive** bar (0…1 with a percentage) when set. The host also shows this spinner automatically while an async view action is in flight, so every async operation gets a polished loading state for free.

`host.ui.converter{ title=, left={label,placeholder,value}, right={…}, forward=, backward=, mono= }` is a live bidirectional two-pane transform window (open it via `host.window.open`): `forward`/`backward` name global Lua functions (text → text) — editing the left pane runs `forward` into the right, editing the right runs `backward` into the left. [`base64`](app/Sources/ProsperApp/Resources/extensions/base64/) is the worked example. The transforms run on the extension's background lane, like window button actions, so typing stays responsive while a large paste converts and the latest edit wins; they do not see globals that a main-thread command set, so keep a transform a pure function of its input.

### Async & timeouts

Long-running natives are async, bridged to sync Lua with a hard timeout — extensions run off the main thread. On timeout the bridge **cancels** the underlying work (a stuck `host.http` request stops; it isn't orphaned), so a wedged call can't keep burning a thread after your handler moved on.

---

## 4. Performance & isolation

Each extension's off-main work runs on its **own serial lane**, so a slow handler (e.g. `host.http` retrying with backoff) never blocks another extension's commands, timers, or events; within one extension calls stay serialized so a `host.prefs` read-modify-write can't interleave.

**Runtime:** Lua 5.4 vendored in-process (pure C, no JIT → notarization-clean), sandboxed — no `io`/`os`/`package`/`require`/file/net — with an instruction budget that aborts runaways. See [`LuaRuntime.swift`](app/Sources/LuaRuntime/LuaRuntime.swift).

**What a script can use:** only these standard libraries are opened: the base functions, `coroutine`, `table`, `string`, `math` and `utf8`. `io`, `os`, `package` and the `debug` library are never opened. From the base functions, `dofile` and `loadfile` are removed; `load`, where the host keeps it (trusted and built-in extensions), takes source text only (a precompiled binary chunk is refused); `string.dump` is removed. `debug` is a table holding `debug.traceback` only, so `xpcall(f, debug.traceback)` works. Everything else an extension does goes through `host.*`.

**Budget:** every call the host makes into an extension (a command, an event handler, a callback) gets one instruction budget, shared by all of the extension's coroutines. Once it is spent the call ends with "execution budget exceeded"; `pcall`, `xpcall` and `coroutine.resume` cannot catch that, a message handler or a `__close` handler cannot run past it, and the next call starts with a full budget. `setmetatable` refuses a metatable with a `__gc` field (finalizers are refused), and `collectgarbage` only reports: `collectgarbage("count")` and `collectgarbage("isrunning")` answer, every other option does nothing and returns 0.

**Main-thread budgets:** Lua the host runs on the main thread has smaller budgets: loading an extension (each host bootstrap chunk and the entry chunk) 500,000 instructions, a launcher command (calc, units) 500,000, a bare call (snippet placeholders, the event-tap probe) 1,000,000, an event-tap dispatch 500,000; everything on the extension's background lane gets 10,000,000. An entry chunk past its load budget leaves only that extension's main-thread features off (launcher command, placeholders, event taps); the error is logged, nothing is shown.

**Memory:** each extension runtime has a memory limit of 256 MiB. A call that would go past it fails with "not enough memory" (a script can catch that with `pcall`), and the runtime stays usable for the next call. The host finds an extension's entry points (commands, event handlers, callbacks) only as plain globals: a name that only an `__index` metamethod on `_G` would serve is not found, and registering a host function does not run a `__newindex` on `_G`.

**Keystroke path:** fully native and **keyCode-indexed** ([`ExtensionKeyRules.swift`](app/Sources/ProsperApp/Extensions/ExtensionKeyRules.swift)) — a keypress only scans rules bound to that key (≈0–2), budgeted under 5 µs and typically a few hundred ns. **No Lua runs in the keystroke path** (the one opt-in exception is raw event taps, §5).

---

## 5. Stateless background extensions (system automation)

Not every extension is a palette command. Prosper drives the kind of system automation people reach for Hammerspoon to do — global hotkeys, key remaps, app launchers, screen/power control, filesystem watches — on a **stateless event model**: by default there is no resident VM holding live closures. The host owns every watcher (timers, key taps, FSEvents, the menubar); when something happens it spins a short-lived runtime, runs **one named Lua handler**, and tears it down. Durable state lives in `host.prefs`; durable timers in the scheduler; native resources (key rules, watches, power assertions) in the host.

**Subscribe to a native event** in the manifest — the handler is a Lua global invoked with a JSON payload pre-decoded to a Lua table:

```toml
[[contributes.events]]
event   = "system.launch"   # the place to install key rules / filesystem watches
handler = "install_rules"
```

| Event | Payload | When |
| ----- | ------- | ---- |
| `system.launch` | — | at startup, and again each time the extension is switched back on or a built-in one is reset |
| `system.wake` | — | wake from sleep |
| `system.sleep` | — | machine about to sleep |
| `screen.locked` | `{ locked }` | screen locked / unlocked |
| `clipboard.changed` | `{ kind, text }` | something was copied — `kind` is `text`/`image`/`file`, `text` present only for `text` and capped at 8 KB (call `host.clipboard.read()` for the whole clip) |
| `battery.changed` | — | power source / level change |
| `network.changed` | — | reachability change |
| `app.activated` | `{ bundleID, name, pid }` | frontmost app change |
| `lid.changed` | — | clamshell open/close |
| `url.open` | `{ url }` | a link opened while Prosper is the default browser. Every listener is asked in turn; a handler that opened the link returns the string `"handled"`. If none does (it returns nothing, declines, errors or runs out of time), Prosper opens the link in the saved fallback browser, so a handler that opens the link must return `"handled"` or the link opens twice |
| `timer.fired` | `{ id }` | a scheduled `host.timer` fired |

A `system.launch` handler must be safe to run more than once: schedule timers by id, set key rules and menu items as a whole, and rebuild state from `host.prefs` rather than counting runs.

A native watcher stays dormant until at least one **enabled** extension subscribes. [`openlid`](app/Sources/ProsperApp/Resources/extensions/openlid/) subscribes to `system.launch`/`battery.changed`/`network.changed`/`system.wake`/`lid.changed`; [`inputswitch`](app/Sources/ProsperApp/Resources/extensions/inputswitch/) to `app.activated`; [`url-dispatcher`](app/Sources/ProsperApp/Resources/extensions/url-dispatcher/) to `url.open` and (behind its `clean_copied` toggle) `clipboard.changed`; [`clipclear`](app/Sources/ProsperApp/Resources/extensions/clipclear/) to `system.launch`/`clipboard.changed`/`system.sleep`/`system.wake`/`screen.locked`; [`appupdates`](app/Sources/ProsperApp/Resources/extensions/appupdates/) to `system.launch` (to arm its durable poll timer).

`clipboard.changed` is the one with a running cost: it needs the pasteboard poll, which
otherwise only runs when clipboard history is on. Subscribing starts it (history stays
off, and nothing is written to the history store). Concealed/transient clips —
passwords, OTPs — never reach a handler. A `host.clipboard.write()` from a handler does
**not** re-fire the event, so writing back the cleaned-up value cannot loop.

**Durable named-handler timers** survive relaunch and re-invoke a global by name (no live closure):

```lua
host.timer.schedule{ id = "nightly", every = 86400, handler = "on_nightly" }  -- repeating
host.timer.schedule{ id = "once",    after = 120,   handler = "on_soon" }      -- one-shot
host.timer.cancel("once")
host.timer.scheduled("once")  -- true while this extension's timer "once" is scheduled (false once a one-shot fired or after cancel)
```

**Raw event taps (opt-in resident VM).** The one exception to the no-live-closures rule: set `event_taps = true` under `[extension.host]` and `hs.eventtap.new(keyDown|systemDefined, fn)` callbacks run synchronously on the keystroke, holding a live closure in a resident VM. The host builds that VM **lazily** (only if your config actually `:start()`s a tap) and evicts it when the extension is disabled, so a config with no taps costs nothing. The callback is on the key path — keep it cheap; for pure remaps/swallows the native key-rule engine (§ Key rules) is faster and needs no Lua per press. Implementation: [`EventTapHost.swift`](app/Sources/ProsperApp/Extensions/EventTapHost.swift); worked example: [`hammerspoon-compat`](app/Examples/extensions/hammerspoon-compat/).

---

## 6. Snippets & placeholders

The native snippet engine ([`snippets`](app/Sources/ProsperApp/Resources/extensions/snippets/)) expands keywords to text with dynamic placeholders (dates, clipboard, arguments). An extension can **supply its own placeholder token**:

```toml
[[contributes.placeholders]]
name    = "weather"     # token, without braces: {weather}
title   = "Weather"
handler = "fill_weather" # Lua global invoked with the raw token spec, returns the substitution
```

The full snippet store is also scriptable via `host.snippets.*` (§3) — that is how the Snippets settings pane manages entries.

---

## 7. Themes

An extension can contribute a **theme** — no Lua, just a manifest entry and a flat JSON palette. [`theme-amber`](app/Sources/ProsperApp/Resources/extensions/theme-amber/) is the worked example ([`theme-default`](app/Sources/ProsperApp/Resources/extensions/theme-default/) is the baseline).

```toml
[[contributes.themes]]
id         = "com.example.amber"
title      = "Amber Terminal"
path       = "theme.json"   # relative to the extension dir
appearance = "dark"         # "dark" (default) | "light" — selector hint
```

```json
{
  "appearance": "dark",
  "colors": {
    "blue": "#FFB000", "blueBright": "#FFD166", "indigo": "#FF7A1A", "magenta": "#FF4D6D",
    "terminal": "#FFE08A", "bgTop": "#14100A", "bgBottom": "#0B0905", "sidebar": "#0F0C07",
    "card": "#1E1810", "cardHi": "#2A2216", "textPrimary": "#F5ECDD", "textSecondary": "#B8A98C"
  }
}
```

Every token has a **role**, and the app colors by role — a theme that ignores them still
renders, it just renders wrong (an error message the same color as a heading, a success
checkmark in red):

| Token | Role |
| ----- | ---- |
| `blue` | The everyday accent — links, selection, focus rings, the active tab. The theme's identity. |
| `blueBright` | A lighter `blue` for glows, hovers, and the selected checkmark. |
| `indigo` | The second voice — decorative gradients and secondary chrome. Give it its own hue, not a tint of `blue`. |
| `magenta` | **Alert**: errors, warnings, destructive buttons, muted state. Must be tellable apart from `blue` at a glance — in a red or pink theme, push it toward orange rather than matching the accent. |
| `terminal` | **Success**: confirmations, "connected", "supporter", agent output. Reads as positive — green in every built-in theme but Amber. |
| `bgTop` / `bgBottom` / `sidebar` | Window ground, top to bottom, plus the sidebar. |
| `card` / `cardHi` | Panel surfaces: resting and elevated/hover. Keep them a step off `bgTop` so panels read as panels. |
| `textPrimary` / `textSecondary` | Body and muted text. Both need WCAG AA (4.5:1) against every surface token: `bgTop`, `bgBottom`, `sidebar`, `card` and `cardHi`. |

`ThemeTests.testBundledThemeAccentsAreDistinguishable` enforces the two rules that are easiest
to break by accident: no two bundled themes of the same appearance may share an accent, and
`magenta` may never collapse onto `blue`.

### Tints (`variants`, `tintLabel`)

A theme can offer a few accent **tints** of itself. Settings → Appearance → Theme shows them as
dots on the theme's row: the base palette first, then each variant in file order. One click on
a dot selects the theme with that tint; Prosper remembers the tint per theme on this Mac.

```json
{
  "appearance": "dark",
  "colors": { "blue": "#E0FF00", "blueBright": "#F0FF80", "indigo": "#66C2FF", "...": "..." },
  "tintLabel": "Lime",
  "variants": [
    { "key": "cyan",  "label": "Cyan",  "colors": { "blue": "#00E5FF", "blueBright": "#8CF4FF", "indigo": "#A98BFF" } },
    { "key": "amber", "label": "Amber", "colors": { "blue": "#FFB000", "blueBright": "#FFD166", "indigo": "#66C2FF" } }
  ]
}
```

- `tintLabel` (optional) names the base palette's tint on its dot. Labels lose control and
  invisible characters and are cut at 32 Unicode scalars; "Default" when nothing usable is left.
- `variants` (optional) is an ordered list of at most **5** entries. Each has a `key` (1 to 24
  bytes of `a-z`, `0-9` and `-`, unique within the theme), a `label` (the dot's name, cleaned and
  cut the same way; the key when nothing usable is left) and `colors`.
- A variant's `colors` may set **only the accent family**: `blue`, `blueBright` and `indigo`.
  Keys it omits keep the base value. Grounds, cards, text, `magenta` and `terminal` always stay
  the theme's, so a tint never changes what an error or a success looks like.
- The list is all or nothing: any other color key, a bad hex, a malformed or duplicate key, a
  sixth variant or an entry without `key` or `colors` refuses the **whole list**. The theme
  still loads with its base palette and no dots; the reason is logged (subsystem `com.prosper`,
  category `theme`).
- A remembered tint the theme no longer declares (renamed, removed, or the list was refused)
  falls back to the base palette without an error.
- Every tint of a bundled theme must pass the same rules as the base: `magenta` tellable from
  each tint's `blue`, the tints of one theme tellable from each other, and `blue`, `blueBright`
  and `indigo` at WCAG AA (4.5:1) against every surface token and against the top of the
  sidebar, where 6 percent of the tint's `blue` is laid over `sidebar`. Tints never count as a
  collision with another theme's accent. The check reads opaque colours only: it cannot see
  text on a translucent fill or behind Frost, where the surface is the blurred desktop, so
  check those by eye.

Pick a theme in **Settings → Appearance**; the whole app (and the AppKit menu-bar / dock chrome) redraws instantly. Missing tokens fall back to the default palette, so a partial palette is valid. Selecting a theme **never spawns the extension's Lua VM** — it is pure declarative data.

---

## 8. Settings sections

An extension can contribute its own pane to **Settings → Extensions** — a static **Tier-A** spec (host-rendered, host-persisted to `host.prefs`) and/or a **Tier-B** dynamic render hook. Models: [`ExtensionSettingsModel.swift`](app/Sources/ProsperApp/Extensions/ExtensionSettingsModel.swift).

```toml
[[contributes.settings_sections]]
id        = "my-ext"
title     = "My Extension"
icon      = "hammer.fill"
accent    = "Links"       # tints the trailing word of rows neon
subtitle  = "Configure the thing"
placement = "sidebar"     # "sidebar" (own entry, default) | "inline" (within Extensions list)
dynamic   = true          # deliver row events to settings_action so you can react live
```

The section id `kit` is reserved: an Agent Kit extension's own Settings tab uses it. See [Agent Kits](#12-agent-kits). A section with that exact id is ignored and a warning is logged, and the rest of the extension loads.

**Tier-A** — static `[[contributes.settings_sections.controls]]` rows, no Lua. **Tier-B** — Lua renders the rows:

```lua
-- settings_render(section_id, state) returns the row tree; settings_action(id, value, formValues)
-- handles a row event (toggle flip, button tap) when the section is dynamic.
function settings_render(_, _)
    return host.ui.settings.render(host.ui.settings.ui {
        sections = {
            host.ui.settings.section {
                id = "my-ext",
                rows = {
                    host.ui.settings.row { kind = "toggle", key = "enabled", title = "Enabled" },
                    host.ui.settings.row { kind = "permission", name = "accessibility",
                                           title = "Accessibility (required)" },
                    host.ui.settings.row { kind = "info", title = "Status", subtitle = "…" },
                },
            },
        },
    })
end
```

Row `kind`s: `group`, `toggle`, `text`, `secret`, `number`, `stepper`, `enum` (with `values`/`value_labels`), `path`, `info`, `permission` (Granted/Not-granted badge with **Open** + **Re-check** wired to `host.perms`), `button`, and `link`. A `records{ … }` block renders an add/remove list ([`quicklinks`](app/Sources/ProsperApp/Resources/extensions/quicklinks/), [`quickdirs`](app/Sources/ProsperApp/Resources/extensions/quickdirs/), [`snippets`](app/Sources/ProsperApp/Resources/extensions/snippets/) manage their entries this way). A global shortcut bound to a host `ShortcutAction` is not a settings-panel row at all — it just shows up automatically in **Settings → Shortcuts**. `shortcut` is still accepted as a `kind` for manifests written before this changed, but it no longer renders anything — drop it from new manifests.

Control fields include `key` (the `host.prefs` key), `default`, `placeholder`, `footer`, `min`/`max`/`step`, `style` (`"neon"` | `"borderless"` | `"destructive"`), `action` (button verb: `"reveal"` | `"open-url"` | `"lua"`), `url`/`file`, `name` (permission), and `visible_when` (a pref key that gates the row's visibility).

A `dynamic = true` section delivers every row event to `settings_action`, so a toggle can **install/tear down rules live** instead of silently writing a pref. Worked examples: [`hammerspoon-compat`](app/Examples/extensions/hammerspoon-compat/) (permission row + live "what's loaded" diagnostics), [`inputswitch`](app/Sources/ProsperApp/Resources/extensions/inputswitch/) (default-input picker + per-app override list), [`fallback-search`](app/Sources/ProsperApp/Resources/extensions/fallback-search/) (append-mode toggle + editable provider list + "Import from default browser").

---

## 9. The automation surface & the trust tiers

Side-effecting host calls form two tiers above the open reads:

- **Automation tier** — hotkeys/key-rules, app launch/hide/focus, `osascript`, keyboard-source set, default-browser set, `host.http`, file reads (`host.fs.read`, any path except the secret paths below), filesystem watches, power/caffeinate, menubar/dialog/alert. Granted to bundled **system extensions** *and* to marketplace/user extensions you have **trusted**.
- **System-only tier** — `host.shell.run`, `host.process.run`, the coding agent, reading the secret paths below, `host.fallback.*`, and destructive file ops (trash). Reachable by a **system extension**, *or* **any extension you grant System Access** (§ below).

**Secret paths.** Below the system tier, `host.fs.read`, `host.fs.exists`, `host.fs.attributes`, `host.fs.list_dirs`, `host.fs.watch` and `host.files.search` treat these as missing, each with everything inside it: `~/.ssh`, `~/Library/Keychains`, `~/.ccpool`, `~/.config/mcpbridge`, `~/.claude/settings.json`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.git-credentials`, `~/.npmrc`, `~/.config/gh`, `~/.config/gcloud`, `~/.kube`, `~/.docker/config.json`, `~/.claude.json`, `~/.claude/.credentials.json`, `~/.config/prosper/device.key`, `~/.config/prosper/supporter.dat`, and the folder named by `CCPOOL_HOME` when Prosper was started with it set (a relative value counts from Prosper's working directory, as ccpool reads it; a value starting with `~` is also protected under your home folder). The answer is the same as for a path that does not exist, also when the path goes there through a symlink, `..` or different letter case. A listing of a parent folder does not name them, and a watch on it does not report changes inside them. A refusal writes one line to Prosper's log, naming the extension and the call (never the path), once per path while the extension stays loaded. The list is `SecretPaths` in [`ExtensionFSWatch.swift`](app/Sources/ProsperApp/Extensions/ExtensionFSWatch.swift). It is not a sandbox: `host.osascript` can still run shell (see the warning below).

**Granting System Access to any extension.** The privileged tier is not reserved for bundled extensions. **Any extension — including one you wrote or installed from the Marketplace — can be elevated to the system tier.** Trust it first, then click **Grant System Access** on it in Settings → Extensions. The gate is exactly `record.privileged = record.isSystem || (record.trusted && granted)` ([`ExtensionRegistry.swift`](app/Sources/ProsperApp/Extensions/ExtensionRegistry.swift), persisted in `privilegedExtensionIDs`) — so a granted user extension calls `host.shell.run`, the coding agent, and the destructive surface identically to a bundled one. It is a deliberate escalation (a granted config runs **any command as you**), default off, per-extension, and revocable — revoking or untrusting tears the VM down. [`hammerspoon-compat`](app/Examples/extensions/hammerspoon-compat/) is the worked example: trusted it gets only automation (`hs.execute` is refused); after Grant System Access its `hs.execute` runs real shell.

For an **untrusted, non-system** extension every side-effecting call is an inert no-op (a refused `host.shell` returns `"error: host.shell is restricted to system extensions"`). A bare untrusted extension never executes at all. Gating logic: `automation = privileged || trusted` in [`ExtensionHostAPI.swift`](app/Sources/ProsperApp/Extensions/ExtensionHostAPI.swift).

A background call still running when its extension is turned off, untrusted, reset, reinstalled or removed can still read private data (the clipboard, files), but every outward channel (writes, commands, network, UI, holds and the `host.llm` functions) answers it with its usual decline value and does nothing; only `host.log` is left, as for a live call (`retiredReads` and `retiredRefusals` in [`ExtensionHostAPI.swift`](app/Sources/ProsperApp/Extensions/ExtensionHostAPI.swift)).

> ⚠️ **Trusting a config is not a full sandbox.** `host.osascript` is in the automation tier and AppleScript can `do shell script`, so a trusted config can run shell indirectly. Only trust configs you have read end-to-end. Granting System Access lets a trusted config run **any command as you** — a deliberate escalation; default is off.

### Automation calls

- `host.apps.search(query)` · `host.apps.launch_or_focus(name|bundleID)` · `host.apps.hide(bundleID)` · `host.apps.frontmost()` → `{ bundleID, name, pid }` · `host.apps.windows(bundleID)` → window count (Accessibility; 0 without the a11y grant)
- `host.osascript.run(source)` → `{ ok, output, error }` — AppleScript / JXA bridge
- `host.keyboard.current_source()` → input-source id · `host.keyboard.layouts()` → `{ { id=, name= }, … }` · `host.keyboard.set_source(id)` → bool (Carbon TIS)
- `host.keys.set_rules{ … }` — install the per-extension **key-rule** set (replaces the prior set; see § Key rules). `host.keys.stroke(spec)` injects a chord; `host.keys.system(name)` injects a media/aux key (`PLAY NEXT PREVIOUS FAST REWIND MUTE SOUND_UP SOUND_DOWN BRIGHTNESS_UP BRIGHTNESS_DOWN ILLUMINATION_UP ILLUMINATION_DOWN`). Injected events are tagged so they never re-enter the tap (no loops).
- `host.url.open(url [, bundleID])` → bool — open a URL (optionally in a specific browser); true when macOS accepted it (a `url.open` handler returns `"handled"` only then) · `host.url.default_browser()` → bundle id of the current http handler · `host.url.set_default_browser(id)` → bool
- `host.fs.watch(path, "handler")` — fire a named handler with `{ paths = {…} }` on change · `host.fs.unwatch(path)` ([`ExtensionFSWatch.swift`](app/Sources/ProsperApp/Extensions/ExtensionFSWatch.swift))
- `host.fs.read(path)` → string | nil — read a UTF-8 text file (up to 1 MiB) at any path except the secret paths above; nil when it is missing, too big, not text, or (below the system tier) a secret path
- `host.caffeinate.prevent_idle_sleep(kind, on)` (`kind` = `"display"`|`"system"`) · `host.caffeinate.set_disable_lid_sleep(on)` · `host.caffeinate.set_remote_wake{ enabled=, interval_ac=, interval_batt=, battery_floor=, device_id= }` · `host.caffeinate.lock_screen()` · `host.caffeinate.start_screensaver()` · `host.caffeinate.sleep_now()` (release every keep-awake hold and sleep). Worked example: [`openlid`](app/Sources/ProsperApp/Resources/extensions/openlid/).
- `host.menubar.set{ id=, title=, icon=, menu={ {title=, handler=, payload=, enabled=, checked=, stay=} | {separator=true} } }` · `host.menubar.remove(id)` ([`ExtensionMenuBar.swift`](app/Sources/ProsperApp/Extensions/ExtensionMenuBar.swift)). A row with no `handler`, or `enabled=false`, is disabled; `stay=true` runs the handler on a click without closing the menu (Return still closes it), and the re-rendered menu updates in place (worked example: [`openlid`](app/Sources/ProsperApp/Resources/extensions/openlid/)) · `host.dialog.{prompt,confirm}` · `host.alert.show(text [, seconds])` — host-rendered UI
- `host.dch.sessions()` → `{ {name=, alias=, active=}, … }` — live remote-terminal sessions (drives the OpenLid status readout)
- `host.ccpool.status()` → `{ running=, port=, current=, accounts = { {label=, state=, until=}, … } }` — the Claude Account Pool, read-only and label-level; open to every extension (no trust or System Access needed). `state` is `active`, `ready`, `limited`, `held` or `refused`; `until` (epoch seconds) is set for `limited` and `held` only; `current` is the label in use, or absent. It never carries a token, an account id or a header value. When the pool was never built (it is off, or not started yet) it answers `{ running = false, port = 0, accounts = {} }`, so `host.ccpool.status().accounts` is always a table. A routed `claude` session keeps its own API keys and tokens: the pool sets only `ANTHROPIC_BASE_URL`.
  - Hold and Release without the pane, from the same Mac: a POST to the pool's proxy port (8790 unless changed), loopback only. The `x-ccpool-control: 1` header is required and a request carrying an `Origin` header is refused (403), so a web page cannot do it. The answer is that account's `{label, state, until}` as above; 404 for an unknown label, 400 for a missing label or hours that are not a number above zero, 405 for GET.
    ```sh
    curl -X POST -H 'x-ccpool-control: 1' 'http://127.0.0.1:8790/ccpool/hold?label=work&hours=5'
    curl -X POST -H 'x-ccpool-control: 1' 'http://127.0.0.1:8790/ccpool/clear?label=work'
    ```

### System-only calls

- `host.shell.run(cmd [, { keep_running = true }])` → output, truncated, state — arbitrary command execution through the login shell (stdout + stderr, trimmed). Output is capped at 64 MiB; `truncated` is `true` when the cap was hit, else `nil` (the text itself is never marked). `state` says how the command ended: `{ type = "exit", code = <exit status> }` (so success is `state.type == "exit" and state.code == 0`), `{ type = "signal", code = <signal number> }` when it was killed by a signal, `{ type = "timeout" }` when the host killed it at the call timeout, `{ type = "running" }` when `keep_running` handed control back at the timeout and the command goes on. When nothing ran (a blank `cmd`, the shell could not be started, or the extension is below the system tier) there is no `state`: the call returns the output alone (and `true` if truncated). On the host call timeout the command's whole process group is killed and `""`, `nil`, `{ type = "timeout" }` is returned; with `keep_running = true` the call still returns `""` at the timeout (state `running`) but the command runs on to completion (for upgrades, user scripts, file moves). `opts` must be `nil`, `false` (same as `nil`, so `cond and { keep_running = true }` works) or a table whose only key is `keep_running` (a boolean); anything else raises a Lua error. An unknown key is named in it; a non-table `opts` or a non-boolean `keep_running` is reported by the type of the bad value (`got string`). Never pass `host.shell.run(x)` as the last argument of a call or inside `{...}` unless the callee wants all three values: the second return (`nil` or `true`) and the state spill in as extra arguments or elements. Wrap it in parentheses, `f((host.shell.run(x)))`, or assign it to a local first.
- `host.fs.read(path)` on the secret paths above
- `host.fallback.*` — fallback-search provider list/save/mode/import ([`fallback-search`](app/Sources/ProsperApp/Resources/extensions/fallback-search/) owns the settings UI; per-keystroke row building is native)
- the coding agent and destructive file ops (trash)

### `host.process.run`

Runs one program directly, with no shell. System tier only (§ above).

```lua
local r = host.process.run{ argv = { "/usr/bin/git", "status", "--short" }, timeout = 5, max_bytes = 65536 }
if r.ok then host.log.info(r.stdout) else host.log.warn(r.error or ("exit " .. tostring(r.status))) end
```

**Takes** one table:

| Key | Meaning |
| --- | ------- |
| `argv` | Required. A list of strings. `argv[1]` is the program, the rest are its arguments, passed as they are (no quoting, no globbing, no `~`). At most 1024 entries; a NUL byte in an entry is an error. |
| `timeout` | Seconds. Default 5, at most 10 (a larger value is cut to 10, a negative one to 0). A value that is not a finite number means the default. |
| `max_bytes` | Cap per stream, in bytes. Default and maximum 1 MiB; a larger value is cut to 1 MiB, a negative one to 0. |

Any other key is a Lua error naming it, as is an `argv` that is not a list, an entry that is not a string, or an entry with a NUL byte.

**Returns** `{ ok, status, stdout, stderr, timed_out, truncated [, error] }`. `ok` is true only when nothing refused the call, it did not time out, and `status` is 0. `status` is the exit code; a program killed by a signal reads as 128 plus the signal, as in a shell. `truncated` is true when either stream went past `max_bytes` (the rest is read and thrown away, so the program is never blocked on a full pipe). A refusal sets `error` (it starts with `host.process.run: `) and runs nothing.

**What is refused** (in `error`, not raised): a missing `argv[1]`, a path that is not absolute, does not exist, is not a regular file or is not executable, a program that fails to start, a call from an extension below the system tier, an extension with no directory, and a third program while two are already running.

**Limits, as the code has them:**

- `argv[1]` must be an absolute path to an existing, regular, executable file. There is no `PATH` lookup. Run a shell (`/bin/sh`, `-c`) only if you want one; `host.shell.run` is the shell call.
- The environment is fixed: `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`, `LANG=en_US.UTF-8`, and nothing else. Stdin is `/dev/null`. The working directory is the extension's own folder.
- At most **two** programs run at once, for the whole app. A third is refused at once, it does not wait.
- At the timeout, the program's whole process group gets SIGTERM, and SIGKILL one second later. `timed_out` is true. The call returns by about 2.5 seconds after the timeout at the latest, even if a child that left the group still holds a pipe.
- The same group kill runs when the call is dropped (an X-ray ref card dropped for a newer one or timed out, § 13) and when Prosper quits. A program that ends by itself but leaves members of its group behind has them killed too.
- A call that is still running when the extension is turned off, untrusted, reset, reinstalled or removed is answered with `ok = false` and `error = "host.process.run: this call was stopped"`.

### Managed config (`host.config`)

A **trusted** extension (a kit) can add owned pieces to Claude Code's config: a marked block in a Markdown or shell-style file, a hook, a permission rule, the status line, or a seeded starter file. Prosper writes only after **you** approve the exact change in a native sheet, keeps a backup of every file first, and can take every piece back out. For an untrusted extension all five calls are inert: `plan` and the write calls answer `ok = false`, and `status` answers `{}`.

The owner of every piece is the calling extension's id. It is never read from the arguments: a piece cannot name another extension, and `status` shows only your own pieces.

```lua
local pieces = {
  { id = "rules", kind = "block", target = "claude:CLAUDE.md", text = "Follow the kit rules.", position = "bottom" },
  { id = "pre", kind = "json", target = "claude:settings.json", path = { "hooks", "PreToolUse" }, op = "append",
    value = { matcher = "Bash", hooks = { { type = "command", command = "kit-run pre" } } } },
  { id = "perms", kind = "json", target = "claude:settings.json", path = { "permissions", "allow" }, op = "union", value = { "Bash(kit-run:*)" } },
  { id = "status", kind = "json", target = "claude:settings.json", path = { "statusLine" }, op = "set", value = { type = "command", command = "kit-status" } },
  { id = "local", kind = "seed", target = "kitconfig:local.md", source = "ext:local.md" },
}
host.config.plan{ pieces = pieces }   -- -> { ok, files = { { target, path, backup, diff, notes, new_file, deletes_file } }, pieces = { { id, action } }, refused = { { id, target, why } } }
host.config.apply{ pieces = pieces }  -- -> { ok, status, applied = { ids }, removed = { ids }, refused, pieces, message }
host.config.status{ pieces = pieces } -- -> { { id, state, target, path, repair } }, or { error = "state_unreadable", message }
host.config.remove{ ids = { "pre" } } -- or { all = true }
host.config.repair{ all = true }      -- or { ids = { … } }, or { pieces = pieces }: also takes a block Prosper has no record of
```

- **`plan`** never writes and never asks. Its `diff` holds only the added and removed lines; the unchanged lines around them are the user's own text and appear only on the consent sheet. **`apply`**, **`remove`** and **`repair`** show the consent sheet: the masked diff, the backup folder, and a sentence per hook and status line. A change to `claude:settings.json` notes that it applies to open Claude Code sessions at once. **Cancel** writes nothing and answers `ok = false, status = "denied"` with empty `applied`, `removed` and `pieces`. Nothing is remembered: the next change asks again.
- If a file changes on disk while the sheet is up, Prosper plans again. When the new change set differs, it shows the sheet a second time. Cancelling it keeps any file already written under the first one, and the answer lists only those pieces.
- The write calls wait for your answer, so call them from an **async handler** (or any off-main lane). A write call made on the main thread answers `ok = false` and writes nothing. After 5 minutes with no answer, the call gives up and writes nothing; a later Apply counts as Cancel.
- **Targets.** `claude:` is Claude Code's config dir (`CLAUDE_CONFIG_DIR` from your login shell, else `~/.claude`). `kitconfig:` is `~/.config/<your manifest name>/`; Prosper creates that dir and marks it with a `.prosper-kit` file. `ext:` (seed sources only) is your extension's own dir, read-only. `..`, absolute paths, `settings.local.json`, paths that differ only by letter case, and the `.prosper-kit` file are refused.
- **Blocks** go in `claude:<name>.md`, or in `kitconfig:` files ending in `.md`, `.markdown`, `.sh`, `.bash`, `.zsh`, `.fish`, `.conf`, `.toml`, `.yaml` or `.yml`. Any other extension is refused, because the block markers need a known comment syntax.
- **JSON** pieces target `claude:settings.json` only. Only these paths are allowed: `hooks.<event>` with `append`, for the 33 events Claude Code documents (an unknown event is refused); `permissions.allow`, `deny`, `ask` and `additionalDirectories` with `union`; `statusLine` with `set`; `permissions.disableBypassPermissionsMode` with `set`, to the string `"disable"` only; and `env.<key>` with `set`, to a string, for the keys of the env allowlist in section 12 only. The bypass slot and the `env` keys are open to an agent kit only: an extension's own pieces are refused both. Every other `env` key, `apiKeyHelper`, `model`, `disableAllHooks`, a top-level `disableBypassPermissionsMode` and `permissions.defaultMode` are always refused. Two of your pieces cannot both `set` the same path.
- **Status states:** `applied`, `drifted` (someone edited it), `missing`, `replaced`, `corrupt`, `unwritable`, `conflict`, `adopted` and `orphaned` (the extension is gone). Remove still works on orphaned pieces.
- **Uninstall** of an extension with live pieces shows the Remove sheet first. If you cancel it, the extension and its config both stay. An extension that never wrote a piece uninstalls even when Prosper cannot read `CLAUDE_CONFIG_DIR` from your login shell; one with pieces waits until it can. If Prosper's own record (`~/Library/Application Support/Prosper/managed-config/state.json`) is damaged or from a newer Prosper, no uninstall goes ahead, because nothing can tell which pieces are whose: update Prosper, or move that file aside, after which uninstall works and any pieces stay in your files as plain text to delete by hand. A block of the extension that is in a file but missing from that record is handled before the sheet: when it is byte for byte what the extension last declared, uninstall records it (in Prosper's own state file, as the extension's `status` call does) and the Remove sheet then takes it out; when it was edited, uninstall goes on and leaves that block in its file untouched. Extensions settings then names each block left and its target (up to five, then a count), until you dismiss the notice; delete such a block by hand if you no longer want it. A disabled extension declares nothing, so blocks it leaves this way are not named.
- Known limits:
  - A write replaces the file by rename. This drops its group, ACLs and extended attributes, and splits any hard link.
  - A symlinked target is written through to the real file.
  - If Prosper crashes between a write and saving its state, seeded files and `union` strings stay in place but no piece owns them.
  - Two Prosper processes are not locked against each other.
  - A `position = "top"` block goes above a shebang or front matter.

### Key rules

Each rule matches a chord **exactly** on modifiers (`"f8"` fires on a bare F8, never cmd+F8) and takes exactly one action:

| Field | Effect |
| ----- | ------ |
| `to = "cmd+alt+i"` | rewrite the chord into another chord (host injects the target) |
| `system = "PLAY"` | inject a media/aux key (case-insensitive) |
| `double_tap = "cmd+q"` | swallow a lone press; a second press within ~0.4 s injects the target |
| `swallow = true` | drop the keystroke entirely |

Scope a rule with `apps = { … }` (allow-list) or `not_apps = { … }` (deny-list) of frontmost bundle ids. Allow-list rules never fire when the frontmost app is unknown. Install rules from a `system.launch` handler — they live natively in the host's key engine from then on:

```lua
function install_rules()
    host.keys.set_rules{
        { from = "f8",    system = "PLAY" },
        { from = "cmd+e", to = "cmd+alt+i", apps = { "com.apple.Safari" } },
        { from = "cmd+q", double_tap = "cmd+q" },   -- press ⌘Q twice to quit
    }
end
```

Worked examples: [`url-dispatcher`](app/Sources/ProsperApp/Resources/extensions/url-dispatcher/) and [`hammerspoon-compat`](app/Examples/extensions/hammerspoon-compat/). User-facing key/media/app shortcuts live natively in **Settings → Shortcuts → Key Mappings** — no hard-coded combos; configure your own, including remapping/swallowing *incoming* media keys. They feed the same `host.keys.set_rules` engine under the reserved owner `com.prosper.shortcuts` ([`ShortcutRulesStore.swift`](app/Sources/ProsperApp/Extensions/ShortcutRulesStore.swift)).

---

## 10. Bundled (system) extensions

Bundled features ship as **system extensions**: editable and disablable, **resettable to original**, but never uninstallable. On launch they are *copied* into `~/.config/prosper/extensions` (missing folders only — never clobbering your edits) and loaded from there, so you can open any in your editor and change it live. **Reset to original** re-copies the pristine bundled version. All live under [`app/Sources/ProsperApp/Resources/extensions/`](app/Sources/ProsperApp/Resources/extensions/):

| Extension | What it does | Notes |
| --------- | ------------ | ----- |
| [`calc`](app/Sources/ProsperApp/Resources/extensions/calc/) | Inline calculator | |
| [`units`](app/Sources/ProsperApp/Resources/extensions/units/) | Unit conversion | Temperature stays native (Foundation's affine °F constants can't be reproduced byte-for-byte in Lua) |
| [`base64`](app/Sources/ProsperApp/Resources/extensions/base64/) | Base64 encode/decode | `host.ui.converter` example |
| [`currency`](app/Sources/ProsperApp/Resources/extensions/currency/) | Currency conversion | `host.http` + cache; off-main async lane example |
| [`translate`](app/Sources/ProsperApp/Resources/extensions/translate/) | Local-LLM translate | `requires = ["model"]`; `l `/`t ` prefixes |
| [`open`](app/Sources/ProsperApp/Resources/extensions/open/) | App launcher | `host.apps.search` |
| [`files`](app/Sources/ProsperApp/Resources/extensions/files/) | Find Files | `host.files.search{}` / `host.files.act` |
| [`shell`](app/Sources/ProsperApp/Resources/extensions/shell/) | Run shell commands | system-only `host.shell.run` |
| [`snippets`](app/Sources/ProsperApp/Resources/extensions/snippets/) | Snippet expansion | `host.snippets.*`, placeholders, `records` |
| [`quicklinks`](app/Sources/ProsperApp/Resources/extensions/quicklinks/) | Saved links | `records` list; palette command |
| [`quickdirs`](app/Sources/ProsperApp/Resources/extensions/quickdirs/) | Saved directories | `host.fs.list_dirs` |
| [`bookmarks`](app/Sources/ProsperApp/Resources/extensions/bookmarks/) | Browser bookmarks | Chrome/Brave/Edge/Vivaldi/Opera/Arc/Safari/Firefox/Zen; `full-disk-access` for Safari; `list_on_empty` |
| [`sysprefs`](app/Sources/ProsperApp/Resources/extensions/sysprefs/) | System Settings panes | `ss ` prefix, `list_on_empty`; 43 panes as `x-apple.systempreferences:` row URLs — pure Lua, no shell, no permissions |
| [`killproc`](app/Sources/ProsperApp/Resources/extensions/killproc/) | List processes by CPU, terminate one | `kill ` prefix; system-only `host.shell` (`ps`/`kill`) + `host.dialog.confirm`. Committed by a trailing `!` (`!!` = SIGKILL), never by Enter, because a prefixed command re-runs on every keystroke; pids validated `^%d+$`, names never interpolated, pid ≤ 1 / Prosper itself / a blocklist refused |
| [`scripts`](app/Sources/ProsperApp/Resources/extensions/scripts/) | Saved shell commands | `sc ` prefix, `list_on_empty`; system-only `host.shell` on the async lane + a `records` settings section over `host.prefs` |
| [`appupdates`](app/Sources/ProsperApp/Resources/extensions/appupdates/) | Pending Homebrew + macOS updates | system-only `host.shell`; no `prefix` on purpose — three `runs_on_select` rows. The palette shows the **cache**; the 10–60 s `softwareupdate -l` runs only on the 6-hourly durable timer or the explicit "Check now" |
| [`pasteplain`](app/Sources/ProsperApp/Resources/extensions/pasteplain/) | Paste with formatting stripped | No manifest keybinding — bindable to a chord in Settings › Shortcuts › Extension Commands, invoked without opening the runner, so the synthesized ⌘V lands in the frontmost app. Ceiling: the rich clip is *replaced*, not restored |
| [`clipclear`](app/Sources/ProsperApp/Resources/extensions/clipclear/) | Clipboard auto-clear | **opt-in** (`default_disabled`); `clipboard.changed` stamps the copy and arms a durable one-shot at its deadline (5 min default), so there is no timer while nothing is pending and one fire per clip; `system.wake` re-arms it from the wall clock (the host timer's clock stops in sleep), and a wipe cancels it; `system.sleep`/`screen.locked` wipe it outright; `clipclear.now` clears on demand. Not `system` — `host.clipboard`/`host.timer`/`host.prefs` are ungated |
| [`window`](app/Sources/ProsperApp/Resources/extensions/window/) | Window management | `host.window.frame/set`; 10 settings sections |
| [`openlid`](app/Sources/ProsperApp/Resources/extensions/openlid/) | Keep-awake / lid power | `host.caffeinate.*`; 5 events; `runs_on_select` toggles |
| [`url-dispatcher`](app/Sources/ProsperApp/Resources/extensions/url-dispatcher/) | Browser routing | **opt-in** (`default_disabled`); `url.open` event + key rules. Separate `clean_copied` toggle (off by default) subscribes to `clipboard.changed` and strips tracking params from a copied bare link in place — prose containing a link is left alone, and it only writes when the cleaned URL actually differs |
| [`inputswitch`](app/Sources/ProsperApp/Resources/extensions/inputswitch/) | Per-app keyboard input source | **opt-in**; `app.activated` event; `host.keyboard` |
| [`menubar`](app/Sources/ProsperApp/Resources/extensions/menubar/) | Ice/Bartender-style menu-bar control | **opt-in**; native footer pane |
| [`ccpool`](app/Sources/ProsperApp/Resources/extensions/ccpool/) | Claude Account Pool | **opt-in**; native footer pane, no Lua logic. The extension is the gate: while it is live and the pool lists an account, a loopback-only proxy rotates several Claude subscription accounts (tokens in the Keychain, never in a file). Turning it off stops the proxy and frees the port; a fresh install builds nothing, opens no file and binds nothing. The pane adds, holds, removes and imports accounts (one-time, from the Homebrew `ccpool`) |
| [`fallback-search`](app/Sources/ProsperApp/Resources/extensions/fallback-search/) | Web-search default results | settings UI only; native row building via system-only `host.fallback.*` |
| [`theme-default`](app/Sources/ProsperApp/Resources/extensions/theme-default/) · [`theme-amber`](app/Sources/ProsperApp/Resources/extensions/theme-amber/) · `theme-*` (dark: crimson, ember, gold, lime, emerald, teal, indigo, violet, rose, graphite, contrast-dark — light: daylight, fern, mint, solar, lavender, blossom, silver, contrast-light) | Color themes | declarative `theme.json`, no Lua |

The conversion engines keep a **native fallback**, so a disabled or edited extension never loses the feature.

> **Not bundled — the automation showcase:** [`hammerspoon-compat`](app/Examples/extensions/hammerspoon-compat/) ships under `app/Examples/`, installs **untrusted**, and demonstrates the full automation tier (loading an unmodified `~/.hammerspoon/init.lua` by shimming `hs.*` onto `host.*`). Read it as the end-to-end example of events, key rules, raw event taps, URL routing, durable timers, and a dynamic settings section.

---

## 11. Installing & distributing

**Everything lives in `~/.config/prosper/extensions`** — one editable directory. User extensions install there and remove freely; system extensions can't be uninstalled, only reset.

- **From GitHub** — paste a repo/subdir URL into **Settings → Extensions** (`github.com/owner/repo`, `…/tree/<ref>/<subdir>`, `.git`, `git@` forms all parse). Prosper fetches the tarball, validates `extension.toml`, installs. ([`RemoteInstaller.swift`](app/Sources/ProsperApp/Extensions/RemoteInstaller.swift))
- **Marketplace** — browse and one-click-install published extensions, or **Publish** your own, from **Settings → Extensions**. Manifests are signed (Ed25519) and verified on download; a freshly installed extension lands **untrusted** and runs only after you grant trust (install-then-trust gate), so privileged host APIs stay opt-in. ([`MarketClient.swift`](app/Sources/ProsperApp/Extensions/MarketClient.swift))
- **Agent Kits** — a packaged Claude Code setup (instructions, tools, hooks, status line, permissions, agents) installs the same ways but untrusted, is applied only after consent, and is listed under its own **Agent Kits** filter. See [Agent Kits](#12-agent-kits).
- **Hidden files stay out** — a file or folder whose name starts with a dot (`.DS_Store`, `.git`, a coding tool's state folder, macOS `._` metadata) is never published, and a GitHub or Marketplace install leaves out any that a download still carries. `*.test.lua` files and `tests` folders are not published either. A download that contains a symbolic link is refused.

## 12. Agent Kits

An **Agent Kit** is an ordinary extension that packages a Claude Code setup: instruction text, tools, hooks, a status line, permissions and agents. It carries a `[contributes.kit]` table next to `[extension]`, ships the same stub `init.lua` a theme does (`return {}`), and runs **no Lua**. Prosper's native Kit runtime reads the table and writes the pieces into the person's Claude Code files, after they say yes. A kit never edits `~/.claude` itself: every write goes through Prosper's managed-config layer and is undone by Remove.

A worked example lives in the repository: [`app/Examples/kits/hello-kit`](app/Examples/kits/hello-kit) (one rule, one hook, one tool, one setting).

### Layout

```
extension.toml      # [extension] + [contributes.kit]
init.lua            # stub, `return {}`
README.md           # required, see "The README contract"
CLAUDE.md           # instruction text, imported by a claude-md piece
tools/<name>        # executables, reached through Prosper-generated shims
hooks/<name>        # executables wired as Claude Code hooks
statusline/<name>   # executable wired as the statusLine
agents/<name>.md    # agent files
seed/<file>         # templates copied to ~/.config/<slug>/ once, never overwritten
```

### The manifest

Top-level keys of `[contributes.kit]`: `schema` (the integer `1`), `homepage` (optional, an `https://` link), `requires` (executables looked up on PATH, never run; at most 32), `pieces` (at most 64) and `settings` (at most 32). An unknown key anywhere is refused. The example's manifest, byte for byte:

```toml
[extension]
id          = "com.example.kit.hello"
name        = "hello-kit"
title       = "Hello Kit"
description = "A minimal Agent Kit: one rule, one hook, one tool and one setting."
version     = "1.0.0"
author      = "Example Org"
license     = "MIT"

[extension.host]
min_version = "2.175.0"
api_level   = 1

[extension.entry]
main = "init.lua"

[contributes.kit]
schema   = 1
homepage = "https://example.com/hello-kit"
requires = ["sh"]

[[contributes.kit.pieces]]
id       = "rules"
kind     = "claude-md"
source   = "CLAUDE.md"
position = "bottom"

[[contributes.kit.pieces]]
id    = "greet"
kind  = "hook"
event = "SessionStart"
run   = "hooks/hello-hook.sh"

[[contributes.kit.pieces]]
id   = "tools"
kind = "tools"
dir  = "tools"

[[contributes.kit.settings]]
key     = "greeting"
title   = "Greeting"
kind    = "string"
default = "Hello from hello-kit"
```

`name` is the kit's slug (`[a-z0-9-]+`) and names its config folder `~/.config/<slug>`; a second kit with the same slug is refused, and so is the reserved slug `prosper`.

### Piece kinds

Every piece has an `id` (`[a-z0-9-]+`, unique in the kit), a `kind`, the keys of its kind, and an optional `needs = ["<piece-id>"]`: the pieces it cannot work without (ids must exist, no cycle). Switching a piece off switches its dependents off, and the list is shown first.

| kind | Keys | Becomes | Off switch removes |
| --- | --- | --- | --- |
| `claude-md` | `source` (a `.md` file), `position` (`top` or `bottom`, default `bottom`) | a managed block in `~/.claude/CLAUDE.md` that imports the file | the block |
| `tools` | `dir` | one shim per executable file, in Prosper's own folder `~/.config/prosper/kits/<ext-id>/bin/` | the shims |
| `hook` | `event`, `matcher`, `run`, `timeout` (1 to 3600 s), `interpreter`, `on_error` (`"deny"` only) | one hook group appended under `hooks.<event>` in `~/.claude/settings.json` | that group |
| `statusline` | `run`, `interpreter` (at most one per kit) | the `statusLine` slot in `settings.json` | the slot, restored to what it was |
| `permissions` | `allow`, `deny`, `ask` (at most 64 rules in each), `disable_bypass` (`true` or `false`; at least one rule unless it is `true`) | the rules, added to `permissions.*` in `settings.json`; with `disable_bypass = true`, `permissions.disableBypassPermissionsMode` set to `"disable"` | the rules this kit added; the bypass slot, restored to what it was |
| `seed` | `from` | files copied into `~/.config/<slug>/` when missing | nothing: seeded files are the person's after the copy |
| `agents` | `dir` (default `agents`) | `<name>.md` files in `~/.claude/agents/`, byte for byte | the files, while they still hash as written |
| `env` | `vars`, a table of string values, keys from the env allowlist only (at least one) | each key set under `env` in `settings.json`; every key and value is listed before you say yes | each key, restored to the value you had (or removed when you had none) |
| `shell-path` | none (opt-in: off until the person switches it on) | one managed block at the bottom of `~/.zshrc` that appends `~/.config/prosper/kits/<ext-id>/bin` to `PATH` once, shown first and backed up | the block, leaving the file byte for byte as before |

Rules the validator enforces on every kit, local or Marketplace, with the reason shown on refusal:

- **Env allowlist (OQ-193).** An `env` piece may set only these keys, each to a string: `CLAUDE_AUTO_BACKGROUND_TASKS`, `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, `CLAUDE_CODE_DISABLE_AGENT_VIEW`, `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY`, `CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS`, `CLAUDE_CODE_ENABLE_AUTO_MODE`, `CLAUDE_CODE_ENABLE_TELEMETRY`, `CLAUDE_CODE_SIMPLE_SYSTEM_PROMPT`, `DISABLE_ERROR_REPORTING`, `DISABLE_NON_ESSENTIAL_MODEL_CALLS`, `DISABLE_TELEMETRY_OFF`, `ENABLE_CLAUDEAI_MCP_SERVERS` and `ENABLE_TOOL_SEARCH`. Any other key refuses the whole kit. The consent sheet adds one plain line for the two keys that change behaviour: `CLAUDE_CODE_ENABLE_AUTO_MODE` ("Claude Code sessions act without asking you.") and `ENABLE_CLAUDEAI_MCP_SERVERS` ("Your claude.ai connectors load in every session."). No piece writes `model`, `apiKeyHelper` or any other settings key, and there is no `secret` setting kind: a tool that needs a credential names a Keychain item in the README and reads it itself.

  ```toml
  [[contributes.kit.pieces]]
  id   = "env"
  kind = "env"
  vars = { DISABLE_ERROR_REPORTING = "1", ENABLE_TOOL_SEARCH = "true" }
  ```
- Every `run`, `source`, `dir` and `from` path stays inside the kit folder, goes through no symlink, and names a file or folder of the right kind. Files carrying a setuid or setgid bit are refused.
- `hook.event` must be one of the hook events Claude Code documents. An unknown name is a refusal in Prosper.
- `interpreter`, when given, must be listed in `requires`.
- `on_error = "deny"` marks a deny guard hook: when Prosper's kit runner cannot run it (a bad argument, a missing or unsafe kit.env, input over 1 MiB, a failing `.pre` hook, a missing script) it exits 2 and Claude Code blocks the call. A hook without it lets the call through on such an error. A Prosper that predates the key refuses a kit that uses it.
- An agent file is `<name>.md` with a `---` frontmatter whose single `name:` equals the file name; it may not hold a placeholder, because it is installed byte for byte.
- A `settings.json` hook runs in parallel with the person's own hooks and with other kits' hooks: nothing promises an order between them.

### Settings and placeholders

`[[contributes.kit.settings]]` entries (`key`, `title`, `kind` = `string`, `path`, `bool` or `choice`, `default`, and `values` for a choice) become a form on the kit's Settings page. Each value reaches the kit's scripts as the environment variable `KIT_<KEY>` (the key upper-cased: `greeting` gives `KIT_GREETING`). Saving the form writes only Prosper's own file inside the kit's config folder and changes no Claude Code file.

Prosper renders these placeholders into the `*.md` files of a staged copy of the kit before it goes live, and into the command strings it builds. Scripts are never rewritten; they get the same values as environment variables from the runner.

| Placeholder | Environment variable | Value |
| --- | --- | --- |
| `{{kit_dir}}` | `KIT_DIR` | the kit's folder |
| `{{kit_bin}}` | `KIT_BIN` | the shim folder |
| `{{kit_config}}` | `KIT_CONFIG` | `~/.config/<slug>`, as an absolute path |
| `{{home}}` | | the home folder |

The runner also sets `KIT_STATE_DIR`, a folder that survives kit updates. Because an update replaces the kit folder whole, a tool that keeps files between runs must keep them there (or in `KIT_CONFIG`), never next to its own code.

### The README contract

`README.md` at the kit root is required. Install refuses a kit without it, or without these level-2 headings (any order, case-insensitive):

| Heading | Must say |
| --- | --- |
| `## What it changes` | every piece in plain words: which file, which hook event, what the status line shows |
| `## Requirements` | the `requires` executables and how to install them, any macOS permission, any account |
| `## Customise` | which `local.md` lines make sense, which tools have `.pre` / `.post` points, the kit settings |
| `## Remove` | that Remove undoes the wiring, and what it leaves on purpose (seeded config, the tools' own data) |

Prosper also generates a "What will change" summary from the manifest. That one is authoritative: it is what the consent sheet applies. When the README disagrees, the generated summary wins.

A `local.md` line that contradicts the kit text gives undefined behaviour: Claude Code reads `local.md` last, and which instruction wins is not guaranteed. To change a kit rule, switch that piece off and write your own.

### Layers and customisation

| Layer | Where | Who writes it | On update |
| --- | --- | --- | --- |
| Generic | the kit folder, the shim folder | Prosper | replaced whole |
| Wiring | managed blocks in `CLAUDE.md`, elements in `settings.json` | Prosper, after consent | re-planned; asks again when the change is not a noop |
| Personal | the person's own text outside blocks, `local.md`, `~/.config/<slug>/hooks/*`, seeded files | the person | never touched |

Hand edits inside the kit folder are lost on update; the pane shows "kit files edited" when it no longer matches what was installed. Three customisation points belong to the person:

1. **`local.md`.** The kit's `CLAUDE.md` must end with the line `@{{kit_config}}/local.md` (exactly one `claude-md` piece carries it, and that piece stays on while another `claude-md` piece is on). Prosper seeds `~/.config/<slug>/local.md` on first apply so the import resolves. The import chain below the kit's `CLAUDE.md` is at most 2 deep.
2. **`.pre` and `.post`.** Every hook, status line and tool runs through one runner script that Prosper owns. If `~/.config/<slug>/hooks/<name>.pre` or `.post` exists it runs before or after the target; a non-zero `.pre` exit stops the run (exit 2 blocks a `PreToolUse` call). `.post` sees `KIT_STATUS` and cannot change the output. A file is run only if it is a regular, executable file owned by the user and not group- or world-writable.
3. **A switch per piece.** Each piece has a toggle in the pane, remembered across updates. A kit author sets the granularity: one `tools` piece per group of tools a person may want separately.

### The Settings page

Each installed kit has its own page under its row in Settings (the section id `kit` is reserved for it). It shows the header (title, version, source, trust, "Update available"), the README, each `requires` entry as found or not found (lookup only, nothing is executed), and one row per piece with its state, target file and switch. Apply, Repair and Remove, for all pieces or one, go through a consent sheet that lists every change. Apply is allowed with a missing requirement, with a warning.

`settings.json` changes (hooks, permissions) reach open Claude Code sessions through Claude Code's file watcher; `CLAUDE.md` changes reach new sessions only. The page says so under the pieces.

### Updates and rollback

A kit never takes the silent auto-update path of other extensions. A newer version is staged and shown as "Update available"; Update opens a sheet with the changed executables and the wiring diff. Apply swaps the staged copy in, regenerates the shims and applies the wiring, and a failure swaps back. One previous version is kept, and "Roll back" returns to it through the same sheet. Trust survives an update; consent does not, whenever the wiring diff is not a noop or an executable changed.

### Several kits

Two `claude-md` blocks both stay live, in apply order. Hooks on one event are appended as separate groups and all run. Permissions are a union, and a `deny` from one kit against an `allow` from another is shown as a warning, never resolved. The `statusLine` is a single slot: the second kit's piece shows `conflict` until the person chooses it. Two kits with the same tool name do not clash on disk (each has its own shim folder); on the PATH of Prosper-started sessions the first-installed kit wins, and the user's own earlier PATH entries win over both.

### Trust

A kit's hooks and status line run as the person, in every Claude Code session, outside Prosper's sandbox. So a kit **installs untrusted**: its README, summary and files can be read, but there is no Apply until the person trusts it. Consent is asked per change, and the sheet names every command Claude Code will run. Nothing applies by itself, and a kit is never auto-applied or auto-updated.

### Publishing and installing from the Marketplace

- **Kind.** A kit is listed with kind `kit`. **Settings > Extensions > Marketplace** has an **Agent Kits** filter, and every kit row carries a **KIT** badge and the line "Unreviewed - runs shell commands in your Claude Code sessions". The Marketplace has no review in v1.
- **Publish checks.** The publish flow validates the packed kit as an install would (manifest, README contract, scripts only) and refuses before uploading. A Marketplace kit is **scripts only**: a Mach-O or other non-text executable is refused (a local install shows a warning instead). The whole package stays under the **256 KB** cap.
- **Listing preview.** Publish computes a preview from the kit itself: the generated "What will change" lines and the first section of the README (at most 2048 bytes). A kit is published with its preview; the server refuses a kit without one (`kit_preview_missing`).
- **Install-time recheck.** After download, Prosper recomputes the summary and README section from the archive and installs only if the kind is `kit`, the version is still the listed one, the listing is active, the preview equals the recomputed one, and the validator accepts the kit. A listing therefore cannot under-describe what the package does.
- **Before installing**, a kit shows a sheet with its README and the generated summary. The install lands untrusted.

### Checklist

1. The manifest passes the rules above, and the README has the four headings.
2. Every script is plain text, executable, inside the kit folder, and the whole kit is under 256 KB.
3. Nothing in the kit is personal or secret: it is public.
4. Try it as a local install first (Settings > Extensions), then publish.

---

## 13. X-ray refs (`[[contributes.xrefs]]`)

An extension can teach the Terminal's X-ray view a new kind of reference, like a ticket id. Prosper underlines each match in a Terminal pane. Hovering one, or pinning it, calls a Lua handler of the extension that returns a small card. Worked example: [`app/Examples/extensions/xref-example/`](app/Examples/extensions/xref-example/).

```toml
[[contributes.xrefs]]
id       = "acme-ticket"
template = "ACME-{n}"
label    = "Acme ticket"
handler  = "xref_card"
timeout  = 3
```

The extension must be enabled and **trusted** for its rules to load. The rules are rebuilt whenever extensions reload, are enabled, disabled, trusted or untrusted.

### The fields

| Field | Rule |
| ----- | ---- |
| `id` | Required. A non-empty string, the rule's name in the log. |
| `template` | Required. A non-empty string; see below. |
| `label` | The card's source line. A non-empty string, shown up to 80 characters. Default: the `id`. |
| `in_code` | `"never"` (default) or `"whole"`. Whether a match inside a code line counts: never, or only when it is the whole trimmed line. The Terminal underline does not use it yet; it reads each viewport line as text. |
| `handler` | A Lua global of the extension. Without it the rule draws nothing: no underline, no card. |
| `timeout` | Whole seconds, 1 to 10. Default 3. How long the card waits for the handler. |

A field of the wrong type refuses the row (for example a `timeout` that is not an integer in 1..10).

### The template

Literal text plus placeholders. Literals match ignoring ASCII case (`acme-12` matches `ACME-{n}`).

| Placeholder | Takes |
| ----------- | ----- |
| `{n}` | 1 to 7 digits |
| `{id}` | a letter or digit, then up to 63 of letters, digits, `_`, `.`, `-` |
| `{KEY}` | an uppercase letter, then 1 to 9 uppercase letters or digits (`API`, `ACME2`) |
| `{repo}` | `name`, or `owner/name`: owner 1 to 39 of letters, digits, `-`; name 1 to 100 of letters, digits, `_`, `.`, `-` |

Rules, each a refusal when broken:

- At most **64 characters**.
- At least 1 and at most **3** placeholders. Only the four above; a `}` with no `{`, an unclosed `{` or an unknown name is refused.
- No two placeholders side by side: put a literal between them.
- A literal right after a placeholder may not start with a character that placeholder could take (so `{n}0` and `{id}-{n}` are refused; `{KEY}-{n}` is fine). This is what keeps a match unambiguous.

A match starts and ends at a word boundary: no letter, digit or `_` touches it on either side. Matches in one line never overlap, and a span over a built-in (dch) underline is dropped; between two rules, the first wins.

### Refusals and caps

A refused rule is skipped with one line in Prosper's log (`extension <id>: xref <name> refused (<reason>)`); the rest of the extension still loads. Reasons: not a table, an unreadable field, a missing or wrong field (above), a bad template (above), a template already used by a loaded rule (the first wins), more than **16** rules in one extension, more than **64** rules in all. If `contributes.xrefs` is not an array of tables the whole list is ignored, with one line.

### What is drawn

A span is underlined only when its rule has a handler **and** the same text appears **at least twice** on screen (in the visible rows of the focused, live Terminal pane). A single occurrence is left alone. Hover a span to read its card, or pin it.

### The handler

```lua
function xref_card(a)           -- a = { text, parts, dir, session }
  local n = a.parts[1]
  if n ~= "12" then return nil end                 -- nil or {}: no card
  return {
    title = "Login retries",
    subtitle = "ACME-" .. n,
    body = "Owner: acme/api",
    actions = {
      { label = "Open", url = "https://example.com/acme/tickets/" .. n },
      { label = "Copy id", copy = "ACME-" .. n },
    },
  }
end
```

**In** (one table): `text` the matched text, `parts` each placeholder's text in template order, `dir` the pane's directory, `session` the session name (`""` when unknown). Never any other line of the screen or the transcript.

**Out**: `nil` or an empty table (no card, "Nothing from <label>"); `{ error = "..." }` (the card shows the message, cut to 200 characters); or a card `{ title, subtitle, body, actions }`. Any other value, or a thrown error, fails the card. A card with every field empty is no card. The whole answer may be at most 64 KB.

Caps: `title` 120 characters, `subtitle` 200, `body` 8 KB, 4 `actions` (extra ones are dropped). Every string the handler returns is treated as outside text and cleaned before it is shown. An action is data, never code: `{ label, url }` (an `http` or `https` URL with a host) opens the URL; `{ label, copy }` copies the text (up to 8 KB). `label` is up to 40 characters; an action with neither a usable `url` nor a `copy` is dropped.

The handler runs on the extension's own call lane, one call at a time, with the usual `host.*` surface for its tier. A handler that waits in a host call (such as `host.process.run`) is cancelled when its card is dropped.

### Requests in flight and caching

- Per window, at most **2** handler calls run at once. A third drops the oldest (its card reads "Dropped for a newer card"; the next ask runs it again).
- The same request (same extension, rule and argument) joins the call already running.
- At `timeout` seconds the call is dropped and the card reads "The extension did not answer in time".
- A reload, disable or untrust while a call runs turns its answer into "Extension unavailable: it was reloaded or turned off".
- An answer is kept 60 seconds; a failure 10. At most 256 answers are kept (the oldest used goes first).
