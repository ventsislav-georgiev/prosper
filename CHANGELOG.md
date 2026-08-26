# Changelog

Notable changes per release. The release pipeline (`.github/workflows/release.yml`)
reads the section whose heading matches the BASE version being tagged (e.g. `## v2.91.0`)
and uses it as the GitHub Release body, with the auto-generated commit list appended
below it.

The top section is always the **draft for the next version** (`## vX.Y.Z`, no
`-beta` suffix — beta versions are never written here). Every beta of that version
(`vX.Y.Z-beta.N`) and its eventual stable promotion both publish this same draft:
the pipeline strips the pre-release suffix and reads `## vX.Y.Z`. Keep filling this
one draft as you work; each beta just reposts it. A beta whose base version has no
draft section fails the build, so start the next `## vX.Y.Z` draft at the top before
cutting its first beta.

The draft heading is tagged `## vX.Y.Z *(unreleased)*`. The tag is cosmetic — the
pipeline matches on the `vX.Y.Z` substring and never prints the heading line, so it
never leaks into release notes. When you start the next version's draft, drop the
tag from the now-released section and put it on the new top draft.

## v2.141.0 *(unreleased)*

### Improvements
- **Shortcuts**: a new **Extension Commands** section in **Settings → Shortcuts**
  binds a global hotkey that RUNS an extension command outright — no launcher,
  nothing to type. Extensions that list a fixed set of targets are expanded into
  one bindable action each, so a hotkey can open one specific System Settings
  pane, fire one Quick Toggle (dark mode, hidden files, empty Trash…), or run one
  saved script. The default shortcuts extensions ship with (`contributes.keybindings`,
  like OpenLid's ⌘⌥⌃L) are finally visible there too: rebind or turn off any of
  them, and your choice survives a relaunch. Turning an extension off takes its
  shortcuts off the keyboard with it. Menu commands are the one exception — they
  belong to whichever app is frontmost, so there is no fixed list to bind; use a
  Command Shortcut to open the launcher in menu-search mode instead.
- **Screen tools**: two new commands, on the launcher (`:ocr` / `:text` / `:scan` and
  `:color` / `:pick`) and rebindable in **Settings → Shortcuts** (no default key).
  **Copy Text from Screen** drags a region and copies what it holds — QR and other
  barcodes first, then on-device OCR. **Pick Color from Screen** samples any pixel
  and copies its sRGB hex. A result that is a single link offers to open it. Both
  copy to the clipboard, so results land in clipboard history like any other copy —
  keep that in mind when OCR'ing something sensitive.
- **Extensions**: three new events — `system.sleep` (machine about to sleep),
  `screen.locked` (`{locked}`, lock and unlock), and `clipboard.changed`
  (`{kind, text}`, text capped at 8 KB). Clipboard events honour the same
  concealed-clip privacy guard as history, don't turn history on, and don't re-fire
  on a `host.clipboard.write()` from a handler. `host.clipboard.write("")` now
  clears the pasteboard instead of leaving an empty-string item on it.
- **Launcher**: type `ss ` for **System Settings** — all 43 panes (Wi-Fi, Displays,
  Sound, Privacy & Security, Login Items…) listed on an empty query and filtered as
  you type, `⏎` opens the pane. No permissions needed.
- **Launcher**: type `kill ` for **Kill Process** — the top CPU consumers, filtered by
  name or pid. The kill is committed by a trailing `!` (`kill 1234!`, or `!!` to force)
  and then a confirmation dialog, so nothing dies while you are still typing the pid.
  Prosper itself and the system's own critical processes are refused.
- **Launcher**: **Scripts** — save a shell command under a name and run it with
  `sc <name>`; `sc ` alone lists everything saved. Each runs to completion and then
  shows its output. Manage the list in **Settings → Scripts**.
- **Launcher**: **App Updates** — pending Homebrew formulae and casks plus macOS
  system updates in one list, with a command to run `brew upgrade` for all of them.
  Prosper re-checks in the background every 6 hours (configurable) and notifies only
  when something *new* appears; the palette command shows that cached result instantly,
  since the macOS check itself can take a minute. "Check for Updates Now" runs the slow
  path on demand. Off by
  default — turn it on in **Settings → Extensions**; configure it in
  **Settings → App Updates**.
- **Launcher**: **Paste as Plain Text** — strip formatting from the clipboard on the
  way in, without the launcher ever appearing. Two opt-in modes make it the default
  paste behavior: ⌘V pastes plain (⇧⌘V keeps the formatting), or the reverse — ⇧⌘V
  pastes plain and ⌘V is left untouched. Finder is exempt either way, since its ⌘V
  pastes files. Or skip the modes and bind your own chord to the one-shot command in
  **Settings → Shortcuts → Extension Commands**. Needs Accessibility. Note that the
  rich clipboard content is replaced rather than restored, so the styled original is
  gone after the paste.
- **New extension — Clipboard Auto-Clear**: a copied password, OTP or token should not
  still be on the pasteboard an hour later. Clears the clipboard a set time after the
  copy (5 minutes by default), when the Mac sleeps, and/or when the screen locks —
  each trigger switchable — plus a "Clear Clipboard Now" command. Off by default, in
  **Settings → Clipboard Auto-Clear**; turning it on starts the pasteboard poll, and
  concealed clips from password managers are never seen by it.
- **Browser router**: a second toggle, **clean copied links** — copy a link with
  `utm_source`, `fbclid` and friends on it and Prosper writes the clean URL back to the
  clipboard in place. Only a bare link on its own is touched (a link inside copied prose
  is left alone), and only when the cleaned URL actually differs. Off by default and
  independent of the existing cleanup of *opened* links.
- **Launcher**: type `menu ` (or just `m `) and search the frontmost app's menu bar —
  every command in every submenu, fuzzy-matched with its full path shown, and Enter
  presses it. Safari's Export as PDF… is `m pdf` instead of a trip through the File
  menu. Needs Accessibility permission; the index is read fresh per app and cached
  for the session.
- **Shortcuts**: **Hyper Key** — hold Caps Lock and it becomes a modifier chord
  (⌃⌥⇧⌘ by default, configurable), tap it alone for a chosen action: nothing, Escape,
  toggle capitals, or switch to the next input source. Prosper refuses to enable it
  if Caps Lock is already remapped elsewhere (hidutil, Karabiner) rather than fight
  over the key, and the remap is removed the moment the feature — or the app — goes
  away. Off by default, in **Settings → Shortcuts → Hyper Key**; needs Accessibility.
- **System Stats**: a **Disk** module — boot-volume capacity in the menu bar (ramp
  coloured, like CPU and RAM), and a popup with live read/write throughput, a mirrored
  activity chart, session read/written totals, and a per-volume breakdown (used of
  total, free, format, device) that picks up externals as you plug them in. Free space
  is the number Finder shows, not `df`'s — purgeable space counts. On NVMe internals
  the popup also reads SMART: drive health, temperature, lifetime bytes read/written,
  power-on hours, power cycles, unsafe shutdowns and media errors. The popup
  also lists the processes doing the most disk I/O right now, with live read and
  write rates. Off by default; turn it on in **Settings → System Stats → Storage**.
- **Quick Toggles**: eight palette commands for the switches macOS buries — dark mode,
  hidden files, desktop icons, empty Trash (confirmed first), eject all external disks,
  lock screen, screen saver, display off. Fire-and-forget: type, Enter, done. Needs
  Automation access for dark mode and Trash; the command opens the right Privacy pane
  if macOS has it switched off. The extension's settings page carries live switches
  for dark mode, hidden files and desktop icons too, so a toggle is reachable without
  the launcher.
- **Volume Mixer**: a per-app volume mixer in the menu bar — one slider per app that
  is playing, up to 200%, plus mute and a one-click boost. macOS has no per-app volume
  and no API for one, so Prosper taps each app's audio, applies the gain, and plays it
  back through an aggregate device it owns: no plugin, no kernel extension, works for
  any app. The panel also carries the system volume, the output device picker and the
  microphone picker, so it doubles as the sound menu. Because a tap reads audio, macOS
  asks for the audio-recording permission the first time — Prosper records nothing, the
  audio goes straight back out. Off by default; turn it on in
  **Settings → Volume Mixer**, or type `:mixer` (or `:v`) in the launcher. Needs
  macOS 14.4.
- **Volume Mixer**: pick the microphone you want kept selected and Prosper re-asserts it
  whenever it reappears — dock, headset, USB interface — instead of letting macOS hand
  the default input to whatever was plugged in last. The panel's mic button also mutes
  every input at once, and an unmute never opens a microphone you had muted yourself.
  The mute-every-microphone toggle can also ride a global shortcut (unbound by
  default), recorded in **Settings → Volume Mixer**.
- **Volume Mixer**: bind a global shortcut to cycle the sound output across the devices
  you tick in the pane, so speakers → headphones is one chord. Unbound by default.
- **Volume Mixer**: the menu-bar glyph follows the output — AirPods, AirPods Pro and
  AirPods Max each get their own icon while they are the default output, the way the
  native sound icon does, and the speaker returns for everything else.
- **Shortcuts**: **Quit Guard** — require a double-tap of ⌘Q to quit. The first ⌘Q is
  swallowed; press it again within half a second and the quit goes through, so a stray
  ⌘Q no longer takes the window you were working in. Off by default, in
  **Settings → Shortcuts → Quit Guard**; it rides the same key engine as Key Remapping,
  so it needs Accessibility permission.
- **Finder**: three Windows habits for the file manager, each its own switch in
  **Settings → Shortcuts → Finder**, all off by default. **F2** renames the selected
  file. **⌘X then ⌘V** moves files: ⌘X marks the selection, ⌘V drops it into the front
  window. Anything staying on the same disk is moved by Finder itself, so you get
  Finder's own progress window and a real **Edit → Undo Move**; a move to another disk,
  or one that hits a name collision, is done by Prosper instead — the file really moves
  (and a collision is renamed rather than refused), but there is no undo entry for it.
  **⌘V with an image on the clipboard** saves it as
  `Pasted_Image_yyyyMMdd_HHmmss.png` in the front window's folder; copied *files* still
  paste exactly as Finder would. All three fire only with Finder frontmost and no
  filename being edited, and need Accessibility; the move also needs Automation
  permission for Finder, which macOS asks for the first time you use it.
- **Settings**: the sidebar has a search field — `⌘F` focuses it, `Esc` clears it.
  Type part of any pane or section name and the rail turns into a result list; picking one
  switches to that pane, scrolls to the matched section and highlights it for a moment.
  Covers extension settings sections as well, and the index is built from the panes
  themselves, so a new section is searchable without anyone maintaining a keyword list.

- **System Stats**: the process lists in the CPU, RAM, Network and Disk popups can
  now kill — click a process row and the list holds its order (values keep updating,
  rows stop shuffling) and shows a ✕ on that row. The ✕ sends a regular terminate,
  guarded by the same refusals as the `kill` launcher command — never Prosper, never
  the system's critical processes. Click the row again to let the list flow. Needs the
  **Kill Process** extension enabled; when it's off the ✕ is dimmed and says so.
- **Settings**: switching panes is noticeably faster. The window used to lay out every
  section of the incoming pane before showing it — Shortcuts alone holds ~25 shortcut
  recorders — so each switch stalled; now only what's on screen is laid out (worst
  pane 148 → 85 ms in debug measurements).

## v2.139.0

### Fixes
- **Command runner**: ⌘V pasted the clipboard twice — pasting `3+3` typed `3+33+3`.
  The runner routed the Edit shortcuts (⌘A/⌘C/⌘V/⌘X) to the focused field itself,
  a leftover from before Prosper had a real Edit menu; both paths ran, so every
  paste landed twice. The runner no longer routes them — the Edit menu does.

## v2.137.0

### Improvements
- **App shortcuts**: bind a global hotkey that launches or focuses one app directly —
  ⌘⇧D starts DBeaver, no launcher in between. Select an app in the launcher and press
  ⌘⇧K (or **Actions → Assign Shortcut…**), or manage the whole list in
  **Settings → Shortcuts → App Shortcuts**. The only way to do this before was a Key
  Mapping, which needs Accessibility permission and rides the typing event tap; these
  are Carbon hotkeys, so they need no permission, cost nothing while idle, and sync
  across your Macs like the rest of the `shortcut.` settings. A shortcut whose app
  isn't installed on this Mac is left unbound rather than holding the chord hostage,
  and two rows fighting over one chord are flagged instead of one silently never firing.
- **Launcher**: type `settings`, `preferences`, `prefs` or `:s` to open Prosper's own
  Settings — the launcher is the one surface that's always reachable, since ⌥\ is
  rebindable and the menu-bar icon can be hidden.
- **Launcher**: the Actions menu's shortcuts now all work without opening the menu
  first (⌘⇧C copy, ⌘E edit quicklink, ⌘⇧K assign shortcut, ⌘⌫ delete quicklink), and
  per-file actions no longer render a misleading ⌘K.
- **Settings**: the app pickers are searchable — a filter field at the top and a
  scrolling list instead of a menu the length of `/Applications`. Enter picks the top
  match. They also list apps alphabetically instead of in filesystem scan order.
- **Launcher**: ⌘⌥C copies the selected row too. ⌘⇧C stays the advertised shortcut,
  but it's a popular *global* hotkey (password managers, clipboard tools), and an app
  that registers it system-wide takes the key before any app can see it.
- **System Stats**: the battery icon flips between charging and on-battery the moment
  you plug or unplug, instead of waiting for the next battery sample (up to ten
  refresh intervals).

### Fixes
- **Shortcuts**: a settings-sync pull no longer risks being overwritten by an open
  Settings window, and a custom shortcut can no longer be silently rebound to launch
  an app (overlapping internal hotkey ids).
- **Shortcuts**: Escape now closes the "Assign Shortcut" dialog instead of only
  disarming the recorder, and the recorder stops listening for keys once its window
  goes away.

## v2.135.0

### Fixes
- **Remote Terminal**: session clients no longer leak, which also fixes the phone
  showing a narrow, garbled screen that the redraw button couldn't repair. A dch
  session keeps ONE window size and the last client to report it wins, so every
  leftover client kept narrowing the session under the phone actually looking at it —
  dozens piled up over a day. Four things kept them alive, all fixed: a phone that
  left the network without hanging up (sleep, tunnel switch, no signal) was never
  noticed, so TCP keepalive now spots the dead link in about a minute; the byte pump
  waited forever for an acknowledgement that never came, wedging the session's pty;
  a client stuck on that undrained pty ignores SIGHUP, so detaching now escalates to
  SIGKILL (the session and everything inside it are untouched); and clients orphaned
  by a crashed or force-quit Prosper are swept on startup.
- **Remote Terminal**: reconnecting retires the previous client for that session at
  once instead of waiting for the network to time out, so a reconnect can't leave two
  clients fighting over the session's window size.

### Improvements
- **Remote Terminal**: screen snapshots now carry the caret position, so the phone
  paints the input row exactly where the session has it instead of guessing (needs
  dch ≥ 1.5; older dch and sessions started before the upgrade keep the old
  behavior).

## v2.134.0

### Improvements
- **Remote Terminal**: pasting an image from the phone now works without Universal
  Clipboard. The phone sends the copied image to this Mac's clipboard and then the
  paste keystroke, so Claude Code (which reads the clipboard of the machine it runs
  on) finds the picture every time — previously the keystroke went over alone and
  pasted nothing unless macOS happened to have synced the image across.

## v2.133.0

### Improvements
- **Remote Terminal**: the phone can now ask for the *authoritative* screen instead
  of hoping the remote program repaints. dch keeps a full terminal emulation mirror
  of every session, so the server answers a new snapshot request with that rendered
  screen — which fixes the missing characters and the half-blank screen after
  rotating the phone, cases where the TUI believes it already drew those cells and
  never sends them again. The size-jiggle repaint nudge still runs first; the
  snapshot is the backstop.
- **Remote Terminal**: the session list now reports what each agent is doing —
  `working`, `idle`, `blocked` (a prompt is waiting for a human) or `done`. dch
  resolves the state from the session's rendered screen, so it works for Claude
  Code, Codex, Gemini and friends with no setup.
- Ships dch 1.4.0 (agent API: `--read`, `--wait`, `--status`, `--ls-json`).

## v2.132.0

### Fixes
- **Calendar**: the menu-bar date no longer goes stale after the Mac sleeps
  past midnight (it kept showing the previous day until clicked). The midnight
  rollover timer paused during sleep; the icon now re-anchors on the system's
  day-changed and wake notifications, which also covers timezone and clock
  changes, and time-bearing icon patterns refresh immediately on wake instead
  of showing the pre-sleep minute.

## v2.131.0

### Fixes
- **Remote Terminal**: attaching from the phone while a TUI sits on a modal
  prompt (e.g. a Claude Code question) no longer shows a black screen. The
  server now forces a repaint with a brief window-size jiggle — Node/Ink apps
  ignore a same-size redraw signal, so a real size change is the only reliable
  repaint. Also ships dch 1.0.2, which repaints attaches via SIGWINCH instead
  of typing a stray ^L into the session (Claude Code binds ^L to clear-input,
  which flashed "press ctrl+l again to clear" on every reconnect and could
  wipe the conversation).

## v2.130.0

### Fixes
- **Command runner**: the search icon no longer flickers into a loading spinner
  on every keystroke. Fast local results (calculator, app search, quicklinks)
  never show the spinner; it appears only when a request genuinely takes a
  moment (e.g. an AI answer or translation), and once shown it stays visible
  briefly instead of vanishing a frame later. The mode chip also stops pulsing
  while a Quick Chat answer streams.

## v2.129.0

### Fixes
- **Menu bar**: the always-hidden eye toggle now actually works — marking an
  icon moves it into the always-hidden band (and unmarking brings it back),
  instead of doing nothing or sliding it into the wrong section.
- **Menu bar**: the "new icons land here" position is no longer forgotten
  after an app restart.

## v2.128.3

### Fixes
- **Remote Terminal**: when a session's program finished (e.g. typing `exit`),
  the exit notification could be lost in the connection teardown, so the mobile
  app saw a dropped link and reattached — resurrecting the dead session. The
  exit frame is now flushed before the connection closes, so clients end the
  session cleanly.

## v2.128.1

### Fixes
- **Menu bar**: using a revealed hidden icon's popup no longer collapses the
  hidden section instantly — only the auto-rehide timer (or the chevron)
  hides it now; clicking elsewhere never does.
- **Menu bar**: new icons the saved order doesn't know yet (e.g. Now Playing)
  no longer trigger an endless reorder loop — ordering pauses, files them in
  automatically, then resumes. The ordering settings explain this.

### Improvements
- **Menu bar**: new "Auto-rehide" toggle — turn it off and hidden icons stay
  revealed until you click the chevron again.

## v2.128.0

### Fixes
- Fixed the search field's **cursor jiggling** left and right while a Quick
  Chat answer streamed in — the loading icon no longer changes the field's
  position as it animates.

## v2.127.0

### Quick Chat — ask the local AI anything
- **New Quick Chat runner mode**: type `c ` (or `ask `) in the launcher,
  then a question or task, and get a direct answer streamed straight from
  the on-device AI model — a lightweight, ChatGPT-style experience.
- Runs on the **same model as inline autocomplete and translate**, so
  there's no separate download and no extra memory: it loads on first use
  and shares the idle-unload window. Much lighter and faster than the
  coding agent, which loads a separate large model.
- Answers stream in live as they're generated. Single-shot for now
  (each question stands alone).
- **Rich-text answers**: the model's markdown (headings, bullet and
  numbered lists, code blocks, bold/italic) now renders natively instead
  of showing raw `**` / `*` markers.
- Quick Chat no longer flickers between "Thinking…" and the answer while
  you type — it keeps the last answer on screen until the new one arrives.

### Appearance & fixes
- Windows are now **slightly translucent by default** (90% opacity) so they
  sit on your desktop instead of reading as opaque slabs. Change it under
  Settings → Personalization → Transparency.
- Fixed the **memory figure** in Settings → AI Models, which double-counted
  and showed roughly twice a model's real footprint.

## v2.126.0

### Themes for every taste
- **17 new built-in color themes** alongside Default and Amber — a full
  rainbow of dark themes (Crimson, Ember, Gold, Emerald, Teal, Indigo,
  Violet, Rose) plus five light ones (Daylight, Mint, Solar, Lavender,
  Blossom). Pick in Settings → Personalization.
- **Monochrome and accessibility themes**: Graphite (dark gray), Silver
  (light gray), and High Contrast Dark / High Contrast Light with pure
  black/white backgrounds and vivid accents for maximum legibility.
- Theme extensions now live in their own **System Theme Extensions**
  section in Settings → Extensions (expanded by default) instead of
  crowding the system-extensions list.

### Calendar beta feedback fixes
- **Calendar access now works**: the hardened-runtime `calendars` entitlement
  was missing, so macOS never showed the access prompt and Prosper never
  appeared in System Settings → Privacy & Security → Calendars.
- Fixed the **Filled icon style** rendering as a narrow pill with a squished
  day number.
- New defaults: **Outline** icon style with month and day-of-week shown.
- Menu bar icon text is no longer bold — new **Text weight** (Regular /
  Medium / Semibold / Bold) and **Font style** (Default / Rounded /
  Monospaced / Serif) options in settings.
- **More popup contrast**: clearer weekend shading, the selected day now gets
  a visible accent fill and outline (today keeps its bright outline).
- **Day selection actually works now**: the event list follows the day you
  click (it was pinned to today), selection reacts on mouse-up with no
  double-click disambiguation delay, and the first click right after opening
  the popup registers (the popup window wasn't key). Double-click still opens
  the Calendar app.
- Event list shows **1 day by default**.
- Today no longer keeps a selected-looking fill when another day is selected —
  it's marked by its bright outline only; the fill belongs to the selection.
- **Event details**: click an event in the list for the full picture — date and
  time, location, attendees with accept/decline status, a join button for video
  calls, and the event notes with clickable links.
- Added **Itsycal** to the acknowledgements (README + About) as the calendar's
  inspiration.

### New: Calendar
- New opt-in **Calendar** extension: an Itsycal-style menu bar calendar that
  reads your macOS calendars (asks for Calendar access on first enable).
- **Menu bar icon** in four styles — solid day badge, outlined badge, plain
  calendar glyph, or a fully custom datetime pattern (e.g. `EEE, d MMM HH:mm`)
  — with optional month / day-of-week in the badge, or hidden entirely and
  driven by a rebindable global shortcut.
- **Popup month calendar** with event dots (optionally colored per calendar),
  ISO week numbers, highlighted weekend/custom days, first-day-of-week
  override, adjustable text size, and a resizable 6–10 week grid — drag the
  handle under the grid. Double-click a day to open it in Calendar.app; pin
  the popup to keep it open.
- **Agenda list** below the grid shows the next 1–31 days (or today only):
  all-day capsules, tentative rings, calendar colors, locations, and one-click
  join buttons for Zoom / Meet / Teams / Webex / FaceTime links.
- Choose exactly **which calendars appear** from a per-source checklist in the
  extension's settings.

## v2.125.0

### New: Migration Assistant
- New opt-in **Migration Assistant** extension imports your quicklinks and
  snippets from **Raycast** or **Alfred**, with guided steps for each app's
  export flow (also reachable from the launcher: "Import from Raycast or
  Alfred"). Imports merge — existing quicklinks (same name) and snippets (same
  name or keyword) are never overwritten, so re-running is always safe.
- **Raycast:** import the plain JSON files written by Raycast's "Export
  Quicklinks" / "Export Snippets" commands (file type auto-detected), or a
  full password-protected `.rayconfig` backup — the export password is asked
  for in a native dialog and never stored. `{argument}` placeholders are
  converted to Prosper's `{query}`.
- **Alfred:** one click imports custom web searches (as quicklinks) and
  snippet collections straight from Alfred's preferences on disk — no export
  step needed. Exported `.alfredsnippets` files are also accepted, and
  collection keyword prefixes/suffixes are preserved.
- Extensions can now read and add quicklinks through the new
  `host.quicklinks` API (`all()` / `save{}`), same shape as `host.snippets`.

### AI Models
- Tidier model rows: secondary actions ("Use for inline", "Reveal in Finder")
  now live in a "…" menu next to the primary button.
- Picking a not-yet-downloaded inline model now starts its download in the
  same step, so autocomplete can no longer be pointed at a missing file.
- The model rename flow was removed.

## v2.124.1

### Fixed
- **Quitting the app no longer crashes.** Since the llama.cpp engines keep a
  model resident, every normal quit tripped an abort inside llama.cpp's Metal
  teardown during process exit and filed a crash report. Process shutdown now
  skips that teardown entirely after Prosper's own cleanup completes.
- Disabled buttons in Settings now look disabled (dimmed/desaturated) instead
  of silently ignoring clicks.

### AI Models
- The loaded-model RAM badge now counts llama.cpp models too (it previously
  only saw MLX memory, under-reporting while a GGUF model was resident).
- New "Reveal" / "Reveal in Finder" actions show a downloaded model's files
  on disk.
- Only one model download can run at a time across both engines (GGUF and
  Hugging Face) — the other Download buttons disable while one is in flight.
- Starting an agent run now also releases the inline llama.cpp model before
  the agent model loads (one resident model at a time); inline reloads lazily
  on the next keystroke after the run.

## v2.124.0

### Coding agent — llama.cpp engine
- **The coding agent now runs on the same llama.cpp engine as inline
  autocomplete.** Tool calls are grammar-locked during decoding — a malformed
  call is structurally impossible, so the old parse-repair round-trips (each a
  full prompt re-read) are gone. Repeated turns reuse the prompt cache, and the
  KV cache runs quantized with flash attention, cutting per-turn latency and
  memory.
- **New GGUF model catalog for the agent.** Seven coding-tuned models from
  2.7 GB to 45 GB: Qwen3.5 4B, Nemotron 3 Nano 4B, Qwen3 8B, Qwen3-Coder
  30B-A3B (recommended), Nemotron 3 Nano 30B-A3B, Qwen3-Next 80B and
  Qwen3-Coder-Next 80B. The former MLX list is retired; an existing selection
  migrates to the recommended model automatically. Custom models imported from
  a Hugging Face URL keep working unchanged.
- **Fixed the chat window freezing during fast replies.** Small models stream
  faster than the transcript could lay itself out, blocking the whole window;
  streamed text now renders in coalesced batches and the window stays
  responsive.

### System stats
- **Separate "Sensors interval" for temperatures and power.** The priciest
  sensor reads can now sample slower than the main update interval, and the
  network ping follows the update interval instead of firing every second.

## v2.123.0

### Inline autocomplete — a new completion engine
- **Completions now run on a purpose-built llama.cpp engine.** Each request
  explores several continuations in parallel (threshold beam search), ranks
  them by model confidence, and shows the winner only when it clears a
  confidence gate — when the model isn't sure, you see nothing instead of
  junk. The word under your cursor is enforced byte-by-byte, so a suggestion
  always continues exactly what you typed.
- **Suggestions update instantly on each keystroke.** The prompt is built so
  everything before the text you're typing stays byte-identical between
  keystrokes, letting the model's cache carry over — each key costs a tiny
  incremental prefill instead of re-reading the whole prompt. Median
  suggestion latency is ~300 ms end-to-end.
- **One model now powers both inline autocomplete and Translate — and you
  can pick its size.** Settings → AI Models offers a Gemma 4 GGUF catalog
  (E2B/E4B, 4-bit and 8-bit, 3.3–8 GB) with per-model download, delete and
  switch; the Completions and Translate settings share the same picker and
  swap models without a restart. Bigger models translate noticeably better
  at some cost in suggestion latency. The MLX engine and its model catalog
  remain dedicated to the coding agent and chat.
- **Translate produces proper results again** (e.g. "incarnation" gives
  въплъщение with alternatives and explanations): the new engine was framing
  its translation prompts with the wrong chat markers for this model's
  vocabulary, so the model saw them as literal text and answered nonsense or
  nothing.
- **Translate now shows results as they arrive.** The best translation
  appears the moment it's ready (typically ~1 s), with a live progress row
  — inline spinner plus honest stage labels ("Loading model…",
  "Translating…", "Finding alternatives…") — while alternatives and
  explanations are still generating; no more generic "(done)" placeholder
  flashing between keystrokes. Candidates gluing Latin and Cyrillic letters
  into one word (model garbage) are filtered out, and the "Detected:"
  language chip now comes from the on-device recognizer instead of the
  model's often-wrong guess. Entering translate mode also no longer loads
  the 4 GB chat model it never uses.
- **Editing mid-document no longer overflows the model window.** The text
  after the cursor is capped to a short head, and the context budget accounts
  for every prompt piece (with a realistic Cyrillic characters-per-token
  estimate), so the model never loses its instructions mid-request.

### Inline autocomplete — steady ghost, inline typo correction
- **The ghost no longer flickers or swaps while you type it out.** Its glyphs
  are laid out once; a matching keystroke or Tab just turns the consumed
  prefix transparent in place — no wiggle, no re-layout, no breathing.
  Backspace un-consumes, deleting then retyping keeps the same suggestion,
  and accepting a word with Tab can no longer pull in a different ghost or
  make the remaining text jiggle.
- **The ghost extends itself instead of running dry:** when you've nearly
  typed through it, a continuation is appended in place and the panel grows —
  no gap while a new suggestion is fetched.
- **Typos are corrected inline while you type.** A misspelled word gets a red
  strike bar with the corrected word in green after it, followed by the gray
  continuation — Tab accepts just the corrected word and the suggestion keeps
  flowing. A suggestion that is a close edit of the word you just typed is
  treated as a correction rather than glued on as a new word, and
  abbreviation-like tokens the system spell checker tolerates (e.g. "tte")
  get a proper fix instead of garbage.
- **Sentences you've already written this session complete instantly** — a
  retyped opening recalls the rest of the sentence with no model call. The
  recall buffer is per-app and never leaves the machine.
- **Accepting suggestions now always inserts plain spaces.** In some apps the
  insertion path used non-breaking spaces, which made every later Tab appear
  swallowed and leaked odd spaces into sent messages.
- **The ghost now renders at the right size and position in Slack** (and
  other Chromium-based apps): the font size is derived from the caret box
  with the correct scale factor, plus a per-app baseline nudge — and a
  per-character glyph mirror handles fields that report no caret geometry,
  including full-screen auxiliary windows.

### Inline autocomplete — language discipline
- **Suggestions are constrained to your keyboard languages.** The model can
  only produce words in the languages you actually have input sources for
  (e.g. English + Bulgarian), and Bulgarian no longer drifts into Russian —
  suggestions containing Russian-only letters (ы/э/ё) are rejected from the
  first keystroke.
- Suggestions appear only at the end of a line — never injected into the
  middle of a sentence you're still editing — and every attempt has a hard
  ~1 second budget, so slow retries are cut off instead of arriving after
  you've moved on.
- **More garbage classes rejected before they render:** suggestions quoting
  text visible on screen (the OCR'd conversation) instead of continuing
  yours; words blending two alphabets ("могամ"); a capitalized new sentence
  glued onto your unfinished word; markdown junk at the edges or interior;
  suggestions that merely re-type the text already after your cursor.

### Translate — sharper output
- **Translations can no longer drift into a sister language's alphabet.**
  Letters that don't exist in the target language (e.g. Russian-only ы/э/ё
  in Bulgarian output) are banned at decode time — the model cannot produce
  them at all, instead of being cleaned up afterwards.
- Translate runs on the same llama.cpp engine and model as inline
  autocomplete, so one download serves both and the coding agent's models
  stay untouched.

### Stability
- **Fixed a crash while typing** (`Range requires lowerBound <= upperBound`
  in the model's KV cache). Ending a completion early abandoned the
  library's background generation task, which kept writing into the same KV
  cache being trimmed for reuse; all generation paths now cancel and join
  that task before touching the cache.
- **Fixed a crash when inline autocomplete and the coding agent (or
  translate, OCR, LoRA training) computed at the same time.** MLX's
  compiled-kernel cache is process-global and not thread-safe; all MLX
  compute now runs through one process-wide gate, so exactly one evaluation
  touches the GPU at a time.

### System Stats — sensors & fan control
- **Temperature sensors now have proper names** matching exelban/Stats:
  Airflow left/right, NAND, Battery 1/2, Airport, per-core CPU efficiency/
  performance labels — plus synthetic "Average CPU/GPU" and "Hottest CPU/GPU"
  rows.
- **Temperature kill-switch for manual fans:** if any sensor reaches 95 °C
  while fans are manually pinned, the helper unconditionally returns them to
  macOS control.
- **Manual fan control now notices when macOS takes the fans back** (thermal
  event, sleep). The helper re-asserts your target once; if the OS insists,
  the UI honestly flips to Automatic with a note instead of showing a manual
  state that isn't real.
- **Fan RPM feedback is faster:** while manual control is on, the readout
  updates every refresh tick, so the ramp is visible immediately.
- **New opt-in "Fast manual fan re-engage"** checkbox (Sensors settings,
  default off): keeps the fan controller unlocked after switching back to
  Automatic so re-enabling Manual is near-instant instead of ~8 s. The held
  unlock is supervised by the helper and fully released on quit, sleep or
  disable.
- Performance round: fixed a mach-port leak in the CPU sampler, cached GPU
  and sensor lookups on the per-tick hot path, and added hot-path budget
  tests.

### Menu bar management — ordering that doesn't fight you
- **Reordering passes are now non-disruptive:** they run only while the mouse
  is quiet, skip the cursor entirely when nothing needs moving, and your own
  drag-reorders (and newly appeared icons) are adopted into the saved order
  instead of being fought and reverted.
- Fixed icons becoming click-through after an ordering pass, a race with
  chevron-collapse, ordering churn from unstable icon fingerprints, and
  battery-wasting passes when nothing changed.

### Open lid / power — helper hardening
- Keep-awake status HUD now reports the real state, including a new watch
  mode; fixed a stuck sleep latch, wake re-assert of the lid override, a
  keychain race on the account tag, XPC double-close spam, and a stale
  "Sleep now" settings pane.

### Window layouts — polish
- Layout palette position names fixed (e.g. "Center"), drag-start preference
  snapshots so mid-drag settings changes can't corrupt a drop, and zone
  geometry made deterministic (preview now always matches the drop).

## v2.122.3

### Inline autocomplete — instant, always-on suggestions
- **The first ghost now fires on the first keystroke** — no debounce, no
  throttle window. When no request is running, every keystroke launches the
  fast completion pass immediately; while one runs, the next is queued and
  chains the moment it lands. You never have to pause typing for a suggestion
  to appear; pausing only upgrades the current one with a full-quality pass.
- **Removed the orange "failed" indicator for empty results.** The model
  finding nothing to suggest is a normal outcome, not an error — the accessory
  now stays quiet instead of flashing orange.

### Inline autocomplete — review hardening
- **Fixed a latent stuck-state** where an abandoned suggestion request (emoji,
  spelling-fix, or typo paths) could leave autocomplete idle for up to 3 seconds:
  the in-flight tracking is now reset the moment a request is superseded.
- **Echo suppression now only checks recently written text** (the context the
  model actually saw), so reusing a phrase written much earlier in a long
  document no longer blocks a legitimate suggestion.
- The suggestion indicator no longer stays stuck on "thinking" when a retry
  comes back empty while a valid ghost is already on screen.

## v2.122.2

### Inline autocomplete — faster, more reliable ghost suggestions
- **Fixed typing lag while autocomplete is on** (noticeable in Safari and other
  heavy apps). Suggestion work — lexicon lookups, accessibility reads, ghost
  rendering — was running inside the keyboard event tap callback, delaying every
  keystroke system-wide. That work is now deferred off the tap; key delivery is
  no longer blocked by suggestion computation.
- **Ghost completions now appear while you type, not only after you pause.**
  Every new keystroke used to cancel the in-flight model request, so during
  continuous typing no request ever survived long enough to land. Requests are
  now pipelined: a request whose context you've merely extended keeps running,
  and a fresh one is fired as soon as it lands.
- **Mid-typing requests are lighter.** Burst-throttled requests use only the fast
  first sampling pass instead of the full retry ladder, keeping the model
  responsive; an empty burst result no longer flashes the orange error accessory.
- **Fixed suggestions echoing what you just wrote** (most visible in Bulgarian).
  The echo guards compared against a stale snapshot of the text and were
  punctuation-sensitive; they now check the live field content at render time and
  ignore punctuation differences.
- **Reduced per-request database work.** Writing-style samples are cached for a
  short window instead of being re-queried from the history store on every
  suggestion request.

## v2.122.1

### Inline autocomplete — smarter, more coherent suggestions
- **Rebuilt the completion sampling around Gemma 4's own recommended settings**
  (temperature 1.0 with top-k/top-p nucleus shaping). The suggestion engine now
  uses a two-tier, language-aware ladder: it keeps a fast, deterministic first pass
  for high-confidence completions in English and Cyrillic Bulgarian, and switches to
  the model's native sampling when a pass comes back empty — so suggestions read
  more naturally and stop collapsing into repeated or fragmentary text.
- **Fixed Latin-script Bulgarian ("shlyokavitsa") drifting into Cyrillic.** Typing
  Bulgarian in Latin letters no longer produces mixed-script or Cyrillic suggestions;
  coverage in this mode now matches the rest.
- **Suggestions can now be grounded in how you actually write.** When typing history
  is enabled, Prosper draws on a rolling sample of your own recent phrasing (kept
  on-device, capped, and evicted least-recently-used) to better match your voice,
  tone, and language — including Latin-script text. It never copies your samples back
  verbatim, and never leaks its own internal instructions into a suggestion.
- **Snappier while typing.** Completion requests are throttled with a bounded max-wait
  so keystrokes stay responsive under load, and the language of the surrounding text
  is inferred more reliably.

## v2.121.0

### Menu Bar Management
- **New "Menu Bar Management" extension (opt-in).** Hide menu-bar icons behind a
  divider you can show on demand, add spacing between icons, and pick the collapsed/
  expanded chevron style — all with no Accessibility or Screen Recording permission.
  A live preview strip in Settings shows your real icons in order. Ships **disabled**
  — it adds nothing to your menu bar until you turn it on in Settings › Extensions.
  The clickable chevron is a separate, always-on-screen item from the invisible
  separator that does the hiding, so showing/hiding your icons never sweeps the
  chevron (or Prosper's own icon) off the screen — click it to show/hide.
- **Mark any icon "always hidden" from Settings.** In the saved-order list, click
  the eye next to an icon to keep it permanently off the bar (it moves behind an
  always-hidden separator and never shows, even on reveal); click again to bring it
  back. You pick the exact icons instead of dragging across an invisible divider.
  Needs the move test passed.
- **Hidden divider in the saved-order list.** The list shows the hidden-section
  divider as a draggable row: icons above it are hidden behind the chevron, icons
  below stay visible. Drag the divider (or icons across it) to choose what's hidden,
  and Prosper drives the real bar to match — no ⌘-dragging in the menu bar. The
  divider's position is captured from your real bar on "Save current order", so the
  list mirrors where you already put things, including icons you'd already dragged
  behind the chevron.
- **The live preview shows each icon's real picture on macOS 26 (Tahoe)**, where the
  system hides per-app identity, by capturing the icons directly (needs Screen
  Recording — there's an in-place prompt; without it you get placeholder glyphs).
  Icons keep their real proportions instead of being squished into squares.
- **Spacing applies on next launch when macOS hides app ownership.** On macOS 26
  (Tahoe) "Apply now" can't relaunch the apps to re-space them, so it says so — the
  spacing is still saved and takes effect on next launch / login.
- **Item ordering that survives relaunch, including multi-icon apps (experimental).**
  Apps like Stats or iStat Menus publish several icons that macOS normally shuffles
  on every launch. Turn on ordering, arrange your icons once, and Prosper keeps them
  in place. It's opt-in, only enabled on macOS versions it has verified it can drive,
  and self-tests on a throwaway icon at startup — if the move can't be performed
  reliably on your Mac it disables itself rather than fighting the system.
  - On macOS 26 (Tahoe), where the system no longer tells apps which icon is which,
    Prosper rebuilds each icon's identity from its picture (this is the only part
    that asks for Screen Recording, and only when you use ordering).
  - Prosper's own icons (Stats modules, extension icons) appear in the order list and
    live preview with their real names and pictures — named and drawn directly (no
    Screen Recording needed).
  - **On chevron click** mode restores your order each time you click the chevron to
    show hidden icons; **Live** mode also snaps icons back if they drift. Live mode
    stays gentle: it backs off on battery, and a circuit breaker parks it if a move
    keeps failing so it can never spin the CPU.
  - Applying a saved order restores both the left-to-right order and the hidden
    section in one pass: icons are put in order, the divider drops at its saved
    boundary (just left of your first visible icon), and the always-visible chevron is
    re-seated on the visible side so the click target (and your Prosper icon) can never
    be swept into the hidden band. Order is judged relative to each icon's neighbors
    rather than by physical adjacency, since system icons (Control Center, the clock)
    can split managed icons into groups that can't ever sit flush.
  - Ordering work runs on a fast path that, in steady state, avoids the expensive
    system-wide window scan — so the background order check doesn't add input lag
    while you type.

### System Stats
- **New "System Stats" extension (opt-in).** Native menu-bar system monitors in
  Prosper's style — CPU, memory, GPU, network, temperatures, fans, battery, and
  power. Pick which modules show and in what order. Ships **disabled**; turn on the
  ones you want in Settings › System Stats. Built entirely on public and on-device
  APIs — no Accessibility, Screen Recording, or root access just to read your stats.
- **A detail popover behind each menu-bar item.** Click a module for a live history
  chart and a full breakdown:
  - **CPU** — per-core load bars, system/user/idle split, efficiency vs performance
    cores with their live clock speeds, plus load average and uptime.
  - **Memory** — app/wired/compressed stacked usage, cached files, the real kernel
    memory-pressure level, and swap used/total.
  - **GPU** — utilization with renderer and tiler breakdown, a Neural-Engine
    utilization estimate, VRAM in use, core count, and frames-per-second presented
    to the display.
  - **Network** — up/down throughput with a mirrored area chart, live latency and
    jitter with an internet-reachability badge, a connectivity-history grid, total
    transferred, the active interface with its hardware (MAC) address and Wi-Fi
    signal, local and public IP with country flag, and a per-process download/upload
    list. Latency is measured with unprivileged ICMP; the public-IP lookup is an
    outbound request that runs only while the Network popover is open.
  - **Sensors** — the full temperature list, current fan speeds, and labeled voltage
    and current rails (DC in, system, memory, display).
  - **Power** — live CPU, GPU, Neural Engine, and DRAM wattage with the total.
  - **Battery** — charge, health, cycle count, live power draw, voltage, amperage,
    capacity, power-adapter wattage, and time remaining.
- **Reads stay light.** Every sampler runs in microseconds and the menu bar updates
  once a second, so the monitors don't add measurable load to the thing they measure.
  Expensive sources (frequency, frame rate, power) sample on a throttled background
  tick and the voltage/current reader probes only the rails your Mac actually has.
- **Menu-bar items styled like a polished system monitor.** A small label sits above
  its value, coloured by the module's thresholds, with fixed widths so a reading going
  from "9%" to "100%" doesn't resize the item and shove its neighbours around. The
  left/center/right alignment positions the value under its label. Network shows upload
  over download with a trailing ↑/↓ arrow; battery draws as a glyph.
- **Popovers open flush beneath their menu-bar item** and match a polished
  system-monitor look 1:1: a header strip with a bar-chart glyph, a centered title, and
  a settings gear; circular gauges for the primary metric (CPU shows three —
  temperature, a system/user split usage donut, and load); per-core load bars under the
  usage-history chart, coloured by efficiency vs performance cluster; colour-dot
  legends; average load and per-cluster clock frequency sections; and a top-processes
  list with each app's real icon. Temperatures, voltages, and currents are formatted
  like the reference (37.3°C, 27.827V, 0.38A). **Memory** shows a pressure half-gauge
  beside an app/wired/compressed usage donut; **GPU** shows render, utilization, and
  tiler dials with the chip model; **Network** shows big download/upload readouts over a
  mirrored up/down history chart with peak labels; **Battery** shows a large glyph with
  a charging pill and grouped Details / Battery / Power-adapter sections.
- **Per-process CPU% reads like Activity Monitor** — percent of a single core, so a
  multi-threaded process can read above 100%.
- **Manual fan control lives in the Sensors popover** — each fan shown with a speed bar
  and an Automatic/Manual control (with confirmation and automatic-reset safeguards).

### Launcher & Clipboard
- **Clipboard History and the command runner now open on the screen you're using.**
  On a multi-monitor setup they used to pop up centered on the main display
  regardless of where your cursor or focused window was. By default they now open
  on the screen under the pointer, like Raycast and Ditto — and they still remember
  the exact spot you dragged them to, reopening there as long as the cursor is on
  that same screen (so you can park one for side-by-side work). Move to another
  screen and it follows the pointer there. A new **Panel placement** setting
  (Settings › General) lets you choose "Screen under the cursor" (default), "Last
  position I moved it to", or "Main screen".

### Inline Autocomplete
- **Ghost text no longer vanishes while you type fast.** The biggest cause of
  "sometimes no suggestion appears" was that a completion arriving a moment after
  you'd typed a few more characters was thrown away as stale, leaving a blank.
  Late responses are now reconciled against your current text: the part you've
  already typed is trimmed off and the rest is shown, so the suggestion keeps up
  with your typing instead of disappearing. (Inspired by VS Code's inline-completion
  handling.)
- **Accepting a suggestion can never insert the wrong text.** When you press Tab or
  →, the suggestion is re-checked against the field's live text at that instant; if
  the context has drifted (a click, a paste, an app that updated its text behind the
  scenes), the keypress refreshes instead of typing something stale into the app.
- **The suggestion delay now adapts to how fast the model is responding.** A snappy
  model stays near-instant; a slower one waits a touch longer so it isn't spammed
  with requests. A one-off slow first response (e.g. the model loading) no longer
  drags the delay up for the rest of the session.
- **No more error flash when a still-valid suggestion is on screen.** If the model
  returns nothing but a good suggestion is already showing, it's kept rather than
  replaced with an error indicator.
- **Mid-word suggestions are handled quietly.** When the model proposes a new word
  while you're mid-way through typing one, it's skipped without flashing an error
  and without the wasteful retry loop that could keep the GPU busy while you sat idle.
- **The first keystroke after enabling autocomplete is more reliable.** The model is
  now ensured loaded before the first completion attempt, closing a cold-start gap
  where the very first request could be silently dropped.
- **Clear status while the coding agent is running.** When the local coding agent is
  using the GPU, the inline indicator now shows a paused state instead of an error —
  suggestions resume automatically when the agent finishes.
- **New verbose troubleshooting trace for autocomplete.** With "Verbose troubleshooting
  log" enabled (Settings → About), the autocomplete pipeline now records exactly why a
  keystroke produced no suggestion (field unsupported, context drifted, model paused,
  empty result, …) and what the model returned, so flaky cases can be diagnosed.

### Clipboard History
- **Arrow keys no longer jump the cursor in the filter field while you navigate.**
  Pressing ↑/↓ moved the selection but also sent the key through to the search box,
  yanking the caret to the start or end of what you'd typed. The keyboard handler now
  fully consumes navigation, commit, and shortcut keys (a flattened-optional bug had
  been silently letting them fall through).
- **Typing in the filter now keeps the first match selected.** When the filtered list
  changed, selection stayed pinned to an item that was no longer visible — the preview
  showed the top entry but nothing was highlighted. Selection now snaps to the first
  match (and scrolls the list back to the top) whenever the previously selected entry
  drops out of the filter.
- **Every selected row now reliably shows its selection box.** Some entries (often
  duplicate copies) kept the highlight card stale or missing while the position-key
  badge moved on. Rows now track selection directly, so the highlighted card always
  matches the actual selection.

### Window Layouts
- **The layout/palette overlay now appears the instant a window actually starts
  moving — reliably, and only for real window drags.** It used to wait on a poll
  that gave up after ~10 samples with no movement, so a slow or hesitant drag
  expired the poll before macOS had begun moving the window and the overlay never
  showed (the "click, nothing; release, retry, then it appears" flakiness). That
  poll no longer aborts the gesture, so the overlay shows the moment the window
  moves. Just as important, it shows *only* when the window moves: a text-selection
  drag in a terminal or editor (e.g. Ghostty) no longer pops the palette, since the
  window never moves.
- **Drag-snap now works on apps that don't expose their windows to accessibility**
  (e.g. Telegram and other Qt-based apps). These apps report no accessibility element
  under the cursor, so the drag couldn't even tell *which* window you'd grabbed — the
  gesture was dropped before any overlay could show. Drag-snap now identifies the
  window from the window server (which tracks every on-screen window) and reads its
  live position from there, falling back to that path whenever accessibility comes up
  empty. The palette and snapping work for those windows now, while a non-moving drag
  (text selection, a scrollbar) still triggers nothing.
- **The palette drop preview no longer promises a resize that won't happen.** For a
  "Move only" layout (reposition, keep size) the preview footprint showed the full
  resized zone instead of where the window would actually land. It now matches the
  real move-only placement. Reminder: a layout that only moves and never resizes has
  **Move only** enabled in the layout editor — uncheck it to resize windows into the
  zone.
- **Higher-contrast layout palette.** The palette strip's backdrop is more opaque and
  the gaps and outlines between panes are now black, so each drop target reads clearly
  against the accent-highlighted cells (the strip stays translucent over your desktop).
- **Fresh installs start on the layout palette.** A brand-new install now defaults the
  drag-snap mode to the layout palette so the feature is discoverable out of the box.
  Existing and upgrading users keep whatever mode they were on — the default is only
  seeded on a genuine first launch.

### Keep Mac Awake (OpenLid)
- **A remotely-woken Mac now stays awake until you sleep it — no more dropping the
  connection a few seconds after you reach it.** The instant a remote wake fires, the
  helper now holds the Mac awake *stickily* as root, before your terminal has even
  reconnected, and keeps holding it regardless of whether the app's keep-alive
  heartbeat is delayed or its link to the helper is still re-establishing across the
  wake. The hold stays until you explicitly sleep the Mac (`prosper://sleep` / "Sleep
  this Mac now") or open the lid — exactly the two moments you'd want it back asleep.
  Remote wake itself is left completely untouched, so you keep waking and sleeping the
  Mac remotely at will.
- **The "held awake by a remote session" state now resets the moment you open the
  lid.** That keep-awake exists only to stop a *closed-lid* Mac from sleeping, so it
  made no sense to keep holding once you're sitting in front of an open lid. Opening
  the lid now releases it immediately (and a hold is never taken while the lid is
  open), so normal sleep resumes as soon as you're physically using the Mac.
- **A remotely-woken Mac no longer falls back asleep mid-session.** After the app
  restarted (e.g. following a remote wake), it forgot that the background helper was
  still armed, so the "keep awake while a session is live" hold quietly no-op'd and
  the Mac slept a few seconds after you connected — even with open `dch` sessions.
  The app now re-establishes that link on launch, so the hold actually reaches the
  helper and the Mac stays awake while work is running.
- **Remote wake no longer silently switches itself off after the first wake.** Remote
  wake could wake the Mac once and then never again, while the checkbox and Status
  still showed it "on". Cause: on every launch the app re-applied the remote-wake
  setting, and if the sign-in key happened to be momentarily unreadable at that instant
  (common right after a wake) it was misread as "signed out" and disarmed the
  background helper's saved config — killing the dark-wake while the UI kept claiming
  it was armed. A transient unreadable key is now left alone: only a real sign-out or
  an explicit toggle-off ever disarms, so a Mac you armed stays wakeable across
  restarts and wakes.
- **Status now lists your remote terminal sessions.** A new "Remote sessions" line in
  the Status group shows each live `dch` session and which ones Prosper currently
  counts as *active* (producing output within the keep-awake window) — so you can see
  exactly when a session is holding the Mac awake versus sitting idle.
- **Settings redesigned so the on/off state is honest and the controls are clear.**
  The old "Right now" section showed Prosper's stored intent, which could say "off"
  while the Mac was still being held awake by something else — and the manual toggle
  sometimes appeared to do nothing. The pane is now split into three plainly-labelled
  groups:
  - **Status** — read-only. Shows what the Mac is *actually* doing right now (read
    from the system, not a stored flag) and *who* is holding it awake: the plugged-in
    rule, a manual switch, a timed session, a remote session, or an external/stale
    hold.
  - **Controls** — the manual on/off switches, separate from the status.
  - **Turn on automatically** — the launch/power rules.
- **"Keep awake while plugged in" is now its own checkbox.** It replaces the old
  three-way "at launch" dropdown with two independent checkboxes ("Keep awake while
  plugged in" and "Turn on at every launch"), so it's obvious which can be on
  together. While the charger is connected and this rule is on, the manual switch
  locks (with the reason shown) so an accidental toggle — or the keyboard shortcut —
  can't sleep the Mac out from under you; unplug, or turn the rule off, to release it.
  The menu bar matches: while the plugged-in rule owns the state, the menu shows
  "kept awake while plugged in" with no "let sleep" action, so it can't fight the
  lock either. Existing settings migrate automatically.
- **Status is clearer at a glance.** Each item shows a bold ON/OFF badge instead of
  burying the state in fine print, the Status section now lists Remote Wake too, and
  flipping a control updates the status immediately. The Permissions group is
  collapsible and sits at the top of every settings page — folded away once granted,
  opened automatically when something still needs your approval — and toggling a
  checkbox no longer jumps the scroll position.
- **New "Sleep this Mac now" button — the off-switch for a stuck "held awake" state.**
  Keeping the Mac awake has more than one holder: your own switch, *and* a hold that's
  kept while a remote `dch` terminal session is live (so a Mac you woke remotely
  doesn't sleep mid-command). The manual switch only ever released its own hold, so a
  Mac held awake purely by a remote session had no off-switch — nothing you clicked
  turned it off. The new button (Controls) releases **every** hold and sleeps
  immediately, inside the privileged helper as root so the Mac actually goes down on
  the first click (not just the display) and stays asleep — re-triggers like a `dch`
  client reconnecting or the "keep awake while plugged in" rule are suppressed until
  the Mac genuinely wakes again. Your detached sessions are left running and reconnect
  on the next wake; remote wake is untouched, so an armed Mac stays wakeable. The
  Status line says so honestly ("Held by a remote session or another app") instead of
  guessing.
- **Sleep this Mac remotely.** Running `open prosper://sleep` on the Mac (e.g. from
  inside your remote `dch` session) does the same thing — releases the holds and puts
  it to sleep — so you can wake it, do your work, and send it back to sleep without
  touching it. Tip: add `alias prosper-sleep='open prosper://sleep'` to your shell.

### Troubleshooting
- **New verbose trace mode (Settings → About → Troubleshooting), off by default.**
  When a remotely-woken Mac won't wake or won't stay awake, flip this on and the whole
  remote-wake / keep-awake story is written to the unified log across both the app and
  the privileged helper. The About pane gives you the exact command to read it back:
  `log show --last 1h --predicate 'eventMessage CONTAINS "ProsperTrace"'` (with a Copy
  button). The trace records the dark-wake decision (why each wake slept or promoted:
  debounce, battery floor, poll result, token check), the keep-awake hold and its
  heartbeats, and the smoking-gun "hold expired" line when the Mac re-sleeps because
  the app went away or the network dropped. The flag survives a helper restart and a
  dark wake, and adds zero cost when off.

### Settings
- **Toggling "Launch at login" no longer freezes the Settings window.** The toggle
  ran macOS's login-item registration (`SMAppService.register`) synchronously on the
  main thread — a slow system call that locked the UI for several seconds. The toggle
  now flips instantly and the registration happens off the main thread.
- **The accessibility "Reset & re-add" button no longer freezes Settings.** It spawned
  `tccutil` and blocked waiting for it to finish on the main thread; the subprocess now
  runs off-main and the UI stays responsive.

### Coding Agent
- **Ten new models to choose from.** Ornith-1.0 (9B and 35B-A3B — DeepReinforce's
  self-scaffolding coding models), OpenAI's gpt-oss (20B and 120B), GLM-4.7-Flash,
  GLM-4.5-Air and GLM-4.6, Qwen3-Next 80B-A3B, the December Devstral Small 2 24B, and a
  higher-fidelity 6-bit build of Qwen3-Coder 30B-A3B — spanning the 16 GB tier up to
  very-large-RAM Macs.
- **The model picker is now always sorted smallest to largest.** Models — including any
  you add yourself via a Hugging Face URL — are ordered by their RAM footprint, so the
  list reads top-down by size and custom models slot into the right place instead of
  trailing the end.

### Input Switcher
- **New "Input Switcher" extension (opt-in).** Automatically set your keyboard input
  source by focused app: pick one default input for every app, then add per-app
  overrides — choose an app from a picker and the input source it should use. When that
  app comes to the front Prosper switches the layout for you, and switches back to your
  default elsewhere. A native take on the common Hammerspoon input-switching recipe.
  Ships **disabled** — turn it on in Settings › Extensions.

### URL Dispatcher
- **Optional tracking-parameter cleanup.** A new "Remove tracking parameters" toggle
  in the URL Dispatcher settings strips analytics and click-tracking junk
  (`utm_*`, `fbclid`, `gclid`, `mc_eid`, `igshid`, and ~90 more from the AdGuard/
  ClearURLs lists) from links before they're opened — so the page never sees them.
  Only known trackers are removed; functional parameters are kept untouched. Off by
  default. A native take on the Hammerspoon URL-cleanup recipe.
- **Now ships disabled.** The extension hijacks the system default browser, so it's
  now opt-in like the other system extensions — turn it on in Settings › Extensions,
  then make Prosper your default from its settings pane.

### Extensions
- **The marketplace moved into its own window.** Browsing and installing extensions
  no longer crowds the Extensions settings page — open it from the new "Browse
  Marketplace" button. The window gives search room to breathe, filter by All /
  Themes / Extensions, and sort by recently updated or most downloaded.
- **Built for a full catalogue.** Results load a page at a time and the next page
  pulls in as you scroll (infinite scroll), so a marketplace with thousands of
  packages stays fast and light. A network hiccup on the first page now shows a
  tap-to-retry message instead of silently ending the list.

## v2.120.0

### Remote Wake
- **A remotely-woken Mac now stays awake while you actually use it.** Previously the
  wake only nudged the idle timer — nothing held the system up — so the Mac would
  re-sleep mid-session, dropping commands partway through. Now Prosper holds sleep
  open (via the privileged helper, the same mechanism as lid-stay-awake) for as long
  as a remote terminal client is connected, and for ~60s after it disconnects.
- **Detached sessions keep the Mac awake while they work.** Even with no client
  connected, if a `dch` session is still producing output the Mac stays up so the
  command can finish; once a session has been silent for ~10s (and no client is
  connected) the hold is released and the Mac may sleep on the next cycle. A
  long-running command that prints nothing at all is treated as idle — an accepted
  limitation. The hold auto-expires if Prosper crashes, so the Mac is never wedged
  awake.

## v2.119.0

### Remote Wake
- **Remote wake now actually wakes the Mac.** The daemon’s wake-check poll used a
  3-second timeout, but the round-trip to the wake server takes ~3s on its own and a
  battery dark wake needs a few more seconds for Wi-Fi to re-associate — so the poll
  always timed out, the daemon never saw the pending wake request, and the Mac went
  straight back to sleep every cycle. The poll timeout is now 10 seconds (still a
  bounded GET with one retry, held open by the existing wake-window assertion), so a
  dark wake has time to fetch the request and promote to a full wake.

## v2.118.0

### Permissions
- **The “Open” button on every permission row now always opens System Settings.**
  Previously, once a permission was *granted*, its “Open” button did nothing — the
  open call was gated behind the not-granted branch (only Notifications, which opened
  unconditionally, worked). Now Accessibility, Screen Recording and every extension
  permission (Full Disk Access, the lid helper, …) open their System Settings pane
  whether or not the grant is already in place, so you can always jump in to review or
  revoke. The system permission prompt still only appears when the grant is missing.
- **Accessibility now has an always-visible grant on the General pane.** The full
  permissions list lives on the Context pane, but that pane is hidden when Inline
  Autocomplete is off — so a clipboard-only user never saw it. General (always present)
  now carries an Accessibility row with the same Granted / Open / Re-check controls, and
  Clipboard History’s paste prompt routes there when the permission is missing.
- **Extension permission rows keep “Open” available when granted**, matching the native
  rows for a single, consistent permissions UX everywhere.

## v2.117.0

### Clipboard History
- **Pasting from Clipboard History no longer silently fails without Accessibility.**
  The auto-paste posts a synthetic ⌘V, which macOS drops unless the app holds
  Accessibility trust — and a clipboard-only user is never asked for it (only inline
  autocomplete and drag-snap request it), so ⏎ / the **Paste** button looked broken.
  The clip is still copied to the pasteboard (manual ⌘V always worked); now, when the
  grant is missing, Prosper opens Settings → Context to the same Accessibility
  permission UI every other Accessibility-gated feature uses, so you can grant it and
  paste works immediately. Fixes #1.

## v2.115.0

### Launcher Search
- **Extension commands are now discoverable by name or keyword, not just memorized
  prefixes.** Typing an extension's name ("translate", "openlid") or any keyword from
  one of its commands ("lid", "awake", "status") now surfaces that extension's commands
  as ranked rows in the command runner, so you can pick the action instead of
  remembering its prefix (e.g. that `lid?` means "OpenLid Status"). Every live
  extension's commands are flattened into the unified search and scored on the same
  ladder as apps/quicklinks/bookmarks; command rows rank last on a score tie so they
  never shadow a real launch target, while an exact name match still floats to the top.
- **Picking a command does the right thing per command.** Window-launching commands open
  their window; parameterless actions that opt in (`runs_on_select`, e.g. OpenLid's
  "Toggle Mac Awake" / "OpenLid Status") run immediately on Enter; input commands enter
  their locked mode and wait for you to type. The handler only ever runs on an explicit
  Enter — never auto-fires on a keystroke.
- **The discovery list is built once and memoized.** It rides the per-keystroke search
  hot path, so its haystacks are cached and rebuilt only when the live extension set
  changes (install/enable/trust) — a 300-command set went from ~300µs to ~0.1µs per
  keystroke on the main thread.

### Settings
- **Settings → Shortcuts now groups extension activators per extension.** Triggers were
  listed flat and unsorted; they are now bucketed under each extension's name and sorted,
  and the section explains that names and keywords also activate commands.
- **The Settings window no longer stretches past the screen.** A tall pane asking for more
  height than the display had could push the window partly offscreen; its height is now
  clamped to the visible screen.

### Window Layouts
- **Drag a window onto on-screen layout zones to snap it there (opt-in).** A Mosaic-style
  layer on top of the existing edge drag-snap: pick "Layout zones" in Settings → Windows,
  choose an active layout, and dragging a window now paints that layout's tiles on the
  target screen and drops the window into whichever zone the cursor is over. Ships with
  Halves, Thirds, Grid 2×2, and Main + side built-ins; the overlay preview is the exact
  frame the window lands in (single geometry source, no preview/drop drift).
- **A "Layout palette" mode (Mosaic-style) shows all your layouts as templates while
  dragging.** Pick "Layout palette" in Settings → Windows and a strip of small layout
  thumbnails appears near the top of the screen the moment you drag a window; each
  thumbnail's cells are individual drop targets, the hovered cell is named ("Bottom
  Right", "Left Half", …) and previewed on screen, and releasing over a cell snaps the
  window into that cell's real frame — the cursor stays at the strip, the window lands
  where the cell points. Reuses your existing layouts and the same editor; works across
  monitors (the palette follows the screen you drag on, and the window lands there).
- **A grid editor for custom layouts and groups.** Settings → Windows → Edit Layouts lets
  you paint zones on a cell grid (drag to add a multi-cell zone, tap a cell to add or
  remove a single zone), organize layouts into groups, set the active layout, and toggle
  "Move only" so a layout repositions a window without resizing it (useful for fixed-size
  dialogs). Layouts persist across launches and survive a downgrade without data loss.
- **Equal-fraction zones get equal pixel widths.** The gap model insets the visible frame
  by half a gap, places each zone, then insets again by half — so equal fractions yield
  equal widths and the outer margin matches the inter-window gap, with no off-by-half
  narrowing of the outer tiles.
- **The drag hot path is allocation-free.** At ~120 Hz the per-event work is just a cursor
  normalize plus a zone hit-test; tile frames are recomputed and the overlay rebuilt only
  when the display or layout actually changes, and a hover moving between zones only
  recolors the existing tiles. Multi-monitor uses the stable display ID for screen
  identity. Pinned by hit-test and full-layout perf budgets.

### Appearance
- **A new frosted-glass look (opt-in).** Settings → Appearance adds a "Frosted glass"
  toggle (off by default): the launcher, chat, clipboard, and settings surfaces blur the
  desktop behind them instead of using a flat tint, in the spirit of Alfred's translucent
  panels. The neon tint rides on top of the blur so readability is unchanged; the blur is
  fully behind the content. Off by default, so nothing changes until you turn it on, and
  the hot path stays gated when it's off.
- **Frost has a working Transparency dial.** Lowering Transparency genuinely shows more of
  the blurred desktop through the frosted panel — the control maps onto the full glass-density
  range and stays enabled while Frost is on (it tunes the glass), forced off only by the system
  "Reduce transparency" setting.
- **Wider Transparency and UI Size ranges.** Transparency now spans 100% / 90% / 80% / 75% /
  65% / 50% / 35% (down from a 60% floor); UI Size now spans 70%–145% (was 85%–130%). The
  frost glass floor tracks the lowest Transparency preset from a single clamp, so the two
  never desync.
- **Changing Transparency or Frost no longer micro-freezes the window.** They now drive a
  backdrop-only re-render of just the background views in place — no subtree teardown, no
  hitch, scroll and focus preserved. (UI Size still rebuilds, since it touches every sized
  site.)

### Remote Wake
- **Wake your Mac from another signed-in device, even from sleep (opt-in, off by
  default).** Settings → OpenLid adds a Remote Wake section: when enabled, the Mac wakes
  briefly on a schedule, checks whether one of your other signed-in devices has asked it
  to wake, and if so promotes itself to a full wake — so you can reach it over the network
  before it's awake. It is outbound-only (the Mac polls; nothing connects inwards), works
  behind any NAT/CGNAT without Wake-on-LAN, and only someone signed into *your* account can
  trigger it.
- **Battery-aware and conservative by design.** The wake cadence is configurable (more
  frequent on AC, less on battery, down to once a day), and a battery floor stops it from
  waking below a set charge. Everything fails safe: any ambiguity (no network, a captive
  portal, low battery, signed out) means it stays asleep rather than burning power. The
  feature can't even arm unless you're signed in.
- **Paired devices can tell whether — and roughly when — it'll wake.** The Mac reports its
  own wake schedule so another of your devices can show whether the Mac is reachable at
  all and an estimated time-to-wake before asking, including a warning when a low battery
  floor would prevent the wake.
- **A "How it works & limitations" popover** explains the trade-offs (battery, timing,
  outbound-only design) in a compact native popover that dismisses when you click away.

### Account & Security
- **Deleting your account now also clears remote-wake data.** Account deletion already
  removed your sessions, devices, and synced settings; it now also purges the remote-wake
  flag and the reported wake schedule from the server, so nothing tied to your devices is
  left behind. (Supporter records are retained as financial records, and the account email
  is tombstoned rather than reused.)
- **Signing out now revokes the session on the server.** Previously signing out only
  cleared local credentials while the session stayed valid server-side until it expired;
  it is now invalidated on the server at sign-out.
- **Remote-wake triggers are rate-limited** so a leaked session can't be used to repeatedly
  wake a Mac and drain its battery.

## v2.114.0

### Menu bar
- **Menu bar shortcuts now reflect the shortcuts you actually configured.** The status
  menu rows (Command Runner, Clipboard History, Coding Agent, Settings) hardcoded key
  equivalents that had drifted from the real bindings — "Command Runner" showed ⌥L (the
  Translate shortcut) and "Settings" showed ⌘, while the configured shortcut was ⌥\.
  Each row now reads its combo from Settings → Shortcuts and refreshes on every open, so
  rebinds show immediately; an unset shortcut renders no glyph instead of a stale one.

### System events
- **AC plug/unplug events now fire instantly.** The battery/power watcher relied on
  `IOPSNotificationCreateRunLoopSource`, which is coalesced with the time-remaining
  recompute and could arrive seconds after the adapter state flipped. It now also
  listens on the `com.apple.system.powersources.source` notify(3) key, so extensions
  reacting to power-source changes see them the moment they happen.

## v2.113.0

### Autocomplete
- **Unsupported apps now fully disable inline autocomplete instead of only hiding the
  menu row.** Apps with no working completion path — terminals (iTerm2, Terminal,
  Ghostty, …) and password managers — already showed an "<App> not supported" row in
  the menu bar, but the engine could still schedule completion requests and flash the
  inline ghost there. The per-app gate (`AppOverrideResolver.isEnabled`) now keys on
  `AppProfile.supportsInlineCompletion`, so the engine and the UI agree: no request is
  scheduled and no ghost is shown for an unsupported app, exactly as if completions
  were disabled.

## v2.112.0-beta.1

### Clipboard & Runner
- **Numbered quick-select shortcuts now use a configurable modifier, defaulting to
  Command.** The clipboard history panel's `⌃1…⌃0` paste-by-position shortcuts are now
  `⌘1…⌘0` by default, switchable back to Control from a new Settings → General →
  Clipboard → "Quick-select modifier" dropdown. The badge glyph on each row follows the
  setting. Modifier matching is exact among the real modifiers (so `⌘⌥1` falls through to
  normal editing) while tolerating Caps Lock / fn.
- **The command runner now mirrors the same shortcut on its top results.** The first five
  results carry a `⌘1…⌘5` keycap badge (on both the list rows and the reading-focused
  cards), and pressing the shortcut activates that result directly. Capped at five — only
  the top results get a shortcut. The clipboard and runner share one keycode table and one
  modifier preference, so the two stay in lock-step.

### Launcher Search
- **Fixed a launcher freeze when changing the search query quickly.** The runner window
  self-sizes by feeding its SwiftUI content height back into an AppKit `setFrame`, but it
  did so synchronously from inside SwiftUI's preference-commit phase — reentering Auto
  Layout and a Core Animation transaction commit (a render-server round-trip) on every
  measured height. Under rapid query changes this could serialize into a long main-thread
  stall blocked on that IPC. Resizes are now coalesced to the next runloop tick
  (latest-wins, one `setFrame` per tick), decoupling them from the commit.
- **Search results are now ranked across all sources together, so matching is consistent.**
  The launcher used to run apps, quicklinks and bookmarks as an exclusive priority chain —
  the first source with any hit won and the rest never ran. A stray fuzzy app match could
  shadow an exact bookmark, so e.g. "pods" and "pods)" returned different things. Every
  source is now scored on one shared relevance ladder (alias › exact › prefix ›
  word-prefix › contains › all-tokens-present › fuzzy) and merged Alfred-style, with apps
  winning ties. Fuzzy subsequence is the lowest tier and only for single-token queries, so
  a real substring hit always outranks it. All whitespace tokens must match (AND).
- **Bookmarks participate in the unified launcher list.** With "show in launcher" enabled,
  bookmarks are scored and merged alongside apps and quicklinks instead of only appearing
  via their own fallback, each row opening its URL natively (with favicon).
- **Search stays off the main thread and within budget.** Scoring runs off-main after a
  single cheap main-actor snapshot; lowercased app names and bookmark haystacks are
  precomputed, and the bookmark lookup overlaps app/quicklink scoring. Worst case ~1ms for
  a large catalog, far under the search debounce.

### Fallback Search
- **Web-search "default results" when a query has no local match.** When the runner can't
  confidently answer a query locally, it now offers web-search rows — "Search Google for
  '…'", Perplexity, Wikipedia, Amazon — the way Alfred and Raycast do. Press Enter (or the
  `⌘1…⌘5` keycap) to open the search in your default browser; each row shows the engine's
  favicon.
- **Shown as low-priority results by default, not only on empty.** In the default "smart
  append" mode the web searches sit at the END of a result list, below real matches, so
  they never get in the way but are always one keystroke away. A Settings toggle switches
  to "empty-only", where they appear solely when a query has no local result. Fallbacks are
  scoped to free-text queries — they never clutter calculator/unit/currency answers, the
  emoji picker, shell output, or extension UI.
- **Import the search engines you already use.** One button pulls the keyword search
  engines from your default browser — Chromium "Web Data" (Chrome, Brave, Edge, Arc,
  Vivaldi) or Safari's default engine — so you don't retype templates you already have.
- **Fully configurable under Settings → Fallback Search.** Add, edit, enable/disable, or
  remove providers; each is a name plus a search URL with a `{query}` placeholder
  (`{query+}` for `+`-separated terms). The query is always percent-encoded, and only
  `http(s)` engines are accepted.
- **Native on the hot path.** All per-keystroke row building is native (no scripting on the
  query path); the settings UI and browser import are a system extension that talks to the
  native store through a host API, keeping the runner fast and the configuration flexible.

### Window Management
- **Drag a window to a screen edge to snap it — Rectangle-style, built in.** Dragging any
  window so the pointer reaches a screen edge or corner shows a live preview of where it
  will land, and it snaps there on release. Left/right/bottom edges give halves, the top
  edge maximizes, and the four corners give quarters. Multi-display aware, and fixed-size
  dialogs are skipped automatically.
- **A premium snap preview.** The default "footprint" preview is a vibrancy blur tinted
  with your theme accent that grows and morphs between zones with an alignment haptic; a
  flat translucent style is available as an option (and used automatically when Reduce
  Transparency is on). Reduce Motion collapses the animation to an instant move.
- **Fully configurable under Settings → Window Management.** Toggle the feature, pick the
  preview style, optionally require a modifier key (Control / Option / Command) while
  dragging to avoid accidental snaps, tune the edge sensitivity and corner size, and
  exclude specific apps (add by bundle id or pick an app — its windows never snap).
- **Engineered to stay out of the way.** Snapping watches the mouse with passive event
  monitors, never the keystroke path that powers autocomplete. The per-drag work is pure
  geometry with no Accessibility round-trips once a window move is confirmed; a window's
  position is read at most a handful of times while detecting the drag, and a hung target
  app can't stall the UI (Accessibility calls are time-bounded). Window moves temporarily
  suspend the Accessibility "enhanced UI" mode so frames land exactly, then restore it.

### Appearance
- **UI size and transparency are now adjustable under Settings → Appearance.** Alongside
  the existing theme picker, two new segmented controls scale the whole interface (85% /
  100% / 115% / 130%) and let the desktop show through Prosper's windows (100% / 90% / 80%
  / 70% opaque). Both apply live to every window — Settings, the command runner, clipboard
  history, the chat agent and the snap preview — and persist across launches.
- **The default look is unchanged, by construction.** At 100% size / 100% opacity the UI
  is pixel-identical to before: every scaled dimension and font is a multiply-by-1.0
  identity, and at the default size text resolves to the exact same system font as a plain
  `.font(.body)` rather than an approximation. Enlarging switches fonts to an explicit
  scaled point size so text and layout grow together.
- **Respects system accessibility.** When macOS "Reduce transparency" is on, windows stay
  fully opaque regardless of the setting (live-observed, so toggling the system setting
  updates Prosper immediately), and the transparency control is disabled with an
  explanatory note. Hairline rules and the host-overlay autocomplete fonts (which must
  match the target app's caret) deliberately don't scale.
- **Built to stay off the hot path.** Size and opacity are global multipliers read through
  a tiny inlined accessor (~140 ns for a large bundle of lookups); changing a setting bumps
  a generation counter that rebuilds the SwiftUI tree once via `.id()` — segmented presets,
  not sliders, so a rebuild can't tear out a drag gesture mid-change.

## v2.111.1

### Snippets
- **System-wide snippet expansion now works with inline autocomplete off.** Snippets
  ride the autocomplete engine's single shared keystroke tap, but were coupled to the
  `autocompleteEnabled` pref in two places: the tap's run-gate (`needKeyTap`) had no
  snippet term, so the tap never started when autocomplete was off and nothing else
  needed it; and the tap handler bailed on an `autocompleteEnabled` guard before ever
  forwarding the keystroke to the expander. Snippets are now a first-class consumer of
  the shared tap (gated only by their own `snippetsEnabled`/`snippetsAutoExpand`), and
  toggling snippet auto-expand at runtime reconciles the tap live.

## v2.111.0

### Remote Terminal
- **Force a remote repaint without reattaching.** The bridge speaks a new `redraw`
  frame on an attached connection: it raises `SIGUSR2` at the dch client, which sends
  `MSG_REDRAW(REDRAW_WINCH)` so the master fires `SIGWINCH` at the inner program and it
  repaints. This recovers DchTerm after a soft-keyboard relayout — no detach/reattach,
  no lost scrollback. No-op once the pty child has exited.

## v2.109.0

### Remote Terminal
- **Rename your `dch` sessions from DchTerm.** The bridge now speaks a `rename`
  frame, so the app can set or clear a per-session display alias without touching
  the session itself. List responses carry the alias alongside the real name, and
  the bridge drives the existing `dch -m` / `-lj` commands rather than reimplementing
  anything.

## v2.107.1

### Remote Terminal
- **The `dch` binary now actually ships in the release.** v2.107.0's bundle step ran
  on a CI runner with no `dch` to embed, so Remote Terminal only worked for users who
  already had `dch` on their PATH. The release pipeline now builds `dch` from source
  and embeds it into the app (and fails the build if it's missing), so Remote Terminal
  works with zero install as intended.

## v2.107.0

### Remote Terminal
- **Serve your terminal sessions to the DchTerm app over Tailscale.** A new
  Settings → General → "Remote Terminal" toggle brings up a thin bridge that lets the
  DchTerm app attach to your live `dch` sessions from another device. The bridge never
  reimplements dch's protocol — it spawns the real `dch` binary as a pty-attached
  client and shuttles bytes over TCP, so session survival, SIGWINCH redraw, and kitty
  key replay keep working unchanged. Detaching (killing the pty child) leaves the
  master daemon alive.
- **Tailscale is the trust boundary — nothing else.** The listener binds *only* to the
  host's Tailscale interface address (never `0.0.0.0`); with no Tailscale address it
  refuses to start. Belt-and-suspenders: every accepted peer IP must also fall inside
  the Tailscale CGNAT range `100.64.0.0/10` or it's dropped. No auth tokens, no TLS.
  Off by default — the port only binds when you enable it.
- **Isolate sessions (optional).** A second toggle runs app-served sessions in a
  private socket dir so they don't intermix with standalone `dch`. Default off —
  terminal-started and app-started sessions share, as requested.

### Privacy
- **Analytics only reports a feature's sub-settings when that feature is on.** A
  disabled feature's detail settings carry no signal, so the snapshot now gates them:
  the master toggle is always sent, the detail props (clipboard limits, completion
  tuning, vision/OCR context, etc.) only when the feature is live. The inline model is
  still reported when autocomplete *or* Translate is active, since they share it.

### Hammerspoon Compat
- **Per-app keyboard input switching works.** `hs.application.watcher` callbacks that
  call `hs.keycodes.currentSourceID(...)` (the common "switch to Bulgarian in Slack,
  back to ABC everywhere else" idiom) did nothing: the Carbon TIS input-source API
  must run on the main thread, but app-activation events deliver on an off-main lane
  where `TISSelectInputSource` silently no-ops. The keyboard host calls now funnel
  through the main thread like every other system call. The hammerspoon-compat
  diagnostics section also lists active app watchers and the current input source.

## v2.105.0

### Extensions
- **Privileged mode — opt-in system access for your own extensions.** A new
  per-extension toggle (Settings → Extensions → "Grant System Access") elevates a
  *trusted* user/marketplace extension from the automation tier to the full system
  tier: `host.shell`, the coding-agent, and destructive file ops become available to
  its Lua. It is a deliberate, explicit escalation — separate from Trust, default
  OFF, and persisted per extension — so a trusted-but-not-privileged extension keeps
  exactly today's behaviour (shell refused). Grant it only to a config you have read
  end-to-end; a privileged extension can run any command as you.

### Hammerspoon Compat
- **`hs.execute` works when privileged.** With "Grant System Access" on, init.lua
  lines like `hs.execute("open -a Ghostty …")` or `pmset displaysleepnow` now run
  instead of returning the "restricted to system extensions" string. Without the
  grant, behaviour is unchanged (refused).
- **Window API: `hideAppIfNoWindows` works.** The app object from
  `hs.application.frontmostApplication()` (and the app-activation watcher) now has
  real `allWindows()` (length = AX window count via `host.apps.windows`) and `hide()`
  (`host.apps.hide`), so the common "hide the app after its last window closes" idiom
  on ⌘W / ⌘⇧W runs unmodified. Needs Accessibility (Prosper holds it in normal use).

## v2.104.0

### Hammerspoon Compat
- **⌘-shortcuts work under any keyboard layout.** A bound chord that re-injected a
  menu key-equivalent (e.g. `hs.eventtap.keyStroke({"cmd"}, "W")` to close a window)
  did nothing while typing in a non-Latin layout like Bulgarian: the synthetic event
  carried the layout's character (⌘W → "в"), so the app's "Close" item (key
  equivalent `w`) never matched. Injected ⌘/⌃ chords now stamp the ASCII character
  for the keycode — mirroring how macOS routes real command-key events — so menu
  shortcuts fire regardless of the active input source. Pure-keycode binds (arrows,
  F-keys, launches) were already layout-independent.
- **Per-app keyboard input switching now works.** `hs.application.watcher.new(fn):start()`
  fires on app activation, and `hs.keycodes.currentSourceID(id)` / `hs.keycodes.layouts()`
  are shimmed onto the host keyboard API. An unmodified config that switches input
  source per app (e.g. Bulgarian in Slack/Telegram, ABC elsewhere) runs as-is. The
  app object from `frontmostApplication()` also tolerates unsupported window methods
  (`allWindows`/`hide`) as harmless no-ops instead of erroring.

## v2.103.0

### Fixes
- **Releases sign and notarize again.** v2.100.0–v2.102.0 failed to build: the
  Apple Events entitlement added in v2.100.0 came with an XML comment that
  contained the literal `--deep`. A double hyphen is illegal inside an XML comment,
  and codesign's entitlement parser (AMFI, stricter than `plutil`) rejected the
  whole plist — `Failed to parse entitlements: AMFIUnserializeXML: syntax error` —
  so `dist/Prosper.app` was left unsigned and notarization aborted. Removed the
  comment from the signing entitlements (the note now lives in the build script),
  so the Apple Events grant from v2.100.0 finally ships.

## v2.102.0

### Build
- **Surface codesign failures in the release log.** The bundle step previously
  hid codesign's stderr (`>/dev/null 2>&1`) and only printed a generic "codesign
  failed" warning, so a notarization-blocking signing error gave no diagnostic. It
  now prints codesign's actual output when a signature fails.

## v2.101.0

### Hammerspoon Compat
- **`hs.dialog.blockAlert` and `hs.alert.closeSpecific` now work.** Configs with a
  confirm-then-act hotkey — e.g. the common cmd+shift+delete "Empty Trash" binding
  that does `hs.dialog.blockAlert("Empty Trash", …)` and acts only if the returned
  button equals `"Empty Trash"` — did nothing: `hs.dialog` was unshimmed, so the
  call fell through to an inert stub that returned a table instead of the button
  title, and the `== "Empty Trash"` branch was never taken (no dialog, no action,
  silently). `hs.dialog.blockAlert` is now backed by the native confirm dialog and
  returns the chosen button title; `hs.alert.closeSpecific` is shimmed as a no-op so
  the progress-alert dismissal pattern doesn't error. (Actions that then drive
  another app via osascript — like `tell application "Finder" to empty trash` — also
  need the Apple Events automation grant added in v2.100.0.)

## v2.100.0

### Fixes
- **Hammerspoon URL routing that opens links via AppleScript now works.** A
  finicky-style config whose handler does `tell application "Safari" …` (or any
  `hs.osascript`/osascript host call that drives another app) was silently denied
  under the hardened runtime — Prosper shipped without the Apple Events automation
  entitlement, so a clicked link just focused Prosper and nothing opened. Added
  `com.apple.security.automation.apple-events` (and an `NSAppleEventsUsageDescription`
  so macOS can show the one-time Automation prompt). On the first routed link, allow
  "Prosper wants to control Safari". The native URL Dispatcher was unaffected — it
  routes through NSWorkspace, which needs no automation grant.

### Settings
- **Permission rows explain *why* the grant is needed** instead of repeating the
  status. The subtitle previously read "Granted", duplicating the badge; it now shows
  a short rationale (per permission), regardless of grant state.

## v2.99.0

### Extensions
- **Permission UI consistency, part 2.** Two more extensions now follow the same
  rule — a **"Permissions"** group at the **top** of the settings page. OpenLid's
  Background Helper (Login Items) approval moved out of the "Right now" section into
  its own Permissions group at the top, and Hammerspoon Compat's required
  Accessibility row moved out of the main section into a Permissions group above it.

## v2.98.0

### Extensions
- **Consistent permission UI across extensions.** Every extension that requires a
  host permission now surfaces it the same way: a group titled **"Permissions"**
  (plural) at the **top** of its settings page. The Window Management page moved its
  Accessibility group above the shortcut recorders, and Browser Bookmarks' Full Disk
  Access group was renamed from the singular "Permission" — so the look and feel is
  uniform with Snippets.

## v2.97.0

### Extensions
- **Window Management is now a first-class extension settings page.** The shortcut
  recorders + Accessibility permission that used to be a hardcoded Swift pane are
  now declared entirely in the extension's manifest, rendered natively with the
  same look. This also removes the duplicate "Window Management" entry that showed
  in the Settings sidebar. A new declarative `shortcut` control kind lets a manifest
  bind a recorder row to a host global shortcut by name (writes through to the same
  store, re-registers the Carbon hotkey on change) — no Lua required.

### Hammerspoon Compat
- **`URLDispatcher` Spoon now works.** Configs that route links by domain through
  the popular `spoon.SpoonInstall:andUse("URLDispatcher", …)` setup previously did
  nothing (Spoons were inert), so per-domain browser routing and URL rewriting from
  `~/.hammerspoon/init.lua` silently never ran. The Spoon is now shimmed: it wires
  `url_patterns`, `url_redir_decoders`, `default_handler`, and
  `decode_slack_redir_urls` onto the existing `hs.urlevent.httpCallback` path —
  decoders run, then the first matching pattern routes to its app, else the default
  handler. A minimal `hs.http` (`urlParts`, `encodeForQuery`) backs the decoders.
  Routing reuses the existing automation surface, so it carries no new privilege.
  Other Spoons stay inert. The "What's loaded" diagnostic now shows the live
  route/rewriter counts.

### Fixes
- **"Prosper is your default browser" no longer reports a false positive.** The
  check matched the recorded LaunchServices handler id as a string, which can be a
  stale/duplicate registration that no longer resolves to a real browser. It now
  resolves the app macOS would *actually* launch for an http(s) URL, so a broken or
  ghost registration honestly reads as not-default.

## v2.96.1

### Fixes
- **Double-tap-to-quit (⌘Q) now fires on the first try.** A held key's OS
  autorepeats arrive at ~the initial repeat delay (~0.5s) — right inside the
  double-tap window — and were consuming/resetting the pending first press, so
  the real second tap looked like a fresh first one and the chord kept getting
  swallowed (users had to mash ⌘Q several times). The keystroke tap now reads the
  autorepeat flag and ignores repeats in double-tap detection; ordinary
  remap/swallow rules still act on repeats as before.

## v2.96.0

### Fixes
- **Auto-update now installs.** Updates were downloaded but failed at the install
  step with "An error occurred while running the updater." The signing pass stamped
  the restricted `keychain-access-groups` entitlement onto *every* nested binary,
  including Sparkle's `Autoupdate` helper — a bare executable that can't carry the
  provisioning profile that entitlement requires, so macOS (AMFI) killed it on
  launch and the updater's helper process never came up. Signing now applies that
  entitlement to the main app executable only; the nested helpers stay
  profile-free and launchable.

### OpenLid
- **Keep awake with the lid closed now works out of the box — no `sudoers` edit.**
  The clamshell-sleep override (`pmset disablesleep`) needs root, which previously
  meant a manual `NOPASSWD` entry in `/etc/sudoers`. Prosper now ships a tiny
  privileged helper daemon (`ProsperLidHelper`) that does it, installed lazily via
  `SMAppService` the first time you actually disable lid sleep (one-time approval
  in System Settings → Login Items). It idle-exits when unused (zero memory) and
  resets the override automatically if the app quits or crashes, so the lid is
  never left wedged awake. Nothing is installed unless you use the feature — if
  the OpenLid extension is disabled, no background item is ever created.
- **Background Helper approval is now an inline settings row.** The one-time
  Login Items approval shows as a native permission row in the OpenLid section
  (only while the override is active), instead of an alert.
- **The lid is no longer left wedged awake if the helper is force-killed.** A
  daemon kill (force-quit, OOM) used to leave `disablesleep` on with nothing to
  reset it. The daemon now clears any stale override at cold start; a client that
  still wants it reconnects and re-applies.

### Permissions & Settings
- **First-run onboarding removed; Input Monitoring no longer requested.** Inline
  autocomplete and the coding agent are off by default, so first launch needs no
  permissions or model. The keystroke tap was always gated on Accessibility alone,
  so the Input Monitoring grant was redundant — it's gone everywhere. Enabling
  autocomplete without Accessibility now shows a tappable warning in General
  settings that deep-links to the grant.
- **Restored the "Reset & re-add Prosper" Accessibility recovery button.** It now
  lives on the Context pane's Accessibility row (shown only when not trusted) and
  fixes the "toggle is ON in System Settings but the app isn't trusted" trap.
- **"Re-run Setup…" is gated on the selected model, not Accessibility.** It runs
  the model download, so it now appears whenever the chosen completion model is
  missing — and won't pointlessly re-download when the model is already present.
- **Per-extension permission grants are surfaced in each extension's settings.**
  Snippets and window extensions list their Accessibility requirement in their own
  page, so a dead `win`/snippet expansion is debuggable from there.
- **Sync transparency.** Extension settings (`ext.*`) now sync (with machine-local
  state like timers excluded), and the Sync pane has a new "What's synced" section
  listing exactly which categories propagate.

## v2.95.0

### Fixes
- **Double-tap-to-quit (⌘Q) now works.** The detection window was 0.4s — tighter
  than a natural double-tap, so the second press often landed late and the chord
  was swallowed again, meaning ⌘Q appeared to do nothing no matter how many times
  you pressed it. Widened to 0.5s (the macOS double-click default), and the second
  press now lets the real key through instead of re-synthesizing one (some apps
  ignored the synthetic ⌘Q for menu shortcuts).

### Hammerspoon
- The **Hammerspoon** settings diagnostics now show a **URL routing** row —
  whether your `hs.urlevent.httpCallback` is active, and a warning if Prosper isn't
  the default browser (so links never reach it).

## v2.94.0

### Browser
- **Route links to a browser by domain.** Make Prosper your default browser and
  every clicked link is sent to the browser you choose per domain — set it up in
  **Settings → URL Dispatcher** (make-default button, fallback browser, and a
  domain → browser rule list). Nothing is hardcoded; rules live in your config.
- The **Hammerspoon facade** now runs an existing `hs.urlevent.httpCallback`
  (Finicky-style) URL-routing config unmodified.

### Fixes
- URL routing **never actually fired** before: the `url.open` event payload arrives
  as a JSON string, and the handler read it as an object, so every link silently
  fell through. Decoded correctly now, with a loop guard so a link is never bounced
  back to Prosper (the new default) forever.

## v2.93.0

### Fixes
- First click on a command-palette result card (browser bookmarks, file search, app
  launcher, snippets) now opens it. Previously the first click did nothing and you
  had to click a second time.

### Browser
- Prosper can now be chosen as your **default web browser** directly in System
  Settings → Desktop & Dock, alongside the existing "Make Prosper the Default
  Browser" palette command. (It was previously hidden from that list.)

## v2.92.0

### Keyboard
- Fixed shortcuts not firing when inline autocomplete is turned off. Hammerspoon
  hotkeys, per-app key remaps, media keys, and native Settings → Shortcuts mappings
  all share one keystroke tap; it now stays up whenever any of them needs it, not
  only while autocomplete is on.

### Extensions
- Hammerspoon Compat now shows a required-Accessibility row in its settings (with a
  warning when the grant is missing — without it nothing fires) and a "What's loaded"
  diagnostics section listing the hotkeys, key remaps, raw eventtaps, and timers
  parsed from your `~/.hammerspoon/init.lua`.
- Snippets list all entries on an empty `sn` query, matching `bm` / `ql` / `qd`.
- The marketplace now shows the version currently published for an extension and
  offers a one-click bump when your local build is newer.

### Fixes
- Fixed a settings list rendering glitch where info rows could appear duplicated.

## v2.91.0

**First public release.** Prosper is a local-first macOS app: a system-wide
inline autocomplete (ghost text at your caret in any app), a command palette
that computes (calc, units, currency, time zones, translate, shell, window
snapping, quicklinks), a local tool-using coding agent, and clipboard history —
all powered by an in-process MLX model. 100% on-device: no cloud, no daemon, no
typed text leaving your Mac. Extensible with Lua commands, themes, MCP servers,
agent hooks, JS/TS plugins, and Hammerspoon-style automation. Developer
ID-signed and notarized.

This release also lands the changes below.

### Coding agent
- The coding agent is now fully native. The thin `com.prosper.agent` Lua extension
  and the entire `host.agent` host-API bridge were removed; `g <goal>` in the runner
  drives `AgentController` directly. No behavior change — same window, same working
  directory, same approvals.

### Theming
- New theme system: extensions can contribute themes (`[[contributes.themes]]` →
  `theme.json`, a 12-token palette) with instant redraw across the app and AppKit
  chrome (menu-bar/dock). Ships with default and amber themes.

### Keyboard
- Native, configurable Key-Mappings UI (Settings → Shortcuts) replacing the old
  app-keys / app-remaps / media-layer flagships. Incoming media keys can be
  consumed or passed through (volume HUD preserved on miss).

### Memory & performance
- The on-device model now unloads when autocomplete is disabled and after an idle
  timeout (default 2 min, configurable), freeing RAM. The inline hot path is
  untouched.

### Extensions platform
- Extension marketplace: browse and publish extensions, with signed-manifest
  verification and an install-then-trust gate.
- Hammerspoon parity: from-scratch host APIs (timers, caffeinate, battery, network,
  screen/lid, menubar, dialogs, key multiplexer, URL/default-browser, filesystem
  watch) plus a facade that loads an unmodified `~/.hammerspoon/init.lua`.
- New Browser Bookmarks system extension (Safari / Chrome / Firefox / Zen).
- Many new host-API surfaces: durable timers, menu-bar items, FS watch, key rules,
  system services, and event taps.
