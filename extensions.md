# Writing Prosper extensions

A fast, lightweight **Lua extension system** (Neovim-style) — no recompile needed, with a strict, native surface (no webviews). Add commands to Prosper's command palette by dropping a folder in `~/.config/prosper/extensions`.

**One directory per extension:**

```
my-ext/
├── extension.toml   # manifest: id, name, version, api_level, match regex, settings
└── init.lua         # entry script; defines the command handler(s)
```

```toml
# extension.toml
[extension]
id          = "com.example.shout"
name        = "shout"
title       = "Shout"
description = "Uppercase the query."
version     = "1.0.0"
author      = "you"

[extension.host]
min_version = "2.0.0"
api_level   = 1

[extension.entry]
main = "init.lua"

[[contributes.commands]]
id    = "shout.run"
title = "Shout"
mode  = "no-view"        # or "view" (returns a host.ui component tree)
match = "^shout "        # palette routes matching input here
```

```lua
-- init.lua
-- The handler is the global named after the command id with non-alphanumerics
-- replaced by '_': command "shout.run" → shout_run(query). Return a string
-- (or "value\tdetail"), a host.ui.render(...) tree, or nil to decline.
function shout_run(query)
    return (query:gsub("^shout ", "")):upper()
end
```

Useful optional command fields: `keywords` (launcher discovery), `prefix` (e.g. `"sh "` locks the runner into the command as a labelled mode), `launches_window = true` (surface as a row that opens the window on Enter instead of running per keystroke), `requires = ["model"]` (hidden until the local LLM is loaded).

**Runtime** — Lua 5.4 vendored in-process (pure C, no JIT → notarization-clean). Sandboxed (no `io`/`os`/`package`/`require`/file/net) with an instruction budget that aborts runaways. VMs activate lazily on first match — zero cost until used.

**Host API** (`host.*`, strict + time-boxed):

- `host.clipboard.{read,write,history}`
- `host.llm.{complete,translate}` — `translate(text, target [, source])` returns a structured table `{ primary, detected, candidates = { { text=, label=, note= }, … } }` (or nil on empty/failed translation), ready to feed result views
- `host.shell.run`
- `host.window.{frame,set,open,close}` — `frame()`/`set(x,y,w,h)` are focused-window geometry (move/resize) via Accessibility: `frame()` returns the window rect and its screen's visible frame, `set` repositions it. `open(node)` opens a standalone host-rendered window from a declarative `host.ui.*` node (e.g. `host.ui.converter`); `close()` dismisses it (used by form/dialog submit handlers)
- `host.http.{request,get,post}` — outbound HTTP with **built-in retry + exponential backoff** on transient failures (no response / 5xx / 408 / 429); http/https only, time-boxed, response capped at 5 MB. Returns `{ status, body, headers, ok, json }`.
- `host.prefs.{get,set}`
- `host.time()` (wall-clock epoch seconds) · `host.sleep(seconds)` (for backoff; capped)
- `host.notify`
- `host.fs.list_dirs(path)` — immediate subdirectory names of a path (tilde-expanded, hidden entries skipped, sorted); the only filesystem capability, read-only. Powers Quickdirs.
- `host.apps.search(query)` — ranked application matches as `{ { name=, path= }, … }`. Powers the Open launcher.
- `host.json` + declarative UI builders `host.ui.{list,detail,form,grid,converter,loading,render}` → native SwiftUI (no HTML)

`host.ui.loading{ title=, subtitle=, progress= }` renders a native Apple-style loading state — an **infinite** spinner when `progress` is absent, or a **progressive** bar (0…1, with a percentage) when set. The host also shows this spinner automatically while an async view action is in flight, so every async operation gets a polished loading state for free.

`host.ui.converter{ title=, left=, right=, forward=, backward=, mono= }` is a live bidirectional two-pane transform window (open it via `host.window.open`): `forward`/`backward` name global Lua functions (text → text) in your extension — editing the left pane runs `forward` into the right, editing the right runs `backward` into the left. Base64 is the worked example.

Long-running natives are async, bridged to sync Lua with a hard timeout — extensions run off the main thread. On timeout the bridge **cancels** the underlying work (a stuck `host.http` request stops, it isn't left running in the background), so a wedged network call can't keep burning a thread after your handler has already moved on.

**Performance & isolation.** Each extension's off-main work runs on its **own serial lane**, so a slow handler (e.g. `host.http` retrying with backoff) never blocks another extension's commands, timers, or events; within one extension, calls stay serialized so a `host.prefs` read-modify-write can't interleave. The keystroke remap path (§D) is fully native and **keyCode-indexed** — a keypress only scans rules bound to that key (≈0–2), budgeted under 5 µs/keystroke and typically a few hundred ns. No Lua runs in the keystroke path.

## Stateless background extensions

Not every extension is a palette command. Prosper can also drive **system automation** — global hotkeys, key remaps, app launchers, screen/power control, filesystem watches — the kind of thing people reach for Hammerspoon to do. These run on a **stateless event model**: there is no resident VM holding live closures. The host owns every watcher (timers, key taps, FSEvents, the menubar) and, when something happens, spins a short-lived runtime, runs **one named Lua handler**, and tears it down. Durable state lives in `host.prefs`; durable timers in the scheduler; native resources (key rules, watches, power assertions) in the host.

**Subscribe to a native event** in the manifest — the handler is a Lua global, invoked with a JSON payload that arrives pre-decoded as a Lua table:

```toml
[[contributes.events]]
event   = "system.launch"   # one-shot at startup
handler = "install_rules"
```

Recognized events: `system.launch` (once, at startup — the place to install key rules or filesystem watches), `system.wake`, `battery.changed`, `network.changed`, `app.activated` (`{ bundleID, name, pid }`), `lid.changed`, `url.open` (`{ url }`, delivered when Prosper is the default browser), plus `timer.fired` from the scheduler. A native watcher stays dormant until at least one enabled extension subscribes.

**Durable named-handler timers** survive relaunch and re-invoke a global by name (no live closure):

```lua
host.timer.schedule{ id = "nightly", every = 86400, handler = "on_nightly" }  -- repeating
host.timer.schedule{ id = "once",    after = 120,   handler = "on_soon" }      -- one-shot
host.timer.cancel("once")
```

## Host API — automation surface

Reads (frontmost app, keyboard layout, fs attributes, battery/network/screen) are open to **every** extension. Side-effecting/privileged calls (launching apps, AppleScript, setting the keyboard layout or default browser, installing key rules, watching the filesystem, power/menubar/dialogs) are gated to **system extensions** (`system = true`); for a non-system extension they are inert no-ops.

- `host.apps.search(query)` · `host.apps.launch_or_focus(name|bundleID)` · `host.apps.hide(bundleID)` · `host.apps.frontmost()` → `{ bundleID, name, pid }` · `host.apps.windows(bundleID)` → window count (via Accessibility)
- `host.osascript.run(source)` → `{ ok, output, error }` — AppleScript / JXA bridge
- `host.keyboard.current_source()` → input-source id · `host.keyboard.layouts()` → `{ { id=, name= }, … }` · `host.keyboard.set_source(id)` → bool (Carbon TIS)
- `host.keys.set_rules{ … }` — install the per-extension **key-rule** set (replaces the prior set). `host.keys.stroke(spec)` injects a chord; `host.keys.system(name)` injects a media/aux key (`PLAY NEXT PREVIOUS FAST REWIND MUTE SOUND_UP SOUND_DOWN BRIGHTNESS_UP BRIGHTNESS_DOWN ILLUMINATION_UP ILLUMINATION_DOWN`). Injected events are tagged so they never re-enter the tap (no loops).
- `host.url.open(url [, bundleID])` — open a URL (optionally in a specific browser) · `host.url.default_browser()` → bundle id of the current http handler · `host.url.set_default_browser(id)` → bool
- `host.fs.exists(path)` → bool · `host.fs.attributes(path)` → `{ exists, isDir, size, mtime }` · `host.fs.watch(path, "handler")` — fire a named handler with `{ paths = {…} }` on change · `host.fs.unwatch(path)`
- `host.battery.{source,percentage}` · `host.network.reachable()` · `host.screen.{all,lid_closed}` — read-only
- `host.caffeinate.{prevent_idle_sleep, set_disable_lid_sleep, lock_screen, start_screensaver}` — power / sleep control
- `host.menubar.{set,remove}` · `host.dialog.{prompt,confirm}` · `host.alert.show(text [, seconds])` — host-rendered UI
- `host.log.{info,warn,error}` · `host.env.get(name)`

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

The bundled **url-dispatcher** extension and **hammerspoon-compat** are the worked examples for this surface. User-facing key/media/app shortcuts now live natively in **Settings → Shortcuts → Key Mappings** (the old opinionated `appkeys` / `media-layer` / `app-remaps` system extensions are gone — no hard-coded combos; configure your own, including remapping/swallowing *incoming* media keys). They feed the same `host.keys.set_rules` engine under the reserved owner `com.prosper.shortcuts`.

**System vs user** — bundled features ship as *system extensions*: editable and disablable, **resettable to original**, but never uninstallable. Currently **Calc**, **Unit Convert**, **Base64**, **Currency**, **Translate**, **Open**, **Shell**, **Quicklinks**, **Quickdirs**, **Window Management**, and **URL Dispatcher** are implemented this way; the conversion engines keep a native fallback, so a disabled/edited extension never loses the feature. Any installed extension whose `match` regex accepts the palette query is dispatched on the off-main async lane — that is how Quicklinks (and user extensions) surface as palette commands. (Temperature conversion stays native — Foundation's affine Fahrenheit constants can't be reproduced byte-for-byte in the Lua port.) Currency is the worked example for the async surface — it fetches daily FX over `host.http` (with retry), caches them via `host.prefs`/`host.time`, and runs on the off-main async lane.

**Everything lives in `~/.config/prosper/extensions`** — one editable directory. On launch, bundled system extensions are *copied* there (missing folders only, never clobbering your edits) and loaded from there, so you can open any extension in your editor and change it live. **Reset to original** re-copies the pristine bundled version over your edits. User extensions install into the same directory and remove freely; system extensions can't be uninstalled, only reset.

**Install from GitHub** — paste a repo/subdir URL into **Settings → Extensions** (`github.com/owner/repo`, `…/tree/<ref>/<subdir>`, `.git`, `git@` forms all parse). Prosper fetches the tarball, validates `extension.toml`, installs.
