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

`host.ui.converter{ title=, left={label,placeholder,value}, right={…}, forward=, backward=, mono= }` is a live bidirectional two-pane transform window (open it via `host.window.open`): `forward`/`backward` name global Lua functions (text → text) — editing the left pane runs `forward` into the right, editing the right runs `backward` into the left. [`base64`](app/Sources/ProsperApp/Resources/extensions/base64/) is the worked example.

### Async & timeouts

Long-running natives are async, bridged to sync Lua with a hard timeout — extensions run off the main thread. On timeout the bridge **cancels** the underlying work (a stuck `host.http` request stops; it isn't orphaned), so a wedged call can't keep burning a thread after your handler moved on.

---

## 4. Performance & isolation

Each extension's off-main work runs on its **own serial lane**, so a slow handler (e.g. `host.http` retrying with backoff) never blocks another extension's commands, timers, or events; within one extension calls stay serialized so a `host.prefs` read-modify-write can't interleave.

**Runtime:** Lua 5.4 vendored in-process (pure C, no JIT → notarization-clean), sandboxed — no `io`/`os`/`package`/`require`/file/net — with an instruction budget that aborts runaways. See [`LuaRuntime.swift`](app/Sources/LuaRuntime/LuaRuntime.swift).

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
| `system.launch` | — | once, at startup |
| `system.wake` | — | wake from sleep |
| `system.sleep` | — | machine about to sleep |
| `screen.locked` | `{ locked }` | screen locked / unlocked |
| `clipboard.changed` | `{ kind, text }` | something was copied — `kind` is `text`/`image`/`file`, `text` present only for `text` and capped at 8 KB (call `host.clipboard.read()` for the whole clip) |
| `battery.changed` | — | power source / level change |
| `network.changed` | — | reachability change |
| `app.activated` | `{ bundleID, name, pid }` | frontmost app change |
| `lid.changed` | — | clamshell open/close |
| `url.open` | `{ url }` | a link opened while Prosper is the default browser |
| `timer.fired` | `{ id }` | a scheduled `host.timer` fired |

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

- **Automation tier** — hotkeys/key-rules, app launch/hide/focus, `osascript`, keyboard-source set, default-browser set, `host.http`, filesystem watches, power/caffeinate, menubar/dialog/alert. Granted to bundled **system extensions** *and* to marketplace/user extensions you have **trusted**.
- **System-only tier** — `host.shell.run`, the coding agent, arbitrary-path `host.fs.read`, `host.fallback.*`, and destructive file ops (trash). Reachable by a **system extension**, *or* **any extension you grant System Access** (§ below).

**Granting System Access to any extension.** The privileged tier is not reserved for bundled extensions. **Any extension — including one you wrote or installed from the Marketplace — can be elevated to the system tier.** Trust it first, then click **Grant System Access** on it in Settings → Extensions. The gate is exactly `record.privileged = record.isSystem || (record.trusted && granted)` ([`ExtensionRegistry.swift`](app/Sources/ProsperApp/Extensions/ExtensionRegistry.swift), persisted in `privilegedExtensionIDs`) — so a granted user extension calls `host.shell.run`, the coding agent, and the destructive surface identically to a bundled one. It is a deliberate escalation (a granted config runs **any command as you**), default off, per-extension, and revocable — revoking or untrusting tears the VM down. [`hammerspoon-compat`](app/Examples/extensions/hammerspoon-compat/) is the worked example: trusted it gets only automation (`hs.execute` is refused); after Grant System Access its `hs.execute` runs real shell.

For an **untrusted, non-system** extension every side-effecting call is an inert no-op (a refused `host.shell` returns `"error: host.shell is restricted to system extensions"`). A bare untrusted extension never executes at all. Gating logic: `automation = privileged || trusted` in [`ExtensionHostAPI.swift`](app/Sources/ProsperApp/Extensions/ExtensionHostAPI.swift).

> ⚠️ **Trusting a config is not a full sandbox.** `host.osascript` is in the automation tier and AppleScript can `do shell script`, so a trusted config can run shell indirectly. Only trust configs you have read end-to-end. Granting System Access lets a trusted config run **any command as you** — a deliberate escalation; default is off.

### Automation calls

- `host.apps.search(query)` · `host.apps.launch_or_focus(name|bundleID)` · `host.apps.hide(bundleID)` · `host.apps.frontmost()` → `{ bundleID, name, pid }` · `host.apps.windows(bundleID)` → window count (Accessibility; 0 without the a11y grant)
- `host.osascript.run(source)` → `{ ok, output, error }` — AppleScript / JXA bridge
- `host.keyboard.current_source()` → input-source id · `host.keyboard.layouts()` → `{ { id=, name= }, … }` · `host.keyboard.set_source(id)` → bool (Carbon TIS)
- `host.keys.set_rules{ … }` — install the per-extension **key-rule** set (replaces the prior set; see § Key rules). `host.keys.stroke(spec)` injects a chord; `host.keys.system(name)` injects a media/aux key (`PLAY NEXT PREVIOUS FAST REWIND MUTE SOUND_UP SOUND_DOWN BRIGHTNESS_UP BRIGHTNESS_DOWN ILLUMINATION_UP ILLUMINATION_DOWN`). Injected events are tagged so they never re-enter the tap (no loops).
- `host.url.open(url [, bundleID])` — open a URL (optionally in a specific browser) · `host.url.default_browser()` → bundle id of the current http handler · `host.url.set_default_browser(id)` → bool
- `host.fs.watch(path, "handler")` — fire a named handler with `{ paths = {…} }` on change · `host.fs.unwatch(path)` ([`ExtensionFSWatch.swift`](app/Sources/ProsperApp/Extensions/ExtensionFSWatch.swift))
- `host.caffeinate.prevent_idle_sleep(kind, on)` (`kind` = `"display"`|`"system"`) · `host.caffeinate.set_disable_lid_sleep(on)` · `host.caffeinate.set_remote_wake{ enabled=, interval_ac=, interval_batt=, battery_floor=, device_id= }` · `host.caffeinate.lock_screen()` · `host.caffeinate.start_screensaver()` · `host.caffeinate.sleep_now()` (release every keep-awake hold and sleep). Worked example: [`openlid`](app/Sources/ProsperApp/Resources/extensions/openlid/).
- `host.menubar.set{ id=, title=, icon=, menu={ {title=, handler=, payload=, enabled=, checked=, stay=} | {separator=true} } }` · `host.menubar.remove(id)` ([`ExtensionMenuBar.swift`](app/Sources/ProsperApp/Extensions/ExtensionMenuBar.swift)). A row with no `handler`, or `enabled=false`, is disabled; `stay=true` runs the handler on a click without closing the menu (Return still closes it), and the re-rendered menu updates in place (worked example: [`openlid`](app/Sources/ProsperApp/Resources/extensions/openlid/)) · `host.dialog.{prompt,confirm}` · `host.alert.show(text [, seconds])` — host-rendered UI
- `host.dch.sessions()` → `{ {name=, alias=, active=}, … }` — live remote-terminal sessions (drives the OpenLid status readout)

### System-only calls

- `host.shell.run(cmd [, { keep_running = true }])` → output, truncated — arbitrary command execution through the login shell (stdout + stderr, trimmed). Output is capped at 64 MiB; `truncated` is `true` when the cap was hit, else `nil` (the text itself is never marked). On the host call timeout the command's whole process group is killed and `""` is returned; with `keep_running = true` the call still returns `""` at the timeout but the command runs on to completion (for upgrades, user scripts, file moves). `opts` must be `nil`, `false` (same as `nil`, so `cond and { keep_running = true }` works) or a table whose only key is `keep_running` (a boolean); anything else raises a Lua error. An unknown key is named in it; a non-table `opts` or a non-boolean `keep_running` is reported by the type of the bad value (`got string`). When output can exceed 64 MiB, never pass `host.shell.run(x)` as the last argument of a call or inside `{...}`: the second return (`true`) spills in as an extra argument or element. Wrap it in parentheses, `f((host.shell.run(x)))`, or assign it to a local first.
- `host.fs.read(path)` → string | nil — arbitrary-path file read
- `host.fallback.*` — fallback-search provider list/save/mode/import ([`fallback-search`](app/Sources/ProsperApp/Resources/extensions/fallback-search/) owns the settings UI; per-keystroke row building is native)
- the coding agent and destructive file ops (trash)

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
host.config.status{ pieces = pieces } -- -> { { id, state, target, path } }, or { error = "state_unreadable", message }
host.config.remove{ ids = { "pre" } } -- or { all = true }
host.config.repair{ all = true }      -- or { ids = { … } }
```

- **`plan`** never writes and never asks. Its `diff` holds only the added and removed lines; the unchanged lines around them are the user's own text and appear only on the consent sheet. **`apply`**, **`remove`** and **`repair`** show the consent sheet: the masked diff, the backup folder, and a sentence per hook and status line. A change to `claude:settings.json` notes that it applies to open Claude Code sessions at once. **Cancel** writes nothing and answers `ok = false, status = "denied"` with empty `applied`, `removed` and `pieces`. Nothing is remembered: the next change asks again.
- If a file changes on disk while the sheet is up, Prosper plans again. When the new change set differs, it shows the sheet a second time. Cancelling it keeps any file already written under the first one, and the answer lists only those pieces.
- The write calls wait for your answer, so call them from an **async handler** (or any off-main lane). A write call made on the main thread answers `ok = false` and writes nothing. After 5 minutes with no answer, the call gives up and writes nothing; a later Apply counts as Cancel.
- **Targets.** `claude:` is Claude Code's config dir (`CLAUDE_CONFIG_DIR` from your login shell, else `~/.claude`). `kitconfig:` is `~/.config/<your manifest name>/`; Prosper creates that dir and marks it with a `.prosper-kit` file. `ext:` (seed sources only) is your extension's own dir, read-only. `..`, absolute paths, `settings.local.json`, paths that differ only by letter case, and the `.prosper-kit` file are refused.
- **Blocks** go in `claude:<name>.md`, or in `kitconfig:` files ending in `.md`, `.markdown`, `.sh`, `.bash`, `.zsh`, `.fish`, `.conf`, `.toml`, `.yaml` or `.yml`. Any other extension is refused, because the block markers need a known comment syntax.
- **JSON** pieces target `claude:settings.json` only. Only these paths are allowed: `hooks.<event>` with `append`, for the 33 events Claude Code documents (an unknown event is refused); `permissions.allow`, `deny`, `ask` and `additionalDirectories` with `union`; and `statusLine` with `set`. `env`, `apiKeyHelper`, `model`, `disableAllHooks`, `disableBypassPermissionsMode` and `permissions.defaultMode` are always refused. Two of your pieces cannot both `set` the same path.
- **Status states:** `applied`, `drifted` (someone edited it), `missing`, `replaced`, `corrupt`, `unwritable`, `conflict`, `adopted` and `orphaned` (the extension is gone). Remove still works on orphaned pieces.
- **Uninstall** of an extension with live pieces shows the Remove sheet first. If you cancel it, the extension and its config both stay. An extension that never wrote a piece uninstalls even when Prosper cannot read `CLAUDE_CONFIG_DIR` from your login shell; one with pieces waits until it can. If Prosper's own record (`~/Library/Application Support/Prosper/managed-config/state.json`) is damaged or from a newer Prosper, no uninstall goes ahead, because nothing can tell which pieces are whose: update Prosper, or move that file aside, after which uninstall works and any pieces stay in your files as plain text to delete by hand.
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