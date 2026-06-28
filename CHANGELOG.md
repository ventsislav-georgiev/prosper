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

## v2.121.0 *(unreleased)*

### Menu Bar Management
- **New "Menu Bar Management" extension (opt-in).** Hide menu-bar icons behind a
  divider you can show on demand, add spacing between icons, and pick the collapsed/
  expanded chevron style — all with no Accessibility or Screen Recording permission.
  A live preview strip in Settings shows your real icons in order. Ships **disabled**
  — it adds nothing to your menu bar until you turn it on in Settings › Extensions.
- **Item ordering that survives relaunch, including multi-icon apps (experimental).**
  Apps like Stats or iStat Menus publish several icons that macOS normally shuffles
  on every launch. Turn on ordering, arrange your icons once, and Prosper keeps them
  in place. It's opt-in, only enabled on macOS versions it has verified it can drive,
  and self-tests on a throwaway icon at startup — if the move can't be performed
  reliably on your Mac it disables itself rather than fighting the system.
  - On macOS 26 (Tahoe), where the system no longer tells apps which icon is which,
    Prosper rebuilds each icon's identity from its picture (this is the only part
    that asks for Screen Recording, and only when you use ordering).
  - **On-reveal** mode restores your order whenever the bar is shown; **Live** mode
    also snaps icons back if they drift. Live mode stays gentle: it backs off on
    battery, and a circuit breaker parks it if a move keeps failing so it can never
    spin the CPU.
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
    cores, plus load average and uptime.
  - **Memory** — app/wired/compressed stacked usage, memory pressure, and swap.
  - **GPU** — utilization with renderer and tiler breakdown, VRAM in use, and core count.
  - **Network** — up/down throughput with a dual-area chart, total transferred, and
    the active interface, IP address, and Wi-Fi network.
  - **Sensors** — the full temperature list and current fan speeds.
  - **Battery** — charge, health, cycle count, live power draw, voltage, amperage,
    capacity, power-adapter wattage, and time remaining.
- **Reads stay light.** Every sampler runs in microseconds and the menu bar updates
  once a second, so the monitors don't add measurable load to the thing they measure.

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
  immediately; your detached sessions are left running and reconnect on the next wake.
  The Status line now says so honestly ("Held by a remote session or another app")
  instead of guessing.
- **Sleep this Mac remotely.** Running `open prosper://sleep` on the Mac (e.g. from
  inside your remote `dch` session) does the same thing — releases the holds and puts
  it to sleep — so you can wake it, do your work, and send it back to sleep without
  touching it. Tip: add `alias prosper-sleep='open prosper://sleep'` to your shell.
- **"Sleep this Mac now" actually sleeps the Mac.** The first beta of this button
  only slept the *display* — the Mac stayed awake and network-reachable — and often
  did nothing on the first click. Cause: the keep-awake holds were released from the
  app over a connection that may have already dropped (so the release silently
  no-op'd), and `pmset sleepnow` run while sleep was still disabled only sleeps the
  screen. The release-then-sleep now happens inside the privileged helper as root:
  it clears every hold first (committed synchronously) and only then sleeps, so the
  Mac goes down on the first click and stays down.

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
