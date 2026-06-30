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

Other contribution arrays under `[contributes]`: `keybindings` (`{ command, key, when }`), `palette_entries`, `views`, `placeholders` (snippet tokens, §6), `events` (§5), `themes` (§7), `settings_sections` (§8).

Any installed extension whose `match` accepts the query is dispatched on its own **off-main async lane** — that is how [`quicklinks`](app/Sources/ProsperApp/Resources/extensions/quicklinks/) and your own extensions surface as palette commands. [`currency`](app/Sources/ProsperApp/Resources/extensions/currency/) is the canonical async example: it fetches daily FX over `host.http` (with retry), caches via `host.prefs`/`host.time`, and never blocks the main thread.

---

## 3. The host API (`host.*`)

The host surface is strict, time-boxed, and assembled per-extension. **Reads are open to every extension; side-effecting calls are tiered (§9).** Full Swift surface: [`ExtensionHostAPI.swift`](app/Sources/ProsperApp/Extensions/ExtensionHostAPI.swift) and [`LiveExtensionHostServices.swift`](app/Sources/ProsperApp/Extensions/LiveExtensionHostServices.swift).

### Core (every extension)

- `host.clipboard.{read,write,history}`
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

- `host.window.frame()` → `{ x, y, w, h, screen = { x, y, w, h } }` — focused-window geometry via Accessibility · `host.window.set(x,y,w,h)` → bool (move/resize). Powers [`window`](app/Sources/ProsperApp/Resources/extensions/window/).
- `host.window.open(node)` opens a standalone host-rendered window from a `host.ui.*` node; `host.window.close()` dismisses it (used by form/dialog submit handlers).
- `host.ui.{list,detail,form,grid,converter,loading,render}` build native SwiftUI trees — **no HTML, the host owns every pixel.** Renderer: [`ExtensionViewRenderer.swift`](app/Sources/ProsperApp/Extensions/ExtensionViewRenderer.swift).
- `host.ui.chooseApp()` → `{ bundleID=, name= }` | nil — native app picker (used by [`inputswitch`](app/Sources/ProsperApp/Resources/extensions/inputswitch/)).
- `host.ui.settings.*` — the Settings-pane builders (§8).

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
| `battery.changed` | — | power source / level change |
| `network.changed` | — | reachability change |
| `app.activated` | `{ bundleID, name, pid }` | frontmost app change |
| `lid.changed` | — | clamshell open/close |
| `url.open` | `{ url }` | a link opened while Prosper is the default browser |
| `timer.fired` | `{ id }` | a scheduled `host.timer` fired |

A native watcher stays dormant until at least one **enabled** extension subscribes. [`openlid`](app/Sources/ProsperApp/Resources/extensions/openlid/) subscribes to `system.launch`/`battery.changed`/`network.changed`/`system.wake`/`lid.changed`; [`inputswitch`](app/Sources/ProsperApp/Resources/extensions/inputswitch/) to `app.activated`; [`url-dispatcher`](app/Sources/ProsperApp/Resources/extensions/url-dispatcher/) to `url.open`.

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

Pick a theme in **Settings → Personalization**; the whole app (and the AppKit menu-bar / dock chrome) redraws instantly. Missing tokens fall back to the default palette, so a partial palette is valid. Selecting a theme **never spawns the extension's Lua VM** — it is pure declarative data.

---

## 8. Settings sections

An extension can contribute its own pane to **Settings → Extensions** — a static **Tier-A** spec (host-rendered, host-persisted to `host.prefs`) and/or a **Tier-B** dynamic render hook. Spec: [`EXTENSION_SETTINGS_SPEC.md`](docs/EXTENSION_SETTINGS_SPEC.md); models: [`ExtensionSettingsModel.swift`](app/Sources/ProsperApp/Extensions/ExtensionSettingsModel.swift).

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

Row `kind`s: `group`, `toggle`, `text`, `secret`, `number`, `stepper`, `enum` (with `values`/`value_labels`), `path`, `info`, `permission` (Granted/Not-granted badge with **Open** + **Re-check** wired to `host.perms`), `button`, `link`, and `shortcut` (a global-shortcut recorder bound to a host `ShortcutAction` — same recorder/reset/clear row as the native Shortcuts pane). A `records{ … }` block renders an add/remove list ([`quicklinks`](app/Sources/ProsperApp/Resources/extensions/quicklinks/), [`quickdirs`](app/Sources/ProsperApp/Resources/extensions/quickdirs/), [`snippets`](app/Sources/ProsperApp/Resources/extensions/snippets/) manage their entries this way).

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
- `host.menubar.{set,remove}` ([`ExtensionMenuBar.swift`](app/Sources/ProsperApp/Extensions/ExtensionMenuBar.swift)) · `host.dialog.{prompt,confirm}` · `host.alert.show(text [, seconds])` — host-rendered UI
- `host.dch.sessions()` → `{ {name=, alias=, active=}, … }` — live remote-terminal sessions (drives the OpenLid status readout)

### System-only calls

- `host.shell.run(...)` — arbitrary command execution
- `host.fs.read(path)` → string | nil — arbitrary-path file read
- `host.fallback.*` — fallback-search provider list/save/mode/import ([`fallback-search`](app/Sources/ProsperApp/Resources/extensions/fallback-search/) owns the settings UI; per-keystroke row building is native)
- the coding agent and destructive file ops (trash)

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
| [`window`](app/Sources/ProsperApp/Resources/extensions/window/) | Window management | `host.window.frame/set`; 10 settings sections |
| [`openlid`](app/Sources/ProsperApp/Resources/extensions/openlid/) | Keep-awake / lid power | `host.caffeinate.*`; 5 events; `runs_on_select` toggles |
| [`url-dispatcher`](app/Sources/ProsperApp/Resources/extensions/url-dispatcher/) | Browser routing | **opt-in** (`default_disabled`); `url.open` event + key rules |
| [`inputswitch`](app/Sources/ProsperApp/Resources/extensions/inputswitch/) | Per-app keyboard input source | **opt-in**; `app.activated` event; `host.keyboard` |
| [`menubar`](app/Sources/ProsperApp/Resources/extensions/menubar/) | Ice/Bartender-style menu-bar control | **opt-in**; native footer pane |
| [`fallback-search`](app/Sources/ProsperApp/Resources/extensions/fallback-search/) | Web-search default results | settings UI only; native row building via system-only `host.fallback.*` |
| [`theme-default`](app/Sources/ProsperApp/Resources/extensions/theme-default/) · [`theme-amber`](app/Sources/ProsperApp/Resources/extensions/theme-amber/) | Color themes | declarative `theme.json`, no Lua |

The conversion engines keep a **native fallback**, so a disabled or edited extension never loses the feature.

> **Not bundled — the automation showcase:** [`hammerspoon-compat`](app/Examples/extensions/hammerspoon-compat/) ships under `app/Examples/`, installs **untrusted**, and demonstrates the full automation tier (loading an unmodified `~/.hammerspoon/init.lua` by shimming `hs.*` onto `host.*`). Read it as the end-to-end example of events, key rules, raw event taps, URL routing, durable timers, and a dynamic settings section.

---

## 11. Installing & distributing

**Everything lives in `~/.config/prosper/extensions`** — one editable directory. User extensions install there and remove freely; system extensions can't be uninstalled, only reset.

- **From GitHub** — paste a repo/subdir URL into **Settings → Extensions** (`github.com/owner/repo`, `…/tree/<ref>/<subdir>`, `.git`, `git@` forms all parse). Prosper fetches the tarball, validates `extension.toml`, installs. ([`RemoteInstaller.swift`](app/Sources/ProsperApp/Extensions/RemoteInstaller.swift))
- **Marketplace** — browse and one-click-install published extensions, or **Publish** your own, from **Settings → Extensions**. Manifests are signed (Ed25519) and verified on download; a freshly installed extension lands **untrusted** and runs only after you grant trust (install-then-trust gate), so privileged host APIs stay opt-in. ([`MarketClient.swift`](app/Sources/ProsperApp/Extensions/MarketClient.swift))

See also: [`docs/ADR-002-extensibility.md`](docs/ADR-002-extensibility.md) (design), [`docs/EXTENSION_SETTINGS_SPEC.md`](docs/EXTENSION_SETTINGS_SPEC.md) (settings rows).
