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

Long-running natives are async, bridged to sync Lua with a hard timeout — extensions run off the main thread.

**System vs user** — bundled features ship as *system extensions*: editable and disablable, **resettable to original**, but never uninstallable. Currently **Calc**, **Unit Convert**, **Base64**, **Currency**, **Translate**, **Open**, **Shell**, **Quicklinks**, **Quickdirs**, and **Window Management** are implemented this way; the conversion engines keep a native fallback, so a disabled/edited extension never loses the feature. Any installed extension whose `match` regex accepts the palette query is dispatched on the off-main async lane — that is how Quicklinks (and user extensions) surface as palette commands. (Temperature conversion stays native — Foundation's affine Fahrenheit constants can't be reproduced byte-for-byte in the Lua port.) Currency is the worked example for the async surface — it fetches daily FX over `host.http` (with retry), caches them via `host.prefs`/`host.time`, and runs on the off-main async lane.

**Everything lives in `~/.config/prosper/extensions`** — one editable directory. On launch, bundled system extensions are *copied* there (missing folders only, never clobbering your edits) and loaded from there, so you can open any extension in your editor and change it live. **Reset to original** re-copies the pristine bundled version over your edits. User extensions install into the same directory and remove freely; system extensions can't be uninstalled, only reset.

**Install from GitHub** — paste a repo/subdir URL into **Settings → Extensions** (`github.com/owner/repo`, `…/tree/<ref>/<subdir>`, `.git`, `git@` forms all parse). Prosper fetches the tarball, validates `extension.toml`, installs.
