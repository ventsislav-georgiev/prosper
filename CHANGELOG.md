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

## v2.175.0 *(unreleased)*

- Agent Sessions window: a live session's "⋯" header menu and its sidebar row's right-click menu
  offer Restart agent, Stop and Kill, with the island's rules and reasons; the window asks first in
  a line over the conversation. A stopped or killed session's selection moves to its History row.
  While a Restart or Stop runs, the row shows it ("Restarting…", "Stopping…") in place of the state,
  the result shows under the header, and Send, Interrupt and prompt answers are refused until it is done.
  Results for a whole folder (Stop all, Kill all, Restart all) show in a fixed line at the bottom of
  the sidebar. History re-reads when the window shows and when a session ends while it is open.
  Right arrow with nothing selected unfolds the first folded section. Ages past 364 days read in
  years, here and on the island (#829).
- Agent Sessions window: History rows get Resume, Resume (no message), Pin/Unpin and Remove from
  History, in the row's right-click menu and as buttons in the History pane, with the island's
  rules and wording. Remove asks first, names the record and shows its `claude --resume <id>`
  (the Claude Code conversation stays on disk); the selection then moves to the next History row.
  A pinned row shows a pin. The result line and the History buttons no longer move anything when
  they change, and the folder line sits in its own slot under the list. An answer whose dch
  support went away since the question says why instead of doing nothing. A stopped or killed
  session stays in view until its History row arrives (about a minute at most); meanwhile it
  reads Ended, and Open in terminal, Return, its "⋯" menu and the input box are off. Remove from
  History says when it also removes older records of that name (#829).
- Agent Sessions window: Rename… in a live session's row menu and in the header "⋯" turns the title
  into a text field: Return saves, Esc or clicking away cancels, and an empty field clears the alias.
  It renames the display name only, through `dch -m`, and a failure shows on the session's line. An
  ended session's chip now reads Ended with its own glyph, its disabled Open in terminal says why,
  and VoiceOver hears "Message Claude, session ended" on its input box (#829). What you typed
  survives the window being resized mid-edit. A new name shows at once and stays shown until the
  session list catches up, so renaming back to the old name works straight away. A name longer than
  dch keeps (599 bytes) is cut on a whole character, so emoji with skin tones and accented letters
  are never split. Return while a Restart or Stop runs on the session keeps the field open with your
  text and says why on the session's line, only while that job runs; once it ends, the line shows
  the job's result ("Restarted", why a restart failed, the Stop's result). The "⋯" help on a
  session whose name starts with a dash names only Rename (#853).
- Agent Sessions window: clicking a session in the sidebar moves the keyboard into it, so you can
  type without clicking again: into its terminal in Terminal mode (as soon as the terminal is
  connected), into the message box in Transcript mode. Return on a selected row does the same, and
  so does Right arrow (on a folded section, the first Right unfolds it); ⌘T or the Transcript |
  Terminal switch lands in the shown view's input. Up and down still move through the list, and any
  click in the sidebar takes the keys back until a row click moves them in again. If you click in
  the sidebar, start a rename or press ⌘F before the session is connected, the keys stay where you
  put them. Return no longer opens the session in the terminal app; "Open in terminal" in the
  header still does (#845).
- Agent Sessions window and Agent Island: a message dch stopped sending on a Ctrl-C, SIGTERM or
  SIGHUP now says what happened. One taken back, or stopped before anything was typed, reads "Not
  sent"; one that may still sit in Claude's input box says so. A Resume whose session came back
  but whose resume message was not sent reads "Resumed" and says why (#854).
- Extensions: a `host.shell.run` that times out now stops the shell and everything it started
  (the whole process group, forced after 1 s) instead of leaving it running. Calls that must
  finish opt out with `host.shell.run(cmd, { keep_running = true })`: control returns at the
  timeout and the command runs on; the built-in Homebrew upgrade, Scripts, the shell extension,
  disk eject and the Alfred snippets import use it. `host.shell.run` output is capped at 64 MiB,
  with a second return value of `true` when the cap was hit (the text is never marked, so large
  bookmark imports still decode); `> cmd` output stops at 1 MiB with an "[output truncated at
  1 MiB]" line. Shell output with invalid UTF-8 now shows replacement characters instead of
  coming back empty (#833).
- App Updates: a Homebrew upgrade that outlasts the extension timeout now says it is still
  running in the background instead of "Nothing was upgraded". Extensions: `host.shell.run`
  rejects bad options (a value that is neither a table nor `false`, an unknown key, a non-boolean
  `keep_running`) with an error, instead of silently running without them; `false` still means
  no options, so `host.shell.run(cmd, cond and { keep_running = true })` works (#834).
- App Updates: when a Homebrew upgrade runs on in the background, the list refreshes within a
  minute of brew finishing and you get the same "N packages upgraded" notification (for up to
  2 hours, and only while Prosper stays open). When some packages fail to upgrade, App Updates
  re-reads the list and says both, for example "brew upgrade failed for some packages (exit 1);
  3 packages upgraded" ("brew upgrade failed (exit 1)" when none was). When another Homebrew
  process holds the lock, it re-reads the list too and says "brew upgrade stopped: another
  Homebrew process holds its lock (exit 1)", with the count when packages were upgraded first;
  an Upgrade started while one Prosper started still runs says "brew upgrade refused: an
  upgrade Prosper started is still running" and leaves the list to that upgrade. The upgrade
  status file now lives in a private folder that Prosper creates and removes. A brew or macOS
  check that times out keeps the last known list instead of emptying it (#834).
- Agent Sessions window: a live session now opens in its real terminal by default, inside the
  window: the same dch session Ghostty would attach to, drawn by libghostty, with full keyboard
  input (Esc, Tab, ⇧Return, ⌃C and arrows reach Claude), IME and Option-composed characters, ⌘C/⌘V
  (sanitized, bracketed when the program asks; an image pastes as ^V), programs' clipboard copies
  (OSC 52), ⌘-click links (web and mail only), ⌘F find with ⌘G / ⇧⌘G, and VoiceOver reading the
  screen. A Transcript | Terminal toggle in the header (⌘T) switches to the transcript view;
  sessions switched to Transcript are remembered per session name on this Mac. History rows show the
  transcript; so does an ended session, with the toggle off and a tooltip saying why. In Terminal
  mode the terminal runs to the window's bottom (no input box or prompt panel), a toggle moves
  neither the header nor the sidebar, and resizes reach the session once, debounced. The terminal
  attaches only while the window shows that session, reattaches once if it is detached elsewhere,
  and says why when it cannot attach (refused, opened on another device, ended) with Reattach /
  Retry. The verbosity picker (⌥⌘1-3) is off in Terminal mode. ⌘↑ / ⌘↓ go to the previous / next
  session, except in a text field (#822). A session opened in Terminal mode now draws at the pane's
  size at once; it no longer shows wrapped at another size until the window is resized (#844).
- Agent Sessions window, Terminal mode: a program in a session's terminal can set your clipboard
  (OSC 52) only while you are looking at that session: it is selected and the window is on screen,
  not minimized and not covered. Settings › Agent Island › Agent Sessions › "Let sessions set the
  clipboard while you're viewing them" (on by default) turns it off. A program can never read the
  clipboard, and a middle click no longer pastes it. A session that ends while shown says "Session
  ended" at once, with no "Couldn't attach" flash. The find buttons have VoiceOver labels, the
  error shown when the Mac cannot start a new process for a terminal is a plain sentence, and no
  config file is left in the temporary folder.
  Pasting several lines is not confirmed first: Claude Code and login shells take a paste as one
  block (bracketed paste), so nothing runs early (#843).
- Agent Sessions window: Settings › Shortcuts lists "Open Agent Sessions", a hotkey that opens the
  window or brings it forward. It is unset by default, listed and registered only while the Agent
  Island extension is on, and does nothing while the island is not running (#858).
- Agent Sessions window: wears the Settings window's look. The title is hidden and the titlebar
  is painted like Settings'; the body uses the Settings backdrop, sidebar surface, accent
  selection bar and section labels, and follows the Appearance opacity, frost, accent, light/dark
  and UI size live, like Settings. The terminal keeps its own opaque background for legibility
  (#860).
- Settings: below UI scale 1.0, the first row's key field is no longer cut off at the top of the
  Bound and All Actions lists in Shortcuts; key fields fit their row at every scale, in Shortcuts
  and in Key Remapping, and keep their label centred (#859, #868).
- Settings › Shortcuts and Key Remapping: a long shortcut now fits its key field instead of being
  cut off at both ends. Page Up / Page Down show as ⇞ ⇟ in key fields and in the "shortcut
  unavailable" notification, and the Shortcuts search also finds a row by its keys' names
  ("pageup", "return", "cmd") (#876).
- Agent Island: New session, and Resume when it has to pick a new name, no longer take a name
  that differs only in case from an existing session's or a History record's ("Proj" beside
  "proj"): on a case-insensitive disk both would share one socket (#847).
- Agent Island: Resume of an ended session whose name differs only in case from a running one
  (record "proj" beside a live "Proj") now resumes it under a free name instead of failing (#847).
- Agent Island: New session in a folder with a very long name now starts the session under a
  shortened name that fits dch's socket path, instead of a name dch cut itself and ended with a
  hash (#847).
- New session names Claude after its session: every Claude session started from New session runs
  with `--name <session name>`, so the name in Claude's prompt box, in /resume and in the terminal
  title matches the session's row. A name typed into the command is replaced, never doubled, and
  Prosper never adds a `--name` to the stored New session command. Shells, other agents and
  `claude -p` runs start unchanged (#847).
- New session no longer re-sends an old startup prompt: a session started under dch 1.48 or older
  with `claude … -- "<prompt>"` (or a bare prompt word) no longer makes that prompt part of the
  inferred New session command; Prosper drops it by the rules of dch's own strip, as of dch
  1.50.1 (#867).
- Prosper now bundles Ghostty's terminal library (libghostty, through libghostty-spm) for the Agent
  Sessions terminal, so the download is about 4 MB (10%) bigger. The app's credits list libghostty
  and the libraries inside it (FreeType, libpng, zlib, Oniguruma, Wuffs, simdutf, Highway, stb,
  libxev, libvaxis, z2d and others), each under its own license (#822).
- Remote Terminal: the remote-frames protocol is 1.1 and learns "ctl": a dch client can run
  `dch --read`, `--send`, `--run`, `--keys`, `--follow`, `--status`, `-k`, `-m`, `-d`, `--history`,
  `--pin`, `--unpin`, `--forget`, `--stop`, `--say`, `--spawn` and `--revive` against this Mac's
  sessions (`dch <verb> mac:name`). Prosper runs its own dch with the argv, never through a shell,
  behind a per-verb and per-flag allowlist (dch 1.41.0's) and dch serve's session-name rule; a name
  with `:` is refused, so a request never relays on to a third host; output streams back as it
  comes. `--say`, `--stop` and `--revive` stop after 660 s and every other verb but `--follow` after
  60 s, each at 8 MiB of output; `--follow` has no output cap and runs until the session ends or the
  client hangs up (dch then gets SIGTERM). A client can cancel a running request (the hello lists
  "ctl-cancel"), and the connection stays open for its next request until 300 s idle. Same gate as
  attach (peer address and owner check); `--spawn` may name a starting directory. `--xray` is
  allowlisted, and offered once the bundled dch has it. (#838)
- Remote Terminal: Prosper's "ctl" now answers the way dch 1.42.0's serve does (#841). A refused
  request gets its reason and then the connection closes; a second request while one runs gets
  "busy" and the connection stays. A connection that ran a ctl takes only ctl frames: a session frame
  or a watch closes it, and any other frame is dropped. A ctl on a connection that is attached or
  watching is refused. A cancelled request ends with exit 2 "cancel", and nothing it printed after
  the cancel is sent. A cancel or a closed connection sends dch SIGTERM; if dch has not exited after
  660 s (`--say`, `--stop`, `--revive`, `--run`, so their clean-up is never cut) or 2 s (every other
  verb), it and the processes it started are killed. A request ends as soon as dch exits, even when
  a process it started still holds its output open. `--xray` is refused first when this Mac's dch lacks it.
- Remote Terminal: a ctl that hit its timeout could lose its final frame when dch exited at once on
  the kill; the connection then answered every later ctl with "busy" until the client dropped it.
  The timeout's end and its final frame now go out together (#856).
- Remote Terminal: when Tailscale reports a negative user id for this Mac, no device counts as
  yours and every device is refused, as `dch serve` does. "Allow when Tailscale isn't answering"
  doesn't let them in (#855).
- Remote Terminal: the Mac's server now refuses a new session name or a rename alias shaped like a
  Claude session id (`m` + 16 hex digits, any case, padding trimmed) with dch serve's own "name
  looks like a session_id", before running dch. A listed older session of that name still attaches
  by its exact name (#850).
- Remote Terminal: renaming a session whose name starts with "-" to a session-id-shaped alias, and
  attaching to a session-id-shaped name padded with tabs or line breaks, are refused with the same
  message dch serve gives (#863).
- iPhone Resume and Resume interrupted (phone and island): a session dch revived whose resume
  message was typed and then taken back, or left in Claude's input, now counts as resumed, under
  the name it runs as now, and the line still says the message was not sent. Other revives that
  dch reports as failed still count as failed (#861).
- Remote Terminal ctl: `--run` gets the 660 s timeout dch serve gives it, a timeout or output cap
  ends dch 2 s after asking it to stop (was 1 s), and turning Remote Terminal off ends a running
  ctl within 2 s, an agent verb's too. A warm ctl connection is closed after 300 s idle however
  many are open; dch serve closes one after 30 s when its connection slots run short (#852).
- Remote Terminal: the session list tells the phone each session's working directory when dch knows
  it, as dch serve does since 1.54.0. Attaching or creating a session whose name starts with "-", has
  a control character or "/", or is too long is refused with dch serve's own message before dch
  runs. The dash check is on the first byte, so "-" followed by a combining mark is refused too.
  A Claude session created from the phone is named after its session, as a New session on the Mac
  is (#877).
- Extensions: trusted extensions can add owned pieces to Claude Code's config through `host.config`
  (plan, apply, status, remove, repair): marked blocks, hooks, permission rules, the status line and
  seeded files, each written only after you approve the exact diff in a native sheet, backed up
  first, and removed again on uninstall. See "Managed config (host.config)" in extensions.md (#870).
- Ships dch 1.59.0 (was 1.39.0). With 1.40.0, when a newer `dch -a` takes a remote session over, the
  older attach now says another client attached and ends, instead of a plain link loss. `dch -a`
  exits 4 when the host refuses the attach and 5 when it was taken over (both used to exit 1);
  neither is retried. A remote attach can ask for recent scrollback above the screen.
- dch 1.40.1 to 1.41.0: a session ended by a TERM or INT now records who sent it, and the Agent
  Island reads it as "ended (signal 15) from pkill"; the sender's pid is never shown, and the phone
  keeps reading "ended (signal 15)" (#839). A terminal focus report split across reads no longer
  leaks into the session as typed text. New sessions default to FORCE_HYPERLINK=1, so Claude Code
  keeps its statusline links. dch serve gains the remote `ctl` op, which runs allowlisted verbs on a
  host; a session name containing ':' is refused there, so a host never relays on to a third one.
- dch 1.42.0: a remote `ctl` request can be cancelled, and a connection stays open for the next
  request instead of closing after each one. `dch --run` into a Claude Code session goes through
  its composer and never waits: while Claude is still starting it exits 1.
- dch 1.43.0: a shell session keeps a ring of its recent output, split at prompts by OSC 133 marks
  (`dch --shell-init` prints the shell setup), for the coming X-ray view; Prosper does not read it
  yet. The ring is on by default: up to 2 MiB of plain shell output per session, held in dch's memory
  only (never on disk) and readable only by the same user; `xray_ring 0` in dch's config turns it off.
  The ring survives `dch --restart` (#846).
- dch 1.44.0: `dch --xray <name> --json` prints a session's chapters as JSON: a Claude Code session's
  transcript chapters, or a shell session's commands split at prompts. `<name>` can also be an agent
  id or a History record. `dch --xray <name> --clear --json` empties a live shell's ring. Prosper
  does not read it yet, and its Remote Terminal still refuses `--xray` (#849).
- dch 1.45.0 to 1.46.1: a session name with a ':' stays local unless the part before it is a known
  host, so a dead local `proj:task` can be revived and forgotten again. New sessions get
  `LC_TERMINAL=ghostty` instead of FORCE_HYPERLINK=1: Claude Code's statusline keeps its links, and
  other CLIs no longer write links into pipes and files. `dch --xray --clear` no longer wipes the
  screen of an agent session or of a shell whose ring is off. A name shaped like a session id is
  refused in any case and with spaces around it. `dch --say`, `--run` and `--revive` stop at a safe
  point on Ctrl-C, a SIGTERM or a SIGHUP: nothing more is typed, text already typed is taken back
  out of Claude's input box until it is empty, and the result says `interrupted`, `withdrawn` or
  `draft_left`. A remote one that is cancelled or whose client goes away gets up to 660 s for
  that, as in Prosper (#851). A remote request whose host sends back a reason full of control
  characters no longer crashes dch.
- dch 1.46.2 to 1.48.0: in dch's session picker, Shift+Enter or `o` opens a History session, and
  a session opened from the picker goes back to the picker when it ends. A remote `ctl` whose
  host's reply can't be read now says so (#857).
- dch 1.49.0: a first prompt given when a Claude Code session starts (`dch --spawn work -- claude --
  "the task"`) is sent once. Restart, revive and History resume start Claude again without it and
  keep every other option, and the History list and records never store or show it. A command dch
  cannot read as Claude Code's (another agent, an option dch does not know, a one-word prompt that
  is a claude subcommand) is kept whole, as before.
- dch 1.50.0 to 1.50.1: Restart agent and Stop no longer hang on "Exiting…" when Claude Code
  2.1.322 asks "Background work is running": dch exits and stops those tasks, and the result and
  the resume message name what was stopped. An agent stuck on a background shell counts as idle
  after 60 s instead of holding "Pausing…" for 10 minutes. A command that only mentions `claude`
  (`git -C src/claude log --oneline`) is no longer rewritten on revive, restart and in History.
  dch's own picker shows one History row per session name, sorted by name. `dch --xray <name>
  --json` now lists the issues, pulls, tickets, commits, files and URLs a session mentions, and
  `--ref` streams one of them; Prosper does not read it yet.
- dch 1.51.0 to 1.52.0: `dch --history --remote` and the History tab of dch's picker list the ended
  sessions of your other hosts, and Enter resumes one on its host (the host needs `dch serve
  --allow-create`). `--ls-json` rows carry the session's start directory as `"cwd"`. `dch --xray
  <name> --follow --json` streams a session's index as it grows. An X-ray title no longer comes
  from a file outside the project hidden in a compound command, `--ref --full` on a shell session
  with a lot of output no longer comes back empty, and a relative `--ref` too long for a key says
  `dch: not a ref` and exits 2 (was 3). Prosper does not read X-ray yet.
- dch 1.53.0 to 1.54.0: no session name can start with `-` any more (`dch: a session name cannot
  start with '-'`), and a folder named `-x` names its session `_x`. Prosper's own forms already
  refused such names, and one sent from the phone is now refused by dch. One made by an older dch
  is still reached after `--` (`dch -k -- -x`, `dch --forget -- -h`), but cannot be resumed.
  dch's picker fetches other hosts' History once when it opens and then only while its History tab
  shows. X-ray on a shell session also reads the lines still on screen, never a full-screen program
  (vim, less), and a session that ends mid-request answers `dch: no such session`. The list of
  background work Restart and Stop stopped is cut at its length limit on a whole character.
- dch 1.54.0 to 1.55.0: `dch --xray --ref` reads the other sessions of the same project
  (`--scope project`, the default; `--scope all` for every project, `--scope session` for the old
  answer), `dch --xray <n> --chapter <anchor> --json` prints one chapter's entries, and
  `dch --xray host:name … --json` runs on another host's `dch serve`. A `dch serve` you run by hand
  now offers X-ray to the devices it admits: such a device can read file windows from a session's
  project, `git show --stat` and the transcripts of other sessions. Prosper's own Remote Terminal
  does not offer X-ray, and Prosper does not read it yet. A `dch serve` host refuses a session name
  holding a left-to-right or right-to-left mark, an Arabic letter mark or a line or paragraph
  separator, and dch's JSON lines (the session list, History, the verbs' results) now also escape
  the Arabic letter mark and the two separators. dch's picker keeps the selection of another
  host's row apart from a local row of the same name.
- dch 1.55.0 to 1.57.0: `dch --xray <n>` with no `--json` opens X-ray as a view in your terminal,
  for a session on another host too (`dch --xray host:name`), and dch's picker opens it with X. In a
  `dch` attach in your own terminal, the detach key and then x within the double-press window (300 ms
  by default) opens the view instead of detaching; with a later x the attach still detaches (or
  switches, when your detach key is also your switch key).
  Prosper's own terminal still passes every key to the session. Each `dch --revive --json`
  result line ends with a "running" key. A `dch serve` you run by hand lets go of a device that
  vanished without closing its connection after about 30 s. Also when you run the bundled dch by
  hand (all in 1.56.0): fixes to `dch --xray --follow`; X-ray across Codex sessions and the resolver
  card; a remote X-ray whose host sends nothing for 65 s ends with exit 7; a remote History record
  that gives a key twice is dropped; the picker draws bidi control characters as `?`; `dch --forget
  -h` (and --pin, --unpin, --stop) says that a name starting with `-` goes after `--`; and `dch
  serve` sets TCP no-delay on every connection. Prosper does not read X-ray yet.
- dch 1.57.0 to 1.58.0: a security fix in `dch --xray`. Since 1.57.0, a session whose project was
  a credential directory kept as its own git repo outside your home (a Claude Code config dir, a
  Codex home, `.kube`, `.docker`, `.password-store`) showed its files, also to a `dch serve` peer;
  they are refused by name again, and more credential file names are on the list. In a `dch -a
  host:name` attach in your own terminal, the detach key and then x opens the X-ray view of that
  remote session; a host on dch serve 1.58.0 turns bracketed paste, mouse reporting, the keyboard
  flags and the alternate screen back on when you leave it. The Prosper server does the same
  since this release. The X-ray view
  hides chapters for prompts the harness wrote (task notifications), and one device holds at most
  two `--xray --follow` of one session. Also fixed in dch: the remote X-ray view hanging on q or
  Esc, a crash in a very small window, `dch -d` not detaching a client that has the view open, and a slow reader cut off
  after 65 s. Prosper still does not read X-ray.
- dch 1.58.0 to 1.59.0: a key change in dch's picker (`dch -l`, the switch, the `-k` and `-d`
  pickers): `x` now opens the row's X-ray view and `X` kills, the other way round from before; kill
  still asks first. Suspending an attach with ctrl-z now hands the shell a clean terminal (the main
  screen, with mouse reporting, bracketed paste and the kitty keyboard flags off) and `fg` repaints
  the session; repeated suspends no longer leave kitty keys on in the shell. A session started by an
  older dch needs `dch --restart` for its side of that fix. A `dch serve` host no longer drops the
  rest of a large one-shot answer (`dch --xray host:x --json | less`) when the reader pauses for
  20 s. In the X-ray view, a remote host's screen can no longer put invalid UTF-8 or a NUL on your
  terminal. Also fixed in dch: the X-ray view left on a cooked terminal after fast keys, a new PR or
  issue getting another item's title in X-ray, and more commands that read outside the project no
  longer define X-ray references.
- Snippets: a snippet with {argument} placeholders now asks for them. A small panel shows the snippet's
  name and one field per argument, prefilled with its default: Return inserts, Escape cancels, Tab moves
  on, and Insert stays off while a required field is empty. A snippet whose arguments all have defaults
  now asks too (it used to insert the defaults at once). It works for a typed keyword, the `sn`
  palette and a bound Shortcuts hotkey, for plain and rich-text snippets, and asks for the arguments of an
  embedded {snippet:…} in the same panel. A typed keyword is erased when the panel opens, as an
  expansion would; Return inserts at the caret, and Escape types the keyword back (with the space or
  punctuation that triggered it, never Return or Tab). Either way focus goes back to the app you typed
  in, and nothing is typed if another app took focus meanwhile, if that app could not be brought back,
  or if a password field took the caret; Prosper beeps in each case (#848). If you click back into the
  app before you answer, the text goes in at the caret where you left it. The panel shows over
  full-screen apps, never opens in a password field, and macOS Text Replacements never ask (#842).
- Settings → Appearance → Theme: High Contrast Dark and High Contrast Light now come in tints. Click a
  dot on the theme's row to switch its accent (Dark: Lime, Cyan, Amber, Violet, White; Light: Blue,
  Lime, Cyan, Amber, Violet, Black). Each theme remembers its own tint. Theme extensions can offer
  tints too, through a new `variants` list in theme.json.
- Agent Sessions window: start new sessions from the window. Two buttons sit next to the session count:
  "+" (⌘N, also the "New session" button when nothing is selected) opens a form in place of the detail pane with
  the folder (recent folders and Choose…), the name (the folder's free name until you type one) and the exact
  command, shown as it will run; an empty command runs your login shell. ">_" (⇧⌘N) starts a login shell at once
  in the last folder, named after it, or "shell" when dch cannot use that name; with the form open, it uses the
  form's folder and name instead. Holding the shortcut starts one.
  Return starts, Esc cancels and puts the keys back where they were. After Start the form reads "Starting…" until
  the new session is listed, then selects it in Terminal with the keys in it. A name dch cannot keep in its session
  folder is refused with the real limit, a name that differs only in case from an existing session counts as
  taken, and a second shell started before the first is listed gets the next free name. Both buttons dim, with the
  reason, while session controls are unavailable, and a start that fails says why (#847).
- Remote Terminal: the Mac's session server now refuses a session name holding a bidi mark (U+200E, U+200F,
  U+061C), a line or paragraph separator (U+2028, U+2029) or a NUL, as dch serve 1.55.0+ does: attach, create,
  rename and kill are refused for it, and the rename says "invalid session name". A create whose request is not a
  JSON object is refused instead of starting a session with no name, and a kill of a name whose first byte is "-"
  is refused even when a combining mark follows it (#879).
- Agent Island: Resume all no longer reports an old History record whose name starts with "-" as a new failure
  every run; its row and the summary now say dch can no longer start that name ("1 session has a name dch can no
  longer start") (#878).
- Agent Sessions: ⌘W, ⌘T, ⌘F, ⌘G, ⇧⌘G, ⌘N and ⇧⌘N now work while a Cyrillic, Greek, Hebrew or other non-Latin
  keyboard layout is active (#882).
- Remote Terminal server: matches dch serve 1.58.0. A redraw request now also turns the session's
  bracketed paste, mouse reporting, focus events, keyboard flags and alternate screen back on, as
  dch serve does when a `dch -a host:name` client leaves the X-ray view. Requests are read as dch
  serve reads them: a UTF-8 byte order mark before the request, a key given twice, or a text with a
  NUL or a broken surrogate escape is refused instead of being read loosely, and none of these
  reaches dch. A create whose command is not a list of strings (or has more than
  256 words) starts nothing, a rename whose alias is not readable no longer clears the alias, and a
  window size from the phone above 65535 or below zero no longer crashes Prosper: a size above 1000
  is capped at 1000, and a width or height of zero or less reads as its default, 80 wide or 24
  high (#885).
- Remote Terminal: the phone terminal no longer waits a network round trip between the pieces of a
  screen update. The Mac session server now sends every small update at once (TCP no-delay)
  (#888).
- Live session status: when a phone's sign-in expires, its Live Activity card is ended within a
  minute and it gets no more session alerts or updates. The server's every-minute check also reads
  far less of its database (#1001).
- URL Dispatcher: a routing rule now also matches the link with its %-escapes decoded, so a rule
  like "My Sites" or "café" catches links written My%20Sites or caf%C3%A9; the link opened is
  unchanged, and escaped URL delimiters and control bytes stay escaped for the match. A stored rule
  whose text is not a string is skipped instead of stopping routing for every link (#936).
- Live session status: when a sign-in expires, its Live Activity card on the phone now ends with
  no session list (as on sign-out), and the nightly cleanup no longer leaves such a card frozen on
  the Lock Screen. The server's every-minute check now reads only cards due for rotation and
  expired sign-ins instead of every card (#1014).
- Extensions: an extension.toml (or imported codex config.toml) with a table header of more than 64
  segments, such as `[contributes.kit.a.a.a…]`, is now refused as malformed before the TOML parser
  reads it, instead of crashing Prosper while it loads; an Agent Kit nested deeper than that is
  refused with a reason. An extension.toml over 1 MiB is refused without being read whole into
  memory, for built-in, local, GitHub and market installs alike (#883).
- Claude Account Pool (opt-in extension, off by default): turn on "Claude Account Pool" in
  Settings › Extensions to rotate several Claude subscription accounts behind one local proxy on
  127.0.0.1. Tokens live in the Keychain only. The proxy runs while the extension is on and the pool
  lists an account; it starts with the first account, stops with the last one or when the extension
  is turned off, and stops when Prosper quits. Its Settings page adds, renames, orders, holds and
  removes accounts, refreshes usage, and imports the accounts of the Homebrew ccpool once; the old
  vault goes to the Trash only if it is still the same plain file holding only accounts the pool
  now has (#871).
- Theme tints: VoiceOver now says which theme is active and reads only its ringed tint dot as
  selected (another theme's remembered dot says "remembered"); every dot shows its name on hover;
  tint names from third-party themes are cleaned of invisible characters and capped at 32; a
  refused tint list is no longer logged again on every rescan, only when its reason changes or it
  comes back after a fix (#862, QA #744).
- Settings shortcut fields now draw Home, End, keypad Enter and Clear with the glyphs macOS menus
  use, keypad keys read "Pad1", "Pad+" and the like instead of "Key<n>", the ISO and JIS keys (§, ¥,
  _, 英数, かな) show their own names, Help reads as a word, and VoiceOver reads a shortcut field as
  a button with the combo in words (#890).
- The coding agent now defaults to Qwen3.6 35B-A3B on Macs with 32 GB of RAM or more. A Mac that
  already has Qwen3-Coder 30B downloaded and never picked a model keeps using it until Qwen3.6 is
  downloaded; smaller Macs are unchanged (#892).
- opencode plugins in Prosper now get the same hook inputs opencode gives them: tool.execute.after
  receives the tool's arguments, permission.ask receives a Permission object (id, type, sessionID,
  messageID, title, metadata, time), and plugins that register an experimental workspace no longer
  fail to load. `type` is opencode's permission kind ("bash" for shell commands, "edit" for file
  patches; other tools, such as MCP tools, keep their codex name), and codex's own tool name stays
  in `tool` and `title`. Plugins written as `export default { server }` now load, a function
  exported twice (by name and as default) runs once, and plugins get `project.worktree` and
  `project.time.created`; `serverUrl` is present but undefined, because Prosper runs no opencode
  server (#183, #949).
- The volume mixer no longer risks reading past its own memory, or reserving an outsized buffer,
  when an output device reports a stream layout that changed mid-read or looks implausible; it falls
  back to stereo limiting.
- Fans: when the overheat cut-off lets one fan take your speed but not the other, Prosper no longer
  leaves the fans split or re-pins one of them every few seconds; it keeps your speed as the pending
  preset and applies it to every fan together once macOS allows it.
- Mixer: a device or app that appears while the mixer is reading the audio device or app list no
  longer makes another device or app drop out of the list for a moment.
- System Settings search: on macOS versions without the Passwords app, the Passwords row now opens
  the Passwords settings pane with its own icon instead of showing a blank file icon and opening
  nothing.
- OpenLid: turning the extension off and back on now really keeps the Mac awake again (or ends a
  timed session that ran out meanwhile) instead of showing "awake" while nothing held it; re-enabled
  extensions also get their shortcuts, rules and timers back without a relaunch.
- A model download that was stopped or interrupted is no longer shown as downloaded when its small
  setup files never arrived; the app now records when a download finishes, and models downloaded
  before this update still count as downloaded.
- Managed config: an approval now covers the exact bytes Prosper writes, so if a config file changes
  under the sheet in a way the masked diff cannot show (a hidden env value, line endings, a BOM),
  you are asked again instead of the old approval being reused, and the repeated sheet says the file
  changed after it opened.
- Managed config: the Remove and Repair sheets now say when a Prosper block holds your own edits, so
  deleting or replacing them is never a silent part of the diff.
- Managed config: a block you edited after Prosper lost its record can be repaired from the
  extension's declared pieces after the sheet shows your edits (core only; the button comes with the
  sheet update), after which Remove and uninstall can take it out.
- Managed config: text blocks and permission strings are compared byte for byte, so a file re-saved
  in another Unicode normalization shows as drift instead of passing as unchanged, and a permission
  that differs only in normalization is added as its own entry.
- On macOS 27, a click on another app's menu-bar icon now closes an open Stats, Mixer or Calendar
  popover even when one of Prosper's own icons was moved into the menu bar's overflow or hidden.
- Clipboard settings now say when macOS is set to keep Prosper from reading what other apps copy (or
  to ask every time), and link to System Settings › Privacy & Security › Paste from Other Apps to
  change it.
- Coding agent: messages, turn endings and approval requests from another codex thread (a sub-agent,
  a review or a forked thread) no longer show up in your session or end your turn early; that
  thread's approval requests are declined instead of being shown as yours.
- When macOS refuses Prosper access to a browser file (search engines for Fallback Search, or
  bookmarks), Prosper now logs that the file could not be read instead of silently treating it as
  empty; browsers that are not installed stay silent.
- App Updates: the "N packages upgraded" count now compares against Homebrew's list right before the
  upgrade, so packages you upgraded in Terminal are no longer counted; brew's output goes to a file
  in Prosper's private folder, so quitting Prosper during an upgrade no longer stops brew partway; a
  background upgrade stopped by another Homebrew process now says so; a lock message from Homebrew's
  auto-update no longer turns a later failure into a "lock" notice; a failed upgrade whose list
  could not be re-read says the list is stale; a folder that could not be created reads "brew
  upgrade did not start" instead of "failed (exit ?)"; the private folder is removed when the watch
  gives up or Prosper relaunches; and a clock set back no longer blocks Upgrade for two hours.
- Hammerspoon compat example: without "Grant System Access", hs.execute no longer returns the error
  sentence as command output; it returns no output with a failed status, and the extension logs once
  that hs.execute needs System Access.
- Editing MCP servers or hooks in Settings no longer drops keys Prosper does not use from mcp.json
  and hooks.json, and no longer overwrites a file it cannot read (broken JSON from a half-finished
  hand edit, for example).
- Resume and Resume interrupted (in Agent Island and from the iPhone) now count a session as resumed
  whenever dch says its Claude is running, even if the resume message could not be sent (for example
  a prompt was on screen); the island's line says the message wasn't sent (the iPhone app reports
  the resume as done and shows that note after its next update), and a session whose Claude is not
  running is reported as failed. The island's tally now puts that note next to the resumed count ("2
  resumed (1 resume message not sent), 1 failed"). On the iPhone, Resume all now reports success
  when at least one session resumed and the only other sessions are old ones whose names start with
  "-" (which dch can no longer start), instead of an error.
- Default, Daylight, Graphite and Silver now come in accent tints, picked from the dots on the
  theme's row in Settings > Appearance. The Violet tints (Default, Daylight) and Daylight Ink keep
  the theme's base blue as their secondary colour. (#911)
- Agent Sessions window, New session: a session that dch started but that never shows up within 15
  seconds (its command ended at once, or never started) now leaves the form open, ready to start
  again, with "<name> ended at once or never started: check the command"; a ">_" shell in that case
  says it in the line under the session list. A session that shows up while the window is on another
  Space is still selected when you come back. When session controls are unavailable, ⌘N and ⇧⌘N now
  say why on that line instead of doing nothing. While the form is open, ⌘T, ⌥⌘1/2/3, ⌘F, ⌘G and
  ⌘↑/⌘↓ no longer act on the hidden session behind it. VoiceOver reads the form's fields by name,
  the folder picker's button says "Choose", and an empty session list explains where sessions come
  from. On the "Dvorak - QWERTY ⌘" layout each window shortcut now fires from one key only, so ⌘, no
  longer closes the window (#887).
- URL Dispatcher: a rule that is a domain (github.com) now matches only links to that site or its
  subdomains, so a link that merely mentions the domain in its path, query or login part, or a
  look-alike such as github.com.example.net, no longer opens in that rule's browser. A rule ending
  in a dot (google.) matches that name with any ending (google.com, www.google.de, but also
  google.evil.example), and a rule of numbers (192.168) matches addresses that start with it. Some
  saved rules stop matching: a domain written without its ending (docs.google no longer matches
  docs.google.com), a domain that is the start of a longer one (google.com no longer matches
  google.com.au), a rule that is only part of a name (my.sharepoint.com no longer matches
  contoso-my.sharepoint.com), and a file name (index.html now matches only file links). Write the
  whole host (docs.google.com), end the rule with a dot (google.), or start a file name with a slash
  (/index.html). Other rules (localhost, /index.html, -my.sharepoint.com, a word) still match
  anywhere in the link, and the rule field is now labelled "Domain or text". A copied link that
  contains some accented letters (such as à) is now cleaned of tracking parameters reliably.
- Agent Sessions: plans written with a table without outer pipes, "~~~" code fences, "===" or
  closing-"#" headings, a "[X]" task or a <https://…> link can now be approved from the window, a
  plan file under a symlinked ~/.claude or plans folder is read (links inside the folder are still
  refused), and the refusal for a numbered draft in Claude's input now reads "Claude's input already
  holds a draft" instead of "Claude is showing a prompt".
- Clipboard history: deleting the last row now selects the row above instead of jumping back to the
  top.
- Clipboard sync with iPhone: the Mac now checks a clip's content itself before treating it as a
  copy of one it already has, removes files left behind by a quit in the middle of saving a phone
  clip when it next starts, and no longer stalls on a phone file with an extremely long or unusual
  name.
- When macOS refuses to let Prosper read a browser's search engines, the log now says which browser
  it was (for example "Chrome Default/Web Data copy failed"), and the bookmarks import now logs when
  it cannot list a browser's profiles instead of quietly finding nothing.
- Coding agent: when a sub-agent that your codex session started asks for approval while the
  session's turn is running, you now get the approval card, marked "Asked by a sub-agent of this
  session", instead of the request being declined without asking you. This covers sub-agents that
  codex spawns from the session (and their own sub-agents); forks, review sub-agents and other
  threads are still declined, and a card you have not answered when the turn ends is declined then.
  A turn you stopped that ends late no longer takes the next turn's approval cards with it, and
  resuming a session that codex answers under another thread id keeps that thread's token usage.
- Agent Island: a session row's right-click menu has "Message…". It opens a one-line box in the
  island: type, press Enter or Send, and dch types the message into that session's Claude. Esc or
  Cancel closes it, and so does closing the island; the draft is not kept. The row reads "Sending…",
  then "Sent" or dch's reason (for example "no claude runs in the session"). A session whose Claude
  is showing a prompt (a permission question, a plan approval) is not messaged: Prosper reads its
  screen first and the row says to open it in a terminal.
- Agent Island: the "⋯" menu has "Message all in Sessions…" (or "…Sidekicks…"), which sends one
  message to every live session in that tab, by name, and shows "N sent, K skipped, F failed" per
  folder. A session that is showing a prompt is not messaged and counts as skipped. While another
  island action is running on a session of a folder, none of that folder's sessions is messaged and
  the folder line says so.
- Agent Island: a Restart whose master fails now shows dch's own error line, and a Resume that could
  not start the program shows the exec error (for example "No such file or directory") instead of a
  generic "did not start".
- Managed config: a text config file that starts with a byte order mark keeps it at the very start
  when an extension adds, updates or removes a block at the top of the file, and such a block no
  longer reads as corrupt. Seed files are copied byte for byte, byte order mark included. A
  permission change made to a file while the confirmation sheet is open is kept by the write.
- Shortcuts: the shortcuts for Settings, Coding Agent, Agent Sessions, Clipboard History, the
  Command Runner and Translate now work the same way: a press opens the window or brings it back to
  the front, and a press while you are using it closes it. A Clipboard History or runner left open
  behind another app is no longer closed by its shortcut; it comes back with your search kept
  (Translate and shortcuts on a prefix come back as their own runner: see the entries below).
- Menu bar: the Command Runner and Clipboard History items now only open or bring back their panel;
  they no longer close it.
- Ships dch 1.60.0 (was 1.59.0). A session remembers a terminal mode switch (alternate screen, mouse
  reporting, bracketed paste, the kitty keyboard flags) even when the program's bytes for it arrive
  in two pieces, so a later attach no longer gets the wrong modes. After ctrl-z, `bg` and `fg` an
  attach is raw again instead of echoing keys and waiting for Enter. A session name that is a path
  is refused. The X-ray view hides compactions and Claude Code's own prompts until `n`, `o` opens
  the session the view is about, and it no longer opens `.yarnrc` or `auth.json`. `dch -d` now also
  detaches a remote client that has the X-ray view open.
- Agent Island: the open island now also closes when you click in another Prosper window, such as
  Settings or Agent Sessions, or when another Prosper window takes the keyboard; before, only a
  click in another app closed it. A window that takes the keyboard by itself never drops a message
  you were typing in the island; a click elsewhere still closes the island and drops it.
- **Shortcuts**: the Calendar shortcut now works like the other window shortcuts. If the popup is
  closed, it opens. If it is pinned and you clicked away from it, the shortcut brings it back
  instead of closing it. If it already has focus, it closes (#1113).
- **Shortcuts**: a custom runner shortcut, or a bound quickdir hotkey (which uses the "qd <name>"
  prefix), closes the runner only if that same shortcut opened it, the runner has focus, it is still
  in that shortcut's mode, and the text still starts with the prefix. Text typed after the prefix
  does not change that; deleting the prefix and typing something else makes the next press switch
  back instead of closing. If one shortcut's prefix starts another's ("qd Dev" and "qd Devices"),
  the press switches between them instead of closing. If the runner was opened some other way (the
  main hotkey, the menu bar item), a shortcut press switches it to that shortcut's prefix (#1113).
- **Shortcuts**: Translate (⌥L) now works like a custom shortcut on the "l " prefix. A runner in
  Translate, opened by ⌥L or put there by typing "l ", comes back with its text kept when it was
  left open behind another app, and closes when it has focus. A runner showing something else, in
  front or behind another app, is switched to a fresh Translate and what it showed is not kept. The
  same holds for any other shortcut whose prefix only switches the mode, such as "g " (#1113, #1121).
- **Shortcuts**: a shortcut for an extension command that opens a window (such as Base64 or Add
  Quicklink) now works like the other window shortcuts. If that window is open but you clicked away
  from it, the shortcut brings it back with what you typed still there, instead of starting a fresh
  one. If the window already has focus, it closes (#1113).
- **Shortcuts**: when a shortcut switches an open runner to its prefix, paste, snippet fill-in and
  menu commands still go to the app you were using before the runner opened (#1113, QA 844).
- Agent Sessions window: the session header is lower: one line in Terminal mode, with the folder
  path beside the title (shortened in the middle, and left out entirely when the window is too
  narrow for it); Transcript mode keeps the path on a second line. A title too long for the line is
  now cut at its end, not in the middle. Terminal mode no longer shows the dimmed view picker, and
  the Terminal | Transcript switch (Terminal, the default, now on the left) and the "⋯" button stay
  in place when you switch modes (#1103).
- Agent Sessions window: "Open in terminal" moved from the header into the "⋯" menu (first item) and
  a session's right-click menu; a notice that says "Open in terminal" now has the button next to it
  (#1103).
- Agent Sessions window: the sidebar's "Agent Sessions" title sits on the same line as the session
  title beside it again (#1103).
- Theme tints: accent text in Daylight, Graphite and Silver is easier to read on the lower part of
  windows, in the sidebar and on highlighted rows such as your messages in Agent Sessions; a few
  accent shades moved slightly darker or lighter, with the same hue. (#1095)
- Extensions: once the first Agent Sessions terminal had opened, the embedded Lua followed the
  system language settings. On a Mac whose region uses a decimal comma, Calculator, Units, Currency
  and Kill Process then showed numbers with a comma, and lower/upper case and pattern matching
  corrupted text with accented letters. Lua now ignores the process locale for text case, character
  classes and numbers, for third-party extensions too. (#1099)
- Safety fix: Always allow permission prompts now answers only in a session where dch reports a
  running Claude Code. A session where dch finds none (a shell, a script, another agent, a file
  being printed) that happens to show text shaped like a Claude Code permission prompt is no longer
  answered; it keeps its card and its Needs input notification, as with the setting off. The check
  is made again right before the key is sent, so a session whose Claude Code has just exited is not
  answered either. One case is still answered: dch counts a Claude Code you suspended with Ctrl-Z as
  running, so such a text in the shell in front of it gets the key. A Claude Code session that dch
  cannot name as one is left to you the same way: two Claude Codes started side by side in one
  session, a Claude Code that does not run under the session itself (inside ssh, tmux or a
  container), one whose transcript file is not found, or a dch older than 1.30. (#935)
- Agent Sessions and the island: the age on a session row no longer counts seconds. It reads "now"
  under a minute, then 1m, 2h, 3d; a working session shows no age (its state already says Working),
  and VoiceOver reads "just now". (#1114)
- Agent Sessions and the island: a session or a History record with a broken far-future time no
  longer crashes Prosper when its age is drawn. (#1114)
- Default theme: the indigo accent of the Neon and Amber tints is very slightly brighter, so its
  text keeps enough contrast on highlighted rows. (#1122)
- Text Viewer, a new built-in extension: Prosper is offered in Finder's Open With menu for plain
  text files, Markdown included (.md and .markdown), which also covers logs, CSV files, shell
  scripts and source code. It registers as an alternate viewer for plain text only and does not ask
  to be the default app. If a kind of file starts opening in Prosper after this update, set its app
  back in Finder's Get Info, under Open with. The file
  opens in a read-only Prosper window with selection, Copy (the text or the path), Find (⌘F, ⌘G,
  ⌘E), Open in the default app and Reveal in Finder. The window reloads when the file changes, and
  opening the same file again brings its window forward. A binary file, a file over 16 MiB, a
  folder or a pipe is refused with a message. (#1106)
- Files search: Markdown and .txt results have a new action, Open in Prosper. (#1106)
- Themes: the accent colours of Daylight and Silver are a shade darker, so accent text stays
  readable on the tinted top of the Settings and Agent Sessions sidebars. (#1124)
- Extensions: comparing text with < and table.sort now order it byte by byte whatever the system
  language. Before, once a terminal had opened, the system's sorting rules applied: "a" came before
  "B" and accented letters moved between the plain ones. (#1099)
- Security: an extension's Lua code could get past the sandbox to the whole Lua standard library,
  and through it run commands, read and write files and load native code with no permission asked.
  Extensions now get only the base functions, coroutine, table, string, math, utf8 and
  debug.traceback, and load takes source text only. An extension that called another debug function
  or string.dump gets an error at that call. (#1125)
- Remote Terminal: "Resume interrupted" from the iPhone now reports a failure in any one folder
  instead of answering as if everything resumed, and when a resume message was not sent beside a
  session dch can no longer start, the phone names that session again. "Restart all" names such a
  folder in its error too. (#951)
- Agent Sessions: a session row now shows its agents, merged pull requests and (when the chips do
  not fit) open pull requests as small icons with a number instead of words, and the ages keep
  updating while you scroll. (#1115)
- Marketplace: a download no longer returns the publisher's e-mail address. Packages are signed with
  an anonymous publisher id instead, and packages already published keep installing. This is a
  change in the Marketplace service and takes effect when the service is updated; no app update is
  needed. (#1138)
- Closing a text viewer window no longer leaves its file open in the background, and "Open in
  Prosper" on a file that is not a text document no longer moves that file up in search
  results. (#1130)
- Agent Island: while dch cannot list its sessions, Always allow no longer answers prompts in the
  sessions it still shows from the last list; those prompts keep their card and send Needs input
  until dch lists again. (#1133)
- Extensions: the limit on how long one call into an extension script may run can no longer be
  outrun. There is one limit per call, shared by all of the script's coroutines; once it is spent
  the call ends with "execution budget exceeded", and pcall, xpcall, coroutine.resume, an error
  handler or a close handler cannot keep it going. An extension that sets a `__gc` finalizer now
  gets an error from setmetatable, and collectgarbage only reports ("count", "isrunning"). (#1126)
- Ships dch 1.62.0 (was 1.60.0). A paste into a program that is busy printing no longer freezes the
  session. In an attach, a key typed right after the detach key counts even on a busy machine. The
  X-ray view lists pull requests, issues and tickets with the one mentioned last at the top, `a`
  shows files, commits and URLs too, and `Ctrl-R` looks up a ref typed in the filter; on a ref's
  card `o` opens the session and the other-projects scan moved to `p`. The view says why it has
  nothing to show, and comes back whole after a stop and `fg`.
- Settings › Text Viewer has a new "Make Prosper the Default" button: click it to have .txt and
  Markdown files open in Prosper when you double-click them. Nothing changes until you click it, and
  the page shows which app opens each kind now. (#1134)
- Marketplace publish no longer uploads hidden files and folders (such as .DS_Store, macOS "._"
  metadata files, or a coding tool's state folder) or your Mac account name from an extension's
  folder, and installing an extension now leaves out any hidden files an archive still carries.
  (#1131)
- Hardening: an extension download that holds a folder Prosper cannot read is now refused instead of
  installed unchecked, and a GitHub address with "." or ".." parts is not accepted. (#1131)
- **Runner and Clipboard History**: a paste goes where you were when you opened the panel. Opened
  (or brought back with its shortcut) while you were in a Prosper window such as Agent Sessions or
  Settings, the paste lands in that window. Opened while Prosper is in front only because the runner
  or Clipboard History put it there (Clipboard History opened over the runner, or the runner opened
  again right after its shortcut closed it), the paste goes to the app you opened the runner from,
  as long as you have not switched to another app since. If that app has quit, nothing is pasted
  into another app and the text stays on the clipboard (#1121).
- File search: an action on a file that no longer exists does nothing and no longer counts as a use
  when results are ranked. (#1143)
- Hardening: each extension's Lua runtime now has its own memory limit (256 MiB). A script call that
  goes past it fails with "not enough memory" and the runtime stays usable; Prosper's own reads and
  writes of an extension's globals no longer run the extension's metatable code (#1127).
- Extensions installed from GitHub: installing or checking for updates now removes only the download
  folder it created, and a download that is refused no longer leaves files behind in your temporary
  folder (#1152).
- Hammerspoon Compat: `app:hide()` at the top level of your init.lua now runs once when the config
  is applied (at launch, when you turn the extension on, or on Re-read config), like every other
  action written there, and no longer again whenever Prosper re-reads the config in the background
  (opening its settings, after you edit the file, or after a callback was stopped for running too
  long). (#1149)
- Extensions: a host function called from inside a Lua coroutine now reads its arguments from, and
  returns its results to, that coroutine, so extensions that use coroutines get the right values
  back. (#1151)
- Runner and Clipboard History no longer press Command-V unless the app you opened them from is back
  in front: if it has quit or another app came forward meanwhile, nothing is typed, the text stays
  on the clipboard and you hear a beep, as with snippet fill-ins. (#1150)
- Two shortcuts on one extension's window (another text, such as "ql add GitHub" and "ql add Jira",
  or another window command of the same extension) now each open their own view; only the shortcut
  that opened the view brings it back or closes it. (#1123)
- Hammerspoon Compat: an object your init.lua made while it was being applied (for example an app
  object kept in a shared table) can no longer act later from a background re-read of the config; it
  acts only while the config is being applied or from its own hotkey, timer, URL, app-watcher or
  event-tap callbacks. (#1156)
- Extensions: a call an extension's host function makes back into the same extension now runs on the
  instruction budget of the call it is part of, so a long-running extension script is always stopped
  on time. (#1154)
- Text Viewer now shows Markdown formatted: headings, bold, italic, strikethrough, code, nested
  lists, task lists, quotes, tables and horizontal rules. (#1118)
- Text Viewer: links in a Markdown file show their full target on hover. Web and mail links open on
  a click; a link to a heading in the same file scrolls to it; links to other text files open in
  another viewer window; any other local file is shown in Finder, never opened or run. (#1118)
- Text Viewer: images inside the Markdown file's folder are drawn, the first 64 of a file; later
  ones show their alt text. Images from the web are never downloaded; their alt text shows instead.
  (#1118)
- Text Viewer: very large or very deeply nested Markdown files are shown as plain source, with a
  note saying why; when a file has more links, table cells or styled text than the viewer draws, a
  note says the rest is shown as plain text, and a table beyond 50,000 cells is shown as plain rows
  so it cannot freeze Prosper. A table wider than 64 columns is shown as plain rows too. (#1118)
- Text Viewer: files open without blocking Prosper; the text is read and formatted in the
  background. (#1118)
- Text Viewer: Copy now copies every part of a multi-part (Option-drag) selection, and Copy Path
  works for files the viewer cannot show. (#1118)
- Text Viewer: ⇧⌘W and ⌥⌘W no longer close a viewer window; ⌘W does. (#1118)
- Text Viewer: opening several files at once while the extension is off shows one notice, not one
  per file. (#1118)
- Text Viewer: a window opened through a symlink keeps showing the file it opened, even if the link
  is changed later. (#1118)
- Text Viewer: a UTF-16 file with an unpaired surrogate is shown read-only instead of as clean text.
  (#1118)
- Text Viewer: right-clicking a link in a Markdown file offers Copy and Copy Link Address only;
  nothing in that menu opens the link. The viewer no longer starts the system's force-click action,
  the one that could preview a link's web page without a click, and a three-finger tap on a link
  does nothing. (#1118)
- File search no longer gives a file the ranking of a file deleted from the same path more than 30
  days before. (#1153)
- The Agent island now shows a session's agents and merged pull requests as an icon plus a number,
  as the Agent Sessions window does; the narrower merged count leaves room for more pull request
  chips, and VoiceOver and the tooltips read "3 agents" and "192 merged pull requests" (#1137)
- Publishing an extension to the Marketplace now first lists the files it will send (and how many
  hidden or test files it leaves out); nothing is uploaded until you click "Publish N files", and a
  symbolic link or a folder Prosper cannot read stops the publish with its name instead of producing
  a package no one can install or one that is missing files. (#1141)
- Two installs or updates of the same extension running at the same time no longer delete each
  other's download; the second one stops with "this extension is already being installed", and a
  download folder left behind by a crash is cleaned up the next time that extension is installed
  from GitHub. (#1141)
- Hammerspoon Compat: a timer's start() and stop() at the top level of init.lua no longer re-arm or
  cancel the timer every time the config is re-read in the background; they take effect when the
  config is applied and from hotkeys, timers and other callbacks. (#1158)
- Hammerspoon Compat: an app object kept by a hotkey, timer, URL or app-watcher callback that was
  stopped for running too long can no longer hide an app from a later run of the config (#1158)
- Ships dch 1.73.0 (was 1.62.0). In the X-ray view the reader reads on into the next and the
  previous prompt, and `]` and `[` step between prompts. The tabs are Prompts (Commands for a shell
  session), Responses (what the agent answered at the end of each turn, newest first), Refs (the
  refs on the screen right now come first) and Search (type a word or phrase to find where the
  session said it). `dch --xray <session> --search <text> --json` does the same from a script. On
  macOS a stopped session is no longer taken for a dead one and started over, and a stop while `dch
  -a` starts no longer leaves the shell on a raw terminal. With 1.65.0 the session list on macOS
  stays fast after sessions that were killed hard or crashed (the beta that shipped 1.64.0 slowed
  down there), a command typed while the one before it still runs gets its own chapter in X-ray,
  opening a chapter of a long session is much faster, and a second Claude started in one session is
  seen by X-ray. With 1.66.0 the X-ray view has a Tasks tab (the task list of a Claude Code or Codex
  session) and a Memory tab (its memories and instruction files), `dch --xray <session> --tasks
  --json` and `--memory --json` print them for a script, a refused `--send` or `--run` leaves
  nothing typed, and Claude started under a wrapper no longer gets text typed where a shell would
  read it. With 1.67.0 `dch --xray <session> --follow --json` goes on when the session is restarted,
  and `--run` is refused with the code `not_foreground` when Claude sits under a wrapper that does
  not pass the keyboard on. With 1.68.0 a Search hit in the X-ray view opens at its own place when
  the same text appears more than once, and `--tasks` and `--memory` no longer run a configured
  command line over 1023 bytes cut short: they skip it, say so in a warning and answer from their
  own reading. With 1.69.0 `dch --xray <session> --follow --json` and the X-ray view keep going
  across restarts however quickly they follow each other, and `--run` types again into the program
  in front of a suspended Claude when that program is the end of a pipeline whose first command has
  finished. With 1.70.0 Enter on a Search hit opens the right one when the same text comes again
  past the clipped part. With 1.71.0 a Search hit opens the entry it came from when the same text
  sits in several entries of one prompt. With 1.72.0 X-ray tells prompts another agent sent apart
  from the ones you typed; a remote attach with the X-ray view open answers a starting program as a
  local one does; a config line holding a stray NUL byte no longer hides or damages the line after
  it; and revive and respawn wait for the session's MCP servers before the first prompt. With 1.73.0
  X-ray's references now find a mention in the middle of a very large transcript, the reference card
  keeps the newest mentions when the machine is busy, and a slow Tailscale lookup no longer locks a
  phone out of the Mac for 30 s. (#1167, #1178, #1282)
- Agent Sessions: Command-1 to Command-9 jump to the session at that place in the sidebar and put
  the keyboard in it (its terminal or its message box), from anywhere in the window; each of the
  first nine live sessions shows its ⌘ number as a chip, as in Clipboard History. (#1110)
- File search now offers "Open in Prosper" on every file the Text Viewer can show (logs, source code
  and other plain-text files), not only Markdown and .txt files. (#1148)
- Hammerspoon Compat: a timer's running() now reports whether the timer is armed (started, stopped,
  or a one-shot that already fired) instead of always answering true. (#1161)
- Hammerspoon Compat: a config that replaces a standard string function can no longer act with
  permissions left over from an earlier run that was stopped for running too long. (#1161)
- Text Viewer: a window opened on a file that does not exist yet now shows the file as soon as it is
  created, and a file that is deleted and created again shows its new contents (before, the window
  kept saying the file was not there). (#1147)
- An extension can no longer hang Prosper with a single slow string or table call (a heavy pattern
  match, sort or repeat): that work now counts toward the extension's time budget, and the call
  stops with an "execution budget exceeded" error instead. (#1145)
- Ordinary extension work (searching and replacing in large text, sorting or joining long lists)
  runs as before. (#1145)
- Publishing an extension to the Marketplace now uploads exactly the files you confirmed: a file
  added after you confirm is not sent, and a confirmed file that was removed or replaced by a link
  stops the publish and is named. (#1160)
- The publish list no longer closes on its own when the Marketplace version loads and the button
  changes to "Publish v<version>". (#1160)
- A file whose name is not valid UTF-8 is now named when it stops a publish, instead of the whole
  folder being reported as unreadable. (#1160)
- Extensions: a runaway extension call on the main thread (launcher calculator and units, snippet
  placeholders, Hammerspoon event-tap setup) now stops after a few milliseconds instead of freezing
  Prosper for up to half a second. Converter windows such as Base64 now convert in the background:
  typing stays responsive while a large paste converts, and the other pane fills in when the
  conversion finishes. (#1146)
- More of the Lua library now counts toward an extension's time budget: the utf8 functions,
  string.pack/unpack/packsize, string.format, upper/lower/reverse/byte/char, numbers read from text,
  and comparisons of long strings in equality tests and table keys. An extension that loops over
  them stops with an "execution budget exceeded" error instead of keeping Prosper busy. (#1166)
- Ordinary extension work with these functions (formatting, parsing numbers, walking UTF-8 text,
  packing data) runs as before. (#1166)
- Agent Sessions window: in Terminal mode, VoiceOver no longer reads the folder icon on the
  session's title line as an image named "Move". (#1120)
- Hammerspoon Compat: a timer's running() now asks Prosper whether the timer is scheduled, so it
  stays right after Prosper reloads the extension (it used to answer false for a timer started
  before the reload until that timer fired). On an older Prosper without that check, running() works
  as before. (#1165)
- Extensions: new `host.timer.scheduled(id)` tells an extension whether one of its own timers is
  scheduled. (#1165)
- Publishing an extension now refuses a folder that holds a named pipe, socket or device file,
  naming it, instead of failing later with "no longer a regular file". (#1168)
- Always allow now writes `auto_allow` into dch's own config file whenever the toggle changes and
  when Prosper starts. With dch 1.30.0 or newer (full build), dch answers permission prompts itself,
  and Prosper's island stops typing them. A value set by hand for `auto_allow` or `sidekick_pattern`
  in that file is replaced by Prosper's toggle and pattern. (#781)
- With an older dch or the lite build, Prosper writes `auto_allow = false` and keeps answering
  prompts itself, so the two never both answer the same prompt. Turning Always allow off writes
  `auto_allow = false` even when no dch is found. (#781)
- The Sidekicks pattern is copied into dch's config as `sidekick_pattern`, so dch's own session
  picker splits sessions the same way the island does. If dch would read the pattern differently
  (for example `\d`, `.` or brackets), or Sidekick tabs are off, the value is left empty. (#781)
- The rest of dch's config file is left as it was. Prosper keeps every other line, keeps the file's
  permissions, follows a symbolic link, and writes the new file atomically. If the file cannot be
  read or written, or is larger than 1 MiB, Prosper leaves it unchanged. (#781)
- Always allow now checks the session list again just before it types Yes. If Claude Code has left
  that session in the meantime, the prompt is shown instead of answered. (#781)
- Typing fast in a two-pane converter window (Base64 and extension converters) no longer queues one
  conversion per keystroke: while one conversion runs, only your newest text is converted next, so
  the answer for what you typed last arrives sooner. (#1170)
- Lua extensions: a script that unpacks a very large table, expands a very long argument list, or
  looks up a very long text key through a chain of fallback tables is now stopped by its execution
  budget as promptly as other heavy work. (#1173)
- Always allow no longer writes `auto_allow = true` to dch's config while a dch 1.29 session (or one
  whose version cannot be read) is running in Prosper's session folders. Those sessions would answer
  hook and ask prompts too. `false` is written until they are gone, then `true` follows. (#1172)
- When dch takes too long to report its config, the island now reads dch's config file itself to
  decide whether to stand down. A file that says `true`, or one it cannot read the way dch does,
  leaves the prompt to dch, so Prosper and dch never both answer it. (#1172)
- Sidekick patterns with bracket sets of letters, digits and `_` (for example `build-[0-9]+$`) now
  reach dch's own picker. Sets with ranges of one kind (`a-z`, `A-Z`, `0-9`) are included. (#1172)
- Settings now says "dch's picker cannot use it: no Sidekicks tab there" under a sidekick pattern
  that dch's own picker cannot use. (#1172)
- Typing a sidekick pattern in Settings writes dch's config once, a second after the last keystroke,
  instead of once per keystroke. (#1172)
- Prosper no longer rewrites a dch config that has a line over 1023 bytes. dch reads such a line in
  pieces, so a piece could set a key Prosper cannot see. (#1172)
- Text Viewer: opening or reloading a large file no longer freezes the app for seconds; only the
  part on screen is laid out, so the scroll bar of a large file is an estimate that settles as you
  scroll. Ordinary documents are laid out whole as before, with an exact scroll bar. (#1155)
- Text Viewer: a reload keeps the same line at the top of the window; a file that got shorter shows
  its new end, and an emptied file shows from the top. (#1155)
- Text Viewer: reloading a large Markdown document is fast again (1 MiB took about 2 s). (#1155)
- Text Viewer: Markdown documents now draw up to 8,000 links as links (was 2,000). (#1155)
- Coding agent on Qwen3.6 (and other thinking models): the model's opening think block no longer
  shows up as the answer or goes back into the conversation, and a tool call the model only sketches
  while thinking is no longer run. (#893)
- Coding agent: changing the agent model while a model is loading no longer opens the session under
  the other model's name. (#893)
- Open Agent Sessions now has a default shortcut, Shift-Option-S (while the Agent Island extension
  is on). A shortcut you set or cleared yourself is kept, and if you already use Shift-Option-S for
  another Prosper shortcut, an app or extension shortcut, or one of your key rules in Settings,
  yours keeps the key. Where Shift-Option-S types a character (Í on the U.S. layout), that
  character cannot be typed with it while the shortcut is active, as with Clipboard History on
  Shift-Option-A. Change it in Settings > Shortcuts. (#1177)
- The Marketplace publish list no longer closes when you scroll its extension far out of view in
  Settings; it still closes when publishing is no longer offered. (#1174)
- Installing an extension now refuses a download that holds a named pipe, socket or device, naming
  it, instead of installing something that could hang Prosper. (#1174)
- Always allow: when dch's config file holds a NUL byte and dch is slow to answer, Prosper now
  leaves the prompt to dch instead of possibly answering it as well. (#1179)
- Text Viewer: a link whose target name holds a right-to-left or other text-direction control
  character is shown as plain text, so its tooltip can no longer show a file name in a different
  order than it really has; an image is not drawn if a folder on its path is swapped for a link
  while it loads. (#1162)
- Agent Sessions window: when the session you are viewing ends, its conversation now stays on screen
  marked Ended (read only, nothing can be sent to it) until its History record arrives, then the
  History card takes its place; this now happens for every way a session ends, not only for Stop or
  Kill from the window. (#899)
- Muted (secondary) text on the tinted top of the sidebar in the Fern and Mint themes is a touch
  darker, so it now meets the 4.5:1 contrast minimum there. (#1129)
- ccpool: with "Start new Claude sessions through the pool" turned on in the ccpool settings, new
  sessions you start from Prosper (Agent Island's New session or the New session form) that run
  claude now go through the pool, and any Anthropic API key or auth token in their environment is
  left out. The New session form shows "via ccpool" next to the command when that applies.
  headroom, shells, other programs and sessions started in a terminal are unchanged. (#914, #1200)
- Text Viewer: Markdown files with a long line of spaces or tabs are no longer shown as source with
  "Nested too deeply"; a list line that opens two items ("1. - x") shows both markers; a table wider
  than 64 columns says why it is shown as plain rows. (#1163)
- Extensions: an extension that is trusted but not given System Access can no longer read, list,
  check, watch or search your SSH keys (~/.ssh), keychains (~/Library/Keychains), ~/.ccpool,
  ~/.config/mcpbridge, ~/.claude/settings.json, Prosper's own key files, and other common credential
  files (AWS, GnuPG, .netrc, Git, npm, GitHub CLI, gcloud, Kubernetes, Docker, Claude); to it they
  look like files that do not exist. The extensions guide lists every path. Bundled system
  extensions and extensions you grant System Access are unchanged, and the guide now says correctly
  that host.fs.read is available to trusted extensions. (#921)
- Text Viewer: a window on a file that is not there yet checks for it less and less often (up to
  once a minute) instead of every second; on a network or automounted volume it does not check for a
  file that was never there, and keeps checking for about two minutes after a watched file
  disappears. A missing file that turns out to be a folder is no longer watched, and invisible
  direction-control characters in a file's name are shown spelled out in the window title and
  header. (#1186)
- Open Agent Sessions' default shortcut (Shift-Option-S) now also steps aside for Hammerspoon Compat
  key rules and for a key mapping you just added in Settings, and its Settings row says it is off
  while a key rule uses the key. (#1189)
- Daylight theme: the terminal green used for agent replies, diff additions and status labels is
  slightly darker, so it reads clearly on the light backgrounds. (#1199)
- Agent Island Sidekicks: a session alias or title that ends in a Unicode line separator is no
  longer taken as ending with the pattern's "$", the same as in dch's own picker. (#1184)
- Account pool: quitting Prosper while the proxy is still starting no longer leaves its port held,
  and a limit reported for an account that was renamed or replaced mid-request now holds back that
  account, not the one that took its name. (#1190)
- Markdown files with a very large amount of markup (well over 100,000 emphasis marks, links, code
  spans, table cells or lines) now open at once as their source with the note "Too much markup:
  shown as source", instead of taking several seconds to draw. (#1187)
- Agent Sessions: the header of an open session no longer shows the folder path; hover the session
  name to see it (VoiceOver reads it too). (#1191)
- Fans: when one fan does not take a new speed from the slider, Prosper now hands every fan back to
  macOS and shows the speed it will restore, instead of leaving one fan at the new speed; a fan that
  rejects the speed after another took it is no longer reported as an overheat. (#1033)
- Text Viewer: Markdown with a great many bare links or e-mail addresses is shown as its source
  instead of stalling, a paragraph with over 10,000 styled pieces shows its rest as plain text with
  a note, and Markdown with lots of emphasis renders faster (#1211)
- Themes: in Blossom, Daylight, Fern, Lavender, Mint and Solar the green text of the "Open in
  terminal" and "New shell" buttons is a little darker, so it reads clearly on its tinted button
  fill (#1206)
- Agent Sessions: a Claude session row shows the model and effort of its last answer (for example
  "Opus 4.7 · high") in a small muted slot on its second line, where there is room beside what the
  row already shows; the slot keeps its size, so nothing shifts when the value arrives, and
  VoiceOver reads it with the row (#1203)
- Account pool: the "via ccpool" note in the New session form now updates as soon as you turn
  routing on or off or the proxy starts or stops, and a usage Refresh no longer puts its result on
  the wrong account when one is renamed or removed while it runs. (#1205)
- Agent Island's Sidekicks tab now also matches a session's Claude Code or Codex title when the
  session has an alias, as dch's own picker does; the Settings caption says "name, alias or session
  title". (#1210)
- Agent Sessions reopens on the session you were last reading (also after a relaunch, and after
  Agent Island is turned off and on) instead of jumping to the first session in the list. (#1217)
- Text Viewer: in Markdown, a picture inside a link (the usual badge form) shows its picture again
  when the image is a local file, with the link kept on it; a web image there shows "[image: name]"
  linked to the link's target instead of only its name. (#1213)
- Fans: when one fan doesn't take a speed set from the popup's Manual button or the phone's "Fans:
  Manual", Prosper now says so ("A fan didn’t take the new speed, so macOS runs every fan again")
  and hands every fan back to macOS, instead of blaming the overheat cut-off and saving the speed as
  pending. (#1215)
- Fans: a fan speed that isn't a real number (from a damaged saved setting or a bad sensor reading)
  is never sent to the fans or saved; that fan stays with macOS. (#1215)
- Account pool: Settings now says that resumed sessions are not routed through the pool; a proxy
  that stops on its own shows at once in Settings and in the New session form's "via ccpool" hint,
  and an already open New session form shows that hint as soon as the pool extension is turned on.
  (#1219)
- A Markdown link whose text starts with "![" but holds no image (for example [![x]](#top)) shows
  its text as a link again instead of "[image: ![x]]", and a picture inside a link now also draws in
  a file that starts with a byte-order mark or holds a NUL byte. (#1222)
- Agent Island: a session with a very long title no longer switches the Sidekicks pattern to plain-
  text matching for every session; the title is also sent to Prosper on iPhone, so a later iPhone
  build can sort sidekicks by it. (#1220)
- Coding agent: in a long session, sub-agents that start after earlier ones have finished (or after
  another conversation's sub-agents) now still get their approval card instead of being declined,
  and a stopped turn ending late no longer costs the next turn its sub-agent cards. (#1098)
- The coding agent's approval card now shows "Asked by a sub-agent of this session" as its own
  labelled line above the command, so the selectable command text holds only the command and keeps
  all its lines. (#1221)
- Agent Sessions: when the window opens on a session that is no longer running, the pane now says
  "<name> isn't running" with a Pick Another button, instead of the empty "Select a session" state.
  (#1195)
- Fans: a fan whose speed can't be read no longer crashes the Stats popup (it shows "no reading").
  Turning on Manual, from the popup or the phone, now says so and leaves every fan with macOS
  instead of pinning only some of them; if Manual was already on, the fans go back to Automatic. A
  damaged saved fan setting no longer pins some fans and not others. (#1223)
- Resume interrupted no longer counts sessions whose name dch will not start (a name that begins
  with "-" or is shaped like a session id); with only such sessions left the button is not shown, on
  the Mac and on the phone. A name shaped like a session id gets its own explanation, and a resume
  whose Claude is not running reads as not resumed, matching the "failed" count. (#950)
- Text viewer: a Screenshot button in the header copies one image of the whole document, all of the
  scroll and not only the visible part, to the clipboard as a PNG; a very long document is copied at
  1x, and past the image height limit its top part is copied and the notice names the lines
  included. (#1107)
- Agent Sessions: dragging the window by its top strip, or clicking the thin line beside the session
  list, no longer moves the arrow keys between the list and the session. (#1196)
- Managed config: a permission change you make to a managed file (chmod) is kept when Prosper
  applies, removes or repairs a piece, even if it lands while the write is in progress; and a
  managed block edited so that one byte is no longer valid text is shown as your edit instead of
  being taken as unchanged. (#1226)
- Fans: a Manual request that times out while manual fan control is already on now hands every fan
  back to macOS until your saved speed is applied again, instead of leaving one fan at the new
  speed; saved fan speeds that can no longer be read while Prosper holds the fans now turn manual
  off and hand the fans back; a garbage fan count from the SMC can no longer crash the fan helper.
  (#1225)
- A Claude Code settings.json (or another JSON file Prosper manages) that starts with a byte order
  mark is no longer refused as corrupt: Prosper edits it and keeps the mark where it is. The consent
  sheet says more exactly why it asks again and how many backups of a hand-edited file are kept
  (#1227)
- A session that ended on a signal now shows the whole command of the process that sent it in its
  end label (a path with spaces is no longer cut at the first space), shortened to 48 characters;
  the phone also gets the whole command in a new optional field (#937)
- Fans: choosing Automatic on the Mac or on the phone now wins over a Manual request that is still
  starting on the other one; a fan speed that lands after its request gave up is handed back to
  macOS; a Mac that reports a bogus fan count no longer retries the fan reset forever; a fan with no
  reading shows a dash instead of 0% (#1230)
- Text Viewer: a Markdown file that starts with two or more byte order marks is drawn like one that
  starts with one (its first line is a heading again, and a picture inside a link shows as a
  picture) (#1229)
- Managed config: a permission change you make to a config file right after Prosper writes it is no
  longer undone, and Prosper refuses to write when its own temporary file has been replaced by a
  link; the MCP and hooks files read a leading byte order mark the same way on every macOS version.
  (#1231)
- Fans: choosing Automatic (in the stats popup or from the phone) while a fan speed change from the
  slider is still being applied now hands every fan back to macOS; before, a fan could stay at the
  slider's speed while the popup said Automatic. A Manual request refused because a fan had no
  reading now also stops a Manual change still in flight from the other surface. (#1233)
- Agent Island settings have a Default model (type a model name or pick opus, sonnet or haiku): new
  Claude sessions that Prosper starts from the island, the New session window or the phone use it
  from their first turn, unless the command already names a model. Empty keeps Claude Code's own
  default; Restart and Resume keep each session's model. (#1228)
- Untrusting an extension, or resetting a built-in one, now releases everything it was holding (a
  keep-awake, timers, menu bar items, key rules, file watches), so for example resetting OpenLid
  during a timed session no longer keeps the Mac awake; a reset extension that is on starts again
  right away, as when it is switched off and on. (#1038)
- Text Viewer: a file with a line longer than 1,048,576 characters now opens without freezing the
  window: it is shown up to that point of the long line, and a note under the header says the rest
  of the file is not shown. (#1236)
- A config-change sheet that an extension stopped waiting for (after 5 minutes) now closes and lets
  the next one through, and asking twice for the same change (a double Uninstall) shows one sheet
  instead of two; a second request shares the first one's answer only when it would write exactly
  the same bytes, with the same file mode, to the same files. (#947)
- Fans: when the Prosper helper still running is from an older version, a refused Manual fan speed
  now says that the helper cannot tell Prosper why it refused. Prosper says so only after the helper
  has shown it is older. (#1208)
- Extensions: switching an extension off and on again, or resetting it, while one of its actions is
  still running no longer drops the keep-awake, key rules or menu bar item it set up again, and the
  old action can no longer leave a keep-awake held behind. (#1238)
- Text Viewer: a long line cut inside a run of flags no longer ends with half a flag, and a long
  note under the header stays on one line in a narrow window (hover it for the whole text). (#1180)
- Agent settings: the config consent sheet shows the extension on its own line, its button says what
  it does (Apply, Remove or Repair), and it no longer lists a backup for a file that does not exist
  yet. (#1235)
- Agent Island Default model: a command that resumes or continues an existing Claude conversation
  keeps the model it ran on instead of getting the Default model, and the Aliases menu in the
  setting follows the interface size. (#1237)
- Fans: when the Prosper helper refuses a Manual speed, Prosper now shows the helper's own reason
  instead of guessing it. When a fan did not take the speed or the temperature could not be read,
  the fans go back to macOS and the speed is not saved for later. (#1234)
- Fixed (data loss): when an extension changed one of your config files through managed config and
  that file existed but could not be read (its permissions, or a cloud file that was not
  downloaded), Prosper treated it as a new file and replaced it with no backup. Prosper now refuses
  the change and says the file exists but cannot be read; the file is left exactly as it is. The
  same holds for the file where Prosper records its managed changes. (#1240)
- An extension you switch off, untrust or reset can no longer start anything new from an action that
  was still running: no command, link, key press, settings change, notification or release of
  something the extension holds again. A reset now re-registers its shortcuts and themes right away.
  (#1238)
- File search: "Open in Prosper" on a file with no extension no longer does nothing when macOS
  disagrees about whether it is text; the viewer opens it and says so itself if it is not text.
  (#1164)
- Settings: when the Sidekick pattern holds regular-expression characters (a dot, brackets, a plus
  and so on), a line under the field now says how it is read, and a "Match this text exactly" button
  rewrites it to match just that text. Nothing changes until you press it. (#938)
- Remote Terminal: a phone's session list stream to this Mac now refuses kill and rename with "watch
  connections cannot kill or rename", as dch serve 1.66.0 does; kill and rename on their own
  connection work as before (#1178)
- Fan control: after the overheat cut-off hands the fans back to macOS, the background helper now
  stays running (up to 30 minutes) until the Mac has cooled below 80 °C, so reopening Prosper can no
  longer bring back a quieter-than-macOS manual fan speed while the Mac is still hot (#981)
- A command typed with a short resume or continue spelling inside a group (-rabc, -r=abc, -cn x,
  -cw, -cv, -cp) no longer gets the Default model added, so the conversation keeps its own model
  (#1237)
- Extensions can now repair a managed config block that was edited by hand after Prosper lost its
  record of it (you see the change and approve it first), and uninstalling an extension no longer
  leaves such a block in your file without a word: it tells you which block and what to do, unless
  you turn the extension off first (#1232)
- Manual fan control now gives the fans back to macOS for good when the helper's replies keep
  arriving too late three times in a row, instead of re-applying the speed and handing it back over
  and over (#1234)
- The "Match this text exactly" button in Settings now appears only when the escaped pattern still
  fits dch's 255-byte limit, so pressing it can no longer make dch silently lose the Sidekick split
  (#938)
- Switching themes no longer closes an open event in a pinned Calendar popup, and the model setup
  window's text now changes colour with the theme (#928)
- Agent Island: clicking an answer on a card while Always allow is still checking that session now
  says "Answer not sent: another job is running" instead of doing nothing, and switching Always
  allow off and on during its follow-up check no longer sends a stray Needs input for a prompt that
  was already answered (#927)
- Settings › Shortcuts no longer offers Open App, Run Shell Command or Quicklinks as runner targets
  while their extension is turned off; a shortcut you already saved on one keeps its row and says
  its extension is off. The Quicklinks and Quickdirs runner modes also stop listing once their
  extension is off (#985)
- Theme names and tint names from an extension now keep their emoji (families, country flags,
  keycaps) and are never cut in the middle of a character, while hidden and direction-changing
  characters are still removed; a theme's name read aloud by VoiceOver is cleaned the same way
  (#928)
- Menu bar popovers (Stats, Calendar, Mixer) on macOS 27 with a second display and Accessibility
  allowed for Prosper: clicking another icon of the same popover on the other display's menu bar
  now switches to it instead of only closing the open one; a click on any other Prosper icon still
  closes it (#1032)
- Choosing Automatic for the fans right after moving the fan slider no longer leaves the slider's
  speeds saved in the background (#1234)
- A theme name or label written with a no-break, thin or wide space now keeps the gap between its
  words ("Sky Blue" no longer reads "SkyBlue"); line breaks and invisible characters are still
  removed, and a label with one over-long character stops there (#928)
- Extensions: an extension is no longer installed when its id is not a plain single name or is the
  name or id of an extension built into Prosper; the install says why and changes nothing. A
  built-in extension is now recognised by its own id as well as its folder, and an installed
  extension can no longer take a built-in's place (#1246)
- Calendar: an event you have open in a pinned Calendar stays open when its calendar syncs and the
  event gets a new identifier (it closes, as before, if two events look the same) (#928)
- A theme or tint name with a long run of spaces now shows a single space, so the rest of the name
  is no longer pushed out of view (#928)
- Fans from iPhone: when a Manual speed cannot be set yet and is saved for later, the phone answered
  "applies when the Mac cools down", which was wrong after a short settle; it now says what the
  Mac's fan popup says: "Waiting for macOS to hand back the fans. Prosper sets 60% as soon as it
  can." (#1041)
- Agent island: a click that is refused because the session is busy, on a row that shows "Allowed
  automatically", now says why (for example "Restart not run: another job is running") instead of
  looking ignored (#927)
- Two extension menu bar icons whose ids differed only by a space, a slash, a colon or another
  unusual character (for example "a b" and "a_b") no longer share one saved menu bar position; icons
  with plain ids of up to 256 characters keep their saved position (#980)
- The sheet that asks before an extension changes your config now names the extension by its title,
  with its full id (wrapped, selectable) under it (#1235)
- When the Mac cannot load the model or finish an answer for the phone, the phone now gets a plain
  sentence instead of the Mac's internal error text; the Remote Terminal status in Settings says in
  plain words why Tailscale on the Mac is not connected (#988)
- When a rename from the phone fails, the phone gets a short sentence from Prosper instead of dch's
  raw output; the Remote Terminal status in Settings no longer shows raw error text for a listen or
  Tailscale check failure (#988)
- When an extension install is refused for an unsafe item, the message names that item without
  invisible or control characters (#1182)
- Outside names that Prosper cleans before showing them (a linked old vault's path in the ccpool
  settings, an item named in a refused extension install) now also keep at most two accent marks per
  letter, so they cannot draw over nearby lines (#1251)
- The Remote Terminal status in Settings no longer quotes Tailscale's own error output; a rename
  from the phone of a session that has just ended now says "no session" for a very long name or a
  session on another Mac too (#988)
- Remote Terminal: a phone request no longer waits for ever when dch, or a remote Mac it relays,
  writes a lot of error output; the error output is read alongside the answer and its first 4 KB is
  kept (#988)
- Remote Terminal: when the Tailscale whois check fails, the status line in Settings says to run
  tailscale whois with that address in Terminal to see why (#988)
- Agent Sessions: while you rename a session, the title, state and counts under the Rename field are
  hidden from VoiceOver by their own flag, not only by being transparent (#1239)
- The extension list in Settings and the Marketplace show an extension's name, version, description
  and author without invisible characters or piled-up accent marks, and a long name is cut to one
  line, so these texts cannot cover the UNTRUSTED badge or the lines around it (#1251)
- Extensions: installing one whose id differs only by letter case from an installed one is refused
  and no longer replaces it; an id that starts with a dot is refused too. Nothing on disk changes in
  either case (#1246)
- Installing or publishing an extension no longer hangs when tar prints a very large amount of error
  output; a tar failure now shows one plain message and tar's own details go to the log (#1182)
- Changing the agent model while the agent is answering no longer garbles that answer: it is read
  with the format of the model that is actually loaded (#1181)
- Remote Terminal: a phone's request to list, show, rename or close a session now gives up after 10
  seconds when dch on the Mac does not answer, so one stuck request no longer stalls every phone
  (#988)
- Marketplace: when packing a folder for publishing fails, the message now shows tar's first line; a
  failed unpack of a download shows one short sentence (#1182)
- Marketplace: an install or update is refused when the package's own files declare another version
  than the Marketplace lists; nothing is changed and the message names both versions (#1182)
- Local agent: a turn that ends while the model is still thinking now says so in one line instead of
  finishing with no answer (#1181)
- Config-change consent sheet: hidden characters in the lines, the path and the notes are shown as
  visible codes such as \u{202E}, and a line stays in its own row; what is written is unchanged
  (#1252)
- Marketplace: an install or update is refused whenever the package's files read as another version
  than its listing, however that version is written (#1182)
- Marketplace: publishing stops before anything is sent when extension.toml's version is not written
  like 1.2.0, and says so (#1182)
- Marketplace: a package whose files declare another id is explained in a plain sentence, and a
  folder that cannot be packed no longer reads as a failed download (#1182)
- Agent: codex is told the model that is actually loaded, also when the agent model changes in
  Settings while it loads or another model is already in memory (#1181)
- Phone chat: a thinking model's private reasoning is no longer shown; a reply that ends while still
  thinking shows a short notice instead (#1181)
- Agent: a very short answer from the local model ("Done.") now shows in the agent window instead of
  an empty reply (#1181)
- Agent Island: a permission prompt with a letter piled with accent marks can no longer draw over
  the command or the answer buttons: each card line stays in its row, the extra marks show as codes,
  and such a prompt can only be declined from the card (approve it in the terminal) (#1251)
- Agent: the phone chat and a run that reuses a started coding agent stay on the model that is
  loaded when the model setting changes in between (#1181)
- Remote Terminal: a phone's session list or screen read that needs a second dch call waits at most
  10 s in all, not 10 s per call (#988)
- Agent: with Nemotron, GLM, Kimi or MiniMax models an unusual character right after the thinking
  tag no longer shows the model's reasoning as its answer, and a long answer that starts with a
  blank line keeps its last characters in the agent window (#1181)
- Publishing an extension stops before any upload when its extension.toml changed after it was
  listed; a refused version with a character that cannot be shown says so (#1182)
- The config change sheet shows each line left to right in the order it is written, also when it
  starts with a Hebrew or Arabic word, and says when a line is cut (#1252)
- Agent: with Nemotron, GLM, Kimi or MiniMax models, a reply that starts with a thinking block now
  shows its answer on streamed requests without tools; a Qwen3-Coder function call written with a
  stray accent mark is read as a call, not shown as raw text (#1181)
- Extensions: a publish whose tar cannot start now says it could not pack the folder, not that it
  could not unpack a download (#1182)
- Account pool: a brief throttle from Anthropic (a 429 that is not spent quota) is now retried on
  the same account up to three times, after 1, 2 and 4 seconds or the server's Retry-After up to 10
  seconds, instead of failing at once; Claude Code's own quota checks still get their 429 at once
  (#1256)
- Coding agent: the status says "Using <model> (already loaded)" instead of "Loading <your pick>"
  when the run uses a model that was already loaded (#1181)
- Account pool: each Claude Code session now stays on one account and its subagents follow it, so
  its prompt cache is kept; a session moves only when its account runs out, is held or is removed
  (#1259)
- Agent Sessions: a session opened in Terminal mode now arrives with its recent history (up to 2,000
  lines) to scroll back through, and a session that draws nothing when it opens gets one refresh
  after a moment.
- Agent Sessions transcript: a tool that was still running when you pressed Load earlier now
  finishes properly when its result arrives, and an image sent without text starts its own turn
  instead of joining the previous one.
- Agent Sessions: in Terminal mode, Command-plus and Command-minus make the terminal's text bigger
  or smaller (8 to 32 points) and Command-0 puts it back to the usual size; this Mac remembers the
  size.
- Agent Sessions window, Focused view: the last turn's summary now keeps reading "Working" for as
  long as the session is working, instead of flipping to "N steps" between two tool calls.
- Extension updates: an update from the Marketplace that was refused for its content is not
  downloaded again until the Marketplace lists a new version (until the app restarts), and a
  published theme's preview is read only from the theme files you confirmed in the publish list.
- Account pool: a new conversation (or one that has to move) now goes to the account with the most
  five-hour headroom per live session, weighted by what each plan has been learned to hold, instead
  of always to the current account; conversations already pinned stay where they are.
- Account pool: a conversation that is still throttled after three retries now moves once to the
  least busy other account; if that account is busy too, it goes back to its own account (where its
  cache is) and the 429 is returned.
- The Check for Updates button no longer says "All extensions up to date" when an update was skipped
  or failed: it says how many could not be installed, and a manifest that could not be read (not the
  package's fault) is tried again at the next check.
- Account pool: the log line of a throttled (rate-limited, not out of quota) request now says its
  size, max_tokens, effort, speed, unusual response header names and how many tries it took and what
  came of it; the public part of the line never holds a header value, a model name, a body byte or a
  session id.
- Agent Sessions: a session that ended in the middle of a task no longer reads "Working" in its
  conversation, and a picture sent on its own now starts its own turn even when it is the first
  message of a page loaded with "Load earlier".
- Extensions that watch a folder now get one change event per short burst (with a "more" count past
  256 files) instead of a flood, stop getting events once they unwatch, and watch a folder once
  however its path is spelled.
- bullet: "Check for Updates" now says when it could not check an extension (offline or Marketplace
  unreachable) instead of "All extensions up to date."
- Account pool: importing from the Python ccpool now also keeps each session's account (its pins),
  alongside the account order and the accounts resting until a limit resets; an import file larger
  than 4 MiB is refused.
- Extensions: after host.fs.unwatch returns, a file-watch handler no longer runs even when its event
  was already on its way, and unwatching a path through a symlink that was retargeted since the
  watch now stops the watch instead of leaving it running.
- Account pool: when a moved conversation's new account fails to answer at all, the conversation
  goes back to the account it came from (where its cache is); the log line after throttled attempts
  now shows the reply's status and says "answered" instead of "served" for an error reply; importing
  from the Python ccpool no longer pushes out the pool's own conversation pins when the pin list is
  full.
- Names, permission prompts and config change lines from extensions and agents now keep up to three
  accent or vowel marks on each letter (so ordinary Hindi, Tibetan and pointed Hebrew words show
  whole and stay approvable), and on the config consent sheet any further mark is shown as a visible
  code right where it is written, in the original order.
- Account pool: an account whose sign-in token is rejected is no longer sent requests, even after a
  restart; it comes back when one of its replies succeeds, when you press Release or when you give
  it a new token. If every account's token is rejected, one is still tried so a fixed token is
  noticed.
- Agent Sessions: switching the transcript's detail level no longer jumps to the end; you stay on
  the turn you were reading (macOS 15 and later). Once older lines were dropped to save memory, the
  transcript says older history is in the terminal instead of loading a page above the gap.
- Settings > Account pool now says "token rejected since <day time>, not routed" for an account
  whose token was refused (401) and is left out of routing; Refresh now takes such an account out of
  routing on a 401 and puts it back when its token answers again (a 403 still only shows "token
  rejected"); and when every other account is only rate limited, the pool answers with the reset
  time instead of trying a rejected token.
- A popover that sets its own light or dark look now keeps it, closed popovers stop being re-themed,
  and switching a theme's colour variant no longer reloads its images.
- Links: when the URL Dispatcher fails or does not open a clicked link, Prosper now opens it in your
  saved fallback browser instead of losing it, and a developer build or fork of Prosper no longer
  sends links back to itself.
- Live Activity: when a Mac goes offline or stops reporting, a card that Apple failed to close is
  now closed again on the next minute (up to 3 tries), instead of staying on the lock screen.
- VoiceOver: the shortcut recorder in Settings and in the Assign Shortcut dialog now says which
  action it sets ("Open Runner, Command R"), announces "Waiting for keys" when you start recording
  and reads out the new shortcut once you press it, and no longer lets VoiceOver stop on the key
  symbols inside it.
- In the config-change approval sheet, numbers and punctuation right after a Hebrew or Arabic word
  now show in the order they will be written to the file, and a phrase of several Hebrew or Arabic
  words shows its words left to right in the order they are written.
- App Updates: if Prosper quits or is updated while "Upgrade Homebrew Packages" is running, the
  upgrade's result is now reported after the relaunch and its temporary folder is cleaned up,
  instead of being lost.
- Clipboard sync: a text copied on your iPhone is no longer dropped as a duplicate of a file or
  image on the Mac that happens to have the same bytes; each kind is kept as its own history entry.
- Agent settings: when mcp.json or hooks.json cannot be read (broken JSON, a wrong value type and
  the like), the MCP Servers and Hooks sections now say so, with the reason and a Reveal in Finder
  button, instead of silently not saving your changes to the file; the line goes away as soon as the
  file reads again. Importing an MCP server you already have no longer re-enables it or resets its
  approval mode and bearer token variable unless the imported file sets them.
- Clipboard history is no longer saved under a weak key or replaced when Prosper cannot read its
  device key: new clips are kept in memory until the key is readable again, the saved history is
  left untouched, and an unreadable key file is never overwritten.
- Always allow, island answers and the Agents window no longer type into a session while its Claude
  is suspended (Ctrl-Z) or in the background: the prompt is left to you and the row says "Claude is
  not in front in that session; nothing was typed" (needs dch 1.63.0 or later).
- An extension whose script or theme file is too large is now refused with a reason that names the
  file and the size limit, and an extension manifest that is refused now says whether it was too
  large or nested too deeply.
- Settings sync and the saved supporter sign-in no longer get sealed under a weak key when this
  Mac's device key cannot be read; they are skipped instead.
- Clear All while history is not being saved now also clears the saved history once it is readable
  again.
- After a restart in the middle of a Homebrew upgrade, Upgrade is available again at once instead of
  after two hours.
- Coding agent: when codex asks for approval on behalf of another thread (a fork, a review or a sub-
  agent this session did not start), the request is still declined, and the transcript now shows a
  "Declined N approval requests from another codex thread" notice for that turn.
- Coding agent: when codex quits unexpectedly, the error now ends with the last line codex printed
  to its error output (for example its panic message).
- Coding agent: after you press Stop, an approval codex still asks for the stopped turn is declined
  automatically instead of bringing the approval bar back.
- Coding agent: command output whose line ending or color code was split across two updates no
  longer shows a stray carriage return or escape code in the live tool card.
- The Agent Sessions window's sidebar has a "..." menu with Agent Island's list-wide actions: New
  session, Restart stale or all agents, Stop all, Kill all, Resume interrupted, Clear unpinned,
  Sort, Row details, Always allow permission prompts and Agent Island Settings. Its questions ("Kill
  2 sessions?") show at the top of the sidebar, the same ones the island asks.
- Settings > General > Clipboard: when macOS asks before Prosper reads other apps' copies, the line
  is now a link that opens the Paste from Other Apps setting, like the blocked warning.
- The clipboard panel now says so when history is not being saved (Prosper cannot read its device
  key), while your new clips stay listed until Prosper quits.
- Agent Sessions: a click on a session whose Claude is suspended or in the background no longer
  types into it when dch has no transcript for that session (island card and Agents window).
- Agent Sessions: sessions Prosper starts or restarts now tell programs the terminal draws 24-bit
  colour, so Claude Code colours match Ghostty. Sessions already running keep their colours until
  restarted (#1266)
- Agent Sessions: the New session form's Name field starts empty and stays empty when cleared; the
  automatic name shows as the placeholder and is still used when nothing is typed (#1265)
- Agent Sessions sidebar: the model and effort label ends at the same place on every row, stays
  through a short gap in what dch reports, and shows on a session that has been working since a new
  conversation began (#1267)
- Agent Sessions sidebar: a session's model and effort now show as two small badges at the end of
  the second line (the effort badge tinted by level, low to max), with the age after them; the
  Command-digit shortcut chip moved up to the end of the session name's line.
- The Sync pane now says when sync is paused because Prosper cannot read this Mac's device key,
  instead of showing LOCAL.
- Signing in on a Mac that cannot save the sign-in now says so ("Signed in for this session; the
  sign-in can't be saved on this Mac.") instead of reporting plain success.
- When the coding agent's backend exits, the error now ends with codex's last message as plain text
  (no colour codes or hidden direction characters, at most 200 characters).
- Pressing Stop while the coding agent is still waiting for its model no longer leaves codex waiting
  two minutes on that request: it is cancelled at once.
- AI models: a model whose download was interrupted now shows "Partly downloaded" with the space it
  uses, offers Resume and Delete, and a GGUF model file that is smaller or larger than expected no
  longer shows as downloaded.
- Turning on Always allow from the Agent Sessions menu now asks first (Turn on or Cancel); turning
  it off stays immediate.
- Prosper now follows the macOS Increase Contrast setting (System Settings > Accessibility >
  Display) without a restart: windows turn fully opaque, dividers and borders are drawn solid, and
  secondary text uses the full text colour, in your chosen theme. Some windows (the launcher, the
  agent island, the clipboard panel and a few popups) still draw part of their own chrome and follow
  in a later update.
- A truncated or partly copied local model file (inline autocomplete or agent GGUF) no longer shows
  as downloaded or loads: it is fetched again, and Resume never deletes a complete file. Inline
  models downloaded by earlier versions (before the files were pinned in v2.156.0) still count as
  downloaded.
- Plugins: a second Prosper (or a dev build) sharing the plugins folder no longer takes the plugin
  host's socket away from the first one, so the first app's plugins keep working.
- Agent Sessions: clicking a pull request chip on a session in the sidebar now opens that pull
  request.
- Agent Sessions: Command-Backspace in the sidebar asks to stop the selected session, or to remove a
  selected History entry; nothing happens until you confirm.
- Agent Island History: two ended runs of one name that ended in the same second now always show the
  same one as the row (it was whichever dch listed first).
- Sidekick tabs: one slow moment (a busy machine, memory pressure) no longer makes Prosper regroup
  your sidekick tab and say "Too slow on a session name" for a pattern that is fine; the pattern is
  searched once more before it is judged slow, and old slow moments are forgotten.
- Ships dch 1.74.0 (was 1.73.0). X-ray's reference answers start from the newest mentions, X-ray
  Search finds a subagent hand-back by the words of its report, and a revived session no longer
  passes Claude's MCP setting on to programs started in it later. (#1309)
- Increase Contrast now also reaches the launcher, the Clipboard panel, Settings and the stats
  popup: their dividers, borders and faint labels are drawn solid. While it is on, Transparency and
  Frost in Appearance are off, with a note saying why. The launcher and Clipboard dividers now use
  the theme's divider colour.
- The config-change sheet now warns, with a line per piece, when an extension's change will run a
  command (a hook or the status line), and its Apply button says how many, for example "Apply and
  allow 2 commands to run".
- Agent Sessions window: on the "Dvorak - QWERTY Command" layout, Option-Command on the Dvorak W key
  no longer closes the window (Option-Command-W still closes on Finnish and Norwegian Extended).
- Agent Sessions window: the status line under the session list now clears itself once its reason is
  gone: a "Controls needs dch ..." note when dch is ready, a "never started" note when that session
  shows up, and either one when the New session form opens.
- Agent Sessions window: when a new session ends at once, the "ended at once or never started"
  message now says how it ended, for example "(exit 127)".
- Agent island: Restart and Stop now refuse ("Restart not run: another job is running") while an
  answer or key sequence from the Agents window is still being typed into that session, a dch action
  that never stops printing is now cancelled after an hour, and when an Agents window answer finds
  its prompt already gone, the prompt that replaced it is checked again right away instead of
  waiting for its next output.
- An extension whose config change has a malformed hook or status line (not a plain command) is now
  refused before anything is written, so the Apply sheet can no longer hide a command.
- Agent Sessions window: two PR chips with the same number from different owners (for example
  acme/api#12 and fork/api#12) now each open their own pull request.
- Increase Contrast now also reaches the window-snap footprint, the layout palette and overlay, and
  the autocomplete suggestion and button: their edges turn opaque, the suggestion text gets darker
  but stays lighter than typed text, the palette backdrop turns solid, and the footprint drops its
  blur.
- Agent Island: a line of dashes inside a command, a description or a question no longer cuts the
  prompt card short; the card now shows the dialog's title, description and question start that it
  used to hide.
- While a session resumes under a new name (because its old name is still running), the new name's
  row is busy too: its Restart, Stop, Message and Kill wait until the resume finishes, on the island
  and from the phone.
- Increase Contrast now also reaches the Agent Island and the Agent Sessions window chrome.
- With Increase Contrast on, a custom theme's faint lines (dividers, card borders) now fall back to
  the main text colour when they would be hard to see on the theme's cards, and secondary text uses
  the main text colour; the launcher and clipboard vertical dividers now use the theme's line colour
  instead of the system grey, and the clipboard colour swatch border now uses the theme's line
  colour too.
- The phone's Restart and Stop, and Stop all / Restart all, now also wait while an Agents window
  answer is still being typed into that session: the phone gets a busy answer, Stop all skips that
  session and says so, and Restart all leaves its folder alone and says so.
- A session started with its own Claude config folder (CLAUDE_CONFIG_DIR) can now have its plan
  approved from the Agent Sessions window.
- With Increase Contrast, a custom theme's faint accent on buttons, search fields and borders falls
  back to a readable colour, and a theme whose own text is too faint on its cards falls back to
  black or white.
- Claude Account Pool: terminal sessions can start through the pool with the shipped ccpool-launch
  script (its path is shown in Settings), a ccpool-statusline script shows which account a Claude
  Code session is using, and extensions can read the pool's state with host.ccpool.status().
- Ships dch 1.96.0 (was 1.74.0). X-ray's full reference search keeps the newest mentions on very
  large transcripts, a quick search's time budget also ends a slow folder lookup, and the X-ray view
  keeps more of a prompt's title on narrow terminals when an agent's name is long; X-ray Refs also
  list the terms a session keeps coming back to. (#1327) Resume
  under a new name also renames the Claude session, a session started while the system is out of
  terminals retries for up to 2 s instead of failing at once, and a reference lookup in a light shell
  keeps the definition of an older block. X-ray can define a reference with a command of your own
  (dch's define_command setting), the X-ray view hides messages other agents sent to a session until
  you press a (and remembers that choice), and stopping and resuming a terminal job no longer leaves
  the X-ray view frozen. (#1348)
- Renaming an account in the account pool now renames its Keychain item too, so Keychain Access
  shows the new name. (#1326)
- Agent Island: Kill all during a Stop all or Restart all started from the phone now still writes
  the folder's tally once that job ends; a session killed while a Stop or Stop all ran is counted
  and reported as killed, on the island and in the phone's reply, instead of failed; a second
  refused Kill click no longer clears its note early; Stop all's question gives its skips in one
  short clause ("Skipped: 2 old dch, 1 "-" name."); and removing an old-dch History row no longer
  shows "pinned" for an older pinned copy of the same conversation. (#991)
- Agent Sessions lists the sessions on your other machines under "Other machines", each with its
  host, and opens them in Terminal mode. (#836)
- With Increase Contrast, primary text on a custom theme whose text is too faint now uses black or
  white, like secondary text. (#1325)
- Always allow no longer answers a permission prompt that hides or reorders characters (the card
  already offers only "No" there), stops answering two prompts that keep alternating within 30
  seconds, and no longer replaces a row's "Restart failed" text with "Allowed automatically"; the
  note also goes once the row waits on you again. (#1315)
- Island: a session killed while its own Stop or Restart was still running now reads "Killed"
  instead of "Stop failed". (#1328)
- Agent Sessions: History now lists the ended sessions of your other machines, each with its host,
  and Resume brings one back on that machine. (#1324)
- The Agent Sessions window no longer sends a message or Esc into a session while its Restart or
  Stop is running (also one started from the phone); answering the session's prompt still works,
  since the restart waits on it. (#1321)
- Agent Sessions no longer takes over a session on another machine by itself: showing the window,
  restoring a layout or the session coming back online now shows an Attach button, and opening it
  needs a click or Attach. (#1330)
- Command Runner: while an input method is composing text (for example Japanese or Chinese input),
  the up and down arrows now move through its candidates instead of moving the result rows (#996)
- Agent island: Resume interrupted now also counts a session named like a session id when another
  live session holds that name, since dch brings it back under a new name (for example name-2); the
  phone's history agrees (#992)
- Agent Sessions: Command-L in a transcript pane (or "Jump to Chapter..." in the pane's "..." menu)
  opens Jump to Chapter, a filterable list of the conversation's prompts that scrolls to the one you
  pick. (#1319)
- Agent island: a session and its sidekick (named like api and api-qa) now offer Stop both from a
  live row's menu and Resume both from History. The main starts first, and the sidekick starts only
  when its main came back. A larger group offers Stop all N and Resume all N. (#908)
- Agent Sessions transcript: a reader at the end of a transcript stays at the end when switching the
  view level or when new lines arrive, also at a reduced UI size (#1334)
- Agent Sessions: on the selected session row, the state text, counts, age, host and PR chips are
  easier to read on the Fern, Mint, Solar and Daylight themes, and so is a Needs input line on light
  themes (#1271)
- Agent Island: Resume no longer fails as "ambiguous" when another session is named after the record
  plus ".json" (for example "work" beside "work.json"); a Resume interrupted skip lands on the right
  History row when the session name contains " (record "; and the Resume interrupted count updates
  when a session ends while the island's History tab is open. (#1320)
- Agent Sessions: New session can start a session on another Mac running dch serve, in a folder you
  pick from that Mac's recent folders or type as a full path. (#1323)
- Agent Island: hovering the end text of a History session that was ended by a signal shows the
  whole command that sent it, not only the first 48 characters. (#1332)
- Agent Island Settings: a new Pairs field sets the name suffix that makes two sessions a pair for
  Stop both and Resume both (default -qa); leave it empty to turn pairs off. (#1338)
- Agent Sessions: "Diagnostics..." in the sidebar menu shows the Prosper, dch and Claude Code
  versions, the tested range, tier counts and the last parse errors for a bug report, with Copy.
  (#923)
- Agent Island: Pin, Unpin and Remove of a History row (on the Mac and from the phone) no longer
  fail as "ambiguous" when another session is named after the record plus ".json", and a Resume of
  such a record that finds no history now shows that on the record's own row. (#1340)
- Agent Sessions: a thin chapters rail along a transcript's left edge marks each prompt; hover shows
  its title and a click jumps there (the rail is for the pointer: Command-L lists the same chapters
  for the keyboard and VoiceOver). (#1318)
- Agent Island History: the X now says when a pinned older run of the same session stays (for
  example "Remove from History (1 pinned older record stays)"), the resume-without-message button
  has its own skip icon instead of a second play triangle, and removing a session beside one named
  "<name>.json" no longer reports a false failure. (#1069)
- Agent Sessions: a session with sidekicks (Settings › Agent Island › Pairs) offers Stop both and
  Resume both, or Stop all N and Resume all N for a larger group, in its row and History menus. A
  pairs suffix now needs at least one letter. (#909)
- Agent Sessions and Agent Island: Kill is now End (with the door symbol), and every item in the
  session menus has a symbol. (#1358)
- Agent Sessions: a confirm question and its buttons sit on one line, the buttons right after the
  question; on a narrow pane they move under it, lined up with its start. (#1361)
- Agent Sessions: a session row shows the model and effort badges on its first line, the age right
  under them, and the ⌘ shortcut to the right of both lines; a long session name is shortened (down
  to about 8 characters and "…") before a badge gives way, and the effort badge is the last to go.
  (#1345)
- Agent Sessions: a session that is running again no longer also shows as an ended record under
  History (in the window, the island and the phone); the record comes back with its pin when the
  session ends. (#1364)
- Agent Sessions and Agent Island: History lists pinned sessions first, then the rest, each A to Z
  by name, as dch does. (#1347)
- Agent Sessions: the subagents count on a session row has an outline, so a session with subagents
  stands out from its PR counts. (#1360)
- Agent Sessions: under Other machines, a session that is running again no longer also shows as an
  ended record in that host's History. (#1366)
- Agent Sessions: a Go menu after Edit lists the window's keyboard shortcuts (previous and next
  session, jump to session 1 to 9, Terminal or Transcript, jump to chapter, find, text size, new
  session, and more) while the window is in front; choosing an item does what its shortcut does.
  (#1359)
- Agent Sessions: X-ray reads a session's task list from dch 1.78.0 (no UI yet). (#1349)
- Agent Sessions: X-ray also reads the memories and instruction files a session has in force (no UI
  yet). (#1350)
- Agent Sessions: History's Remove says when a pinned older record of the same name stays, as Agent
  Island does. (#1344)
- Agent Sessions: Shift-Cmd-X (or X-Ray… in a pane's menu) opens X-ray with a Tasks tab: the
  session's task list in groups, with a filter and a card per task (dch 1.78.0 or later). (#1351)
- Settings > Agent Island: the Pairs suffix refusal now says it needs at least one letter, and New
  session gains a Sidekick prompt field for the sidekick's first message (used once the New session
  form can start a sidekick). (#907)
- Agent Sessions: the model and effort badges show on long-running sessions with very large
  transcripts, and no longer vanish while the same Claude session runs. (#1372)
- Agent Island's session rows now match Agent Sessions: the same state mark, state word, outlined
  agents count, merged and open counts, model and effort badges, and tighter, even spacing, with the
  PR name chips and their links kept below. (#1371)
- Agent Island follows the selected theme: its History rows, prompt cards and message field use the
  theme's colours, and the shown tab takes the theme's accent where it reads on the black notch,
  which stays black. (#1375)
- In the Agent Sessions terminal, Cmd-Backspace deletes the line, and Cmd-Left/Right and Option-
  Left/Right move to the line start/end and by word, as in Ghostty. (#1376)
- The Agent Sessions sidebar no longer shows a session's old name or state after it moves between
  groups (Needs you, Sessions, Sidekicks); reopening the window is no longer needed. (#1373)
- The X-ray Tasks tab refreshes itself while you watch it: every 5 seconds for a local session, 15
  for a remote one, and never while hidden. A host that stops answering keeps its tasks on screen
  with a "host unreachable" note. (#1368)
- Settings > Agent Island > Agent Sessions has a Window style (Standard, No title bar or Borderless)
  and, for Borderless, Rounded corners (turn it off for square corners that fill a full-screen
  window edge to edge); in every style you can drag the window by the empty parts of the sidebar's
  title row and the session header, and double-click there to zoom it. (#1378)
- X-ray has a Memory tab (the memories and instruction files in force for the session), and a task
  or memory opens the prompt that changed it. (#1352)
- Agent Sessions: the sidebar can now be Full, a narrow Mini rail (each session's state, number and
  a needs-you dot; hover for the name), or Hidden, where it slides in when you point at the window's
  left edge and Control-Command-S keeps it open. Choose in Settings › Agent Island › Agent Sessions
  or the Go menu. (#1379)
- X-ray's Memory tab now refreshes every 30 seconds while you watch it, switching to Memory while
  another read is running no longer skips its refresh, empty task groups are no longer shown, and
  clicking a task whose prompt was loading when the transcript changed now opens the task's card
  instead of doing nothing. (#1381)
- X-ray's Memory tab now says "host unreachable" when a session's machine stops answering, and
  clears it when the machine answers again. (#1353)
- The New session form in the Agent Sessions window has a Sidekick box, which also starts a QA
  session named after yours, and an optional Prompt you can type there, which the new session gets
  as its first message. Command-Return starts it. (#1370)
- X-ray has Prompts and Responses tabs for a conversation shown as a transcript; automatic prompts
  are hidden until you show them, and messages from other agent sessions are marked with their
  sender and can be hidden. (#1354)
- On a session on another Mac, the Todos chip opens X-ray's Tasks tab; when that Mac has no task
  list it says "No task list on that host". (#1388)
- X-ray's Prompts and Responses tabs also work for a session in Terminal mode and for a session on
  another Mac. (#1389)
- X-ray has a Search tab: search a session's transcript, on this Mac or another. (#1355)
- The New session form can add a session to a group already running: pick the group and Main or
  Sidekick, and the form fills in the group's folder, the command its members run and the next free
  name (for example "sec-2"); a new sidekick gets the sidekick prompt naming its main. (#1214)
- Agent Island: when a sidekick pattern is too slow to try even on empty text, Settings now says
  "Too slow as a regex: matched as text" instead of naming a session that was never searched. (#995)
- Agent Sessions shows a group of sessions (a main and its sidekicks) as one row in the sidebar,
  each session on its own line. (#1342)
- Agent Sessions: in Mini mode the arrows and Command-1...9 reach rows in folded sections, and a
  slid-out sidebar no longer takes the arrow keys or Command-Backspace. (#1383)
- The island's New session menu has "New session…", which opens the form in the Agent Sessions
  window. (#910)
- Updating or reinstalling an extension now stops the old version first (its timers, menu bar items,
  key rules, file watches and keep-awake holds are released) and starts the new version's launch
  code, instead of leaving the old version running until the app restarts. (#1241)
- Managed config: if Prosper's temporary file or the folder of the file being changed is swapped out
  mid-write, the write now stops with a clear error ("open temp failed", "check temp failed", "open
  directory failed") and leaves your file as it was, instead of failing with a misleading chmod
  error or replacing the file with the swapped-in one. (#1243)
- Agent Sessions: X-ray Refs tab; a ref opens its context: definition, mentions across sessions,
  matching tasks and memories, with Open, Copy and Search. (#1417)
- An extension whose manifest Prosper refuses (too large, nested too deep, or unreadable) now shows
  in Settings > Extensions as a "Not loaded" row with the reason, and the Marketplace shows that
  same plain sentence instead of the parser's raw error text. (#984)
- Agent Sessions: the "ended at once or never started" note no longer shows for a session that did
  start (it listed late, ran while the window was on another Space, or Agent Island was turned off
  and on), and a session that shows up late is selected instead of leaving a second Start that would
  duplicate it; the island's "Choose folder..." panel now says Start, since choosing a folder there
  starts the session. (#1096)
- Agent Sessions: when a quick shell (Shift-Command-N) never shows up, the note no longer says
  "check the command", since no command was typed. (#1096)
- Uninstalling an extension whose block in your config file has broken Prosper markers no longer
  gets stuck: a sheet first says the file stays exactly as it is and Prosper only forgets the block,
  and nothing changes if you cancel. (#1244)
- Installing, updating or resetting an extension no longer deletes the installed copy when the new
  copy fails: the old version stays in place and keeps working, and a half-finished copy left by a
  crash is ignored. (#1430)
- Agent Sessions and the island now say "Not delivered: the session is not reading input" when you
  answer a prompt and dch reports that the session dropped the keystroke or typed text because its
  program is not reading input. (#1171)
- Reveal in Finder for a folder Prosper could not load now says which folder it belongs to when read
  by VoiceOver. (#1433)
- VoiceOver no longer reads "go down" after "Recent folders" on the New session form's folder menu
  button; the chevron looks the same. (#1429)
- The config-change consent sheet now names the asking extension as Extension "<its name>" with its
  id underneath, so an extension titled "Prosper" or "macOS" can no longer look like Prosper or the
  system asking. (#1245)
- Settings has a page for each installed Agent Kit: its status, requirements, pieces, settings and
  overrides, and you choose which pieces and tools to take. (#1425)
- Agent Sessions: a new session that shows up in the list only after the New session form said it
  never started no longer closes the form or takes the keys when you have edited the form since; the
  form keeps your edits and says the session started after all. Reopening the form also forgets that
  earlier start. (#1434)
- X-ray Search and ref cards no longer put your search text on the dch command line for a local
  session, so other users on the Mac cannot see it in the process list. (#1410)
- The consent sheet title now shows any quote mark inside an extension name as an apostrophe, so a
  name can no longer break out of the quoting. (#1437)
- An extension no longer disappears if Prosper quits in the middle of installing or updating it: the
  previous copy is put back on the next start, leftover install folders are cleaned up after a day,
  and built-in extensions now update the same safe way. (#1435)
- A kit turned off in Extensions no longer keeps its tools on the PATH of new sessions, and a kit's
  Settings tab and search entry now show its title cleaned and capped like the kit pane does.
  (#1438)
- Managed config writes now also work in a folder you can enter but not list (for example mode
  0300), and a write is refused if the folder Prosper holds open is no longer the folder at that
  path. (#1431)
- Always allow now notices a session that starts in the socket folder your Agent Island view does
  not show (Mac-only or Remote-only) and updates dch's config right away, and a stray NUL byte in
  dch's config is cut from its line when Prosper rewrites the file, so it no longer keeps the island
  from answering. (#1185)
- The island no longer keeps showing "Not delivered" on a session after a later answer went through
  or after it moved on from needing input, and a dropped answer's card comes back. (#1436)
- The consent sheet title now also shows the fullwidth quotation mark and the CJK double prime
  quotes (U+301D, U+301E, U+301F) in an extension name as an apostrophe, so they cannot close the
  quoting. (#1441)
- An extension that declares a Settings section with the id "kit" no longer gets a second tab with
  the same id as its kit pane: that section is ignored (logged), and the rest of the extension
  loads. (#1440)
- X-ray: with dch 1.84.0, a session name containing a colon now also sends search and reference text
  on stdin, so it stays out of the process list. (#1442)
- X-ray sends search and ref text on stdin only when the probed dch is 1.84.0 or later; an older or
  not yet probed dch gets the text in argv, so a bundle without its own dch and an older installed
  dch no longer search for "-". (#1443)
- Settings, Agent island: the Command and Default model fields keep the right height after you
  change the UI scale (before, a field could keep the previous scale's height until something
  measured it again). (#1250)
- Agent Sessions controls (Restart, Stop, End, the terminal and +) keep working after you install a
  newer dch than the one Prosper ships: Prosper now also finds dch in ~/.local/bin and on your login
  PATH, and picks it up as soon as a session starts on the newer version. (#1460)
- Agent Sessions: in Slide mode the sidebar now stays open while its own menus, submenus (such as
  Row details) or the Diagnostics popover are open, and slides away after they close only if the
  pointer has left it. (#1461)
- Agent Sessions transcript: sessions on Claude Code up to 2.1.326 no longer show the "Newer Claude
  Code: some details may show simplified" note. (#1464)
- Agent Sessions: the sidebar "..." menu's submenus, such as Row details, now stay open and
  highlighted while the session list updates, instead of closing about every second. (#1466)
- Agent Sessions controls only use a dch that you or the system own and that other users cannot
  change, so a dch dropped into a shared folder on your PATH can never drive Restart, Stop or End.
  (#1460)
- Agent Sessions terminal: trackpad scrolling moves twice as far per swipe, as in Ghostty (mouse
  wheels unchanged). (#1465)
- Agent Sessions: the header count reads like "6/17 active · 🤖 9" (sessions working or needing
  input, of all, and the total sub-agents); hover it, or use VoiceOver, for the full split; a narrow
  header drops the word "active". (#1467)
- Settings > Agent Island > New session has a Default effort menu under Default model: new Claude
  sessions (and their sidekick, and sessions started from the phone) start with that effort unless
  the command already sets one; "Claude Code picks" leaves it to Claude Code, and Restart and Resume
  keep what the session had. (#1454)
- Settings > Agent Island > Agent Sessions: a new "Terminal colours" choice keeps Prosper's colours
  (the default) or uses "My Ghostty theme", which takes only the colour settings from your own
  Ghostty config and from the theme it names (looked up in your Ghostty themes folder, then in
  Ghostty.app; a light:/dark: theme follows Prosper's own light or dark theme); Prosper's own keys
  and clipboard rules stay as they are. (#1456)
- Settings > Appearance > Theme rows now line up: the selected row's highlight leaves room around
  its colour swatch, every row's tint dots end at the same place on the right, and the checkmark has
  its own spot on every row, so nothing shifts when you pick a theme. (#1462)
- Agent Sessions and Agent Island: PR chips are now amber on a dark amber wash, like the "Needs
  input" badge, so they stand out; on a selected or hovered row their text stays the theme's main
  text colour. (#1451)
- A quick shell that dch refuses to start no longer leaves "New session failed" on the Agent
  Sessions window until your next action: the line goes when you open the New session form or a
  session of that name appears; and an odd "exit ..." end in the "ended at once or never started"
  line now reads in words like every other end. (#1313)
- The X-ray window opens on the tab you used last, and on Prompts the first time, instead of always
  opening on Tasks. (#1463)
- Agent Sessions: a session's end text from dch (exit, signal or any other wording) now shows
  without control or direction characters and is cut when very long, in the form status, the dir
  line and the History rows. (#1313)
- Agent Sessions and Agent Island: on light themes the amber of a session's "Needs input" badge and
  of its PR chips is now a darker amber, so the text is readable (dark themes are unchanged).
  (#1451)
- Agent Island has its own colours again by default (white on the black notch, as before it followed
  the theme); turn on Settings > Agent Island > Look > Follow theme to draw its History rows, prompt
  cards and message field in your theme's colours. (#1452)
- Clicking a prompt or a response in X-ray in Terminal mode opens it in a card with the prompt
  and its response, and "Read the prompt" on a memory card opens that prompt's card instead of doing
  nothing. (#1472)
- The New session form sits in the middle of the pane (it still starts at the top and scrolls when
  the window is short). (#1479)
- Cmd-click a file path (absolute, ~/ or file://) in an agent session opens it in Prosper's Text
  Viewer; other files and apps never open. (#1480)
- X-ray opens instantly for a session you already looked at, and its Prompts, Responses and Refs
  stay live without polling. (#1475)
- Agent Sessions: rows 10 to 18 in the sidebar now show Option-Command-1 to 9 and jump on those keys
  (after Command-1 to 9). The Option-Command-1/2/3 shortcuts for the transcript's
  Focused/Default/Verbose view are gone. The sidebar is a little wider to fit the new chips, so
  session names keep their room. (#1470)
- The ccpool status line now also names the pool account for a session running behind headroom.
  (#1485)
- X-ray: a prompt's card now shows the whole prompt and the whole final answer, read from dch; long
  text says where it was cut, and the card says why when the chapter can no longer be read. (#1472)
- Cmd-click on a relative file path in a local agent session now opens it too, resolved against the
  session's folder; a remote session's paths never open. (#1480)
- Agent Sessions now opens borderless with square corners by default; Settings > Agent Sessions
  changes it back. (#1478)
- Agent Kits can ship agent files (named workers): Prosper installs them byte for byte into
  ~/.claude/agents, never overwrites an agent file you already have, and on Remove deletes only the
  ones it wrote and you did not edit. (#920)
- X-ray's Tasks and Memory tabs now update live from the same dch stream as Prompts and Responses,
  with no polling (needs dch 1.91.0 or newer; older hosts keep the periodic refresh). (#1475)
- Agent Island: with Follow theme off (the default), the live session rows are dark as well, white
  text on the black notch like the History rows, on every theme; the Agent Sessions window is
  unchanged. (#1452)
- Agent Sessions can split: Go > Split Right (⌘D) and Split Down (⇧⌘D) show local sessions side by
  side, each in its own live terminal. (#1477)
- Settings > Account pool shows usage charts: utilisation per account, tokens by kind, cache hit
  rate, top sessions and time to finish, over the last 24 hours, 7 days or 14 days. (#1484)
- X-ray chapter cards show where dch cut the middle of a long prompt or answer, with dch 1.93.0 or
  newer. (#1487)
- The sub-agent count shows a robot instead of the people icon, in Agent Sessions and Agent Island.
  (#1453)
- X-ray Refs list terms, identifiers and backticked words from the conversation, with where they
  were first mentioned (dch 1.93.0 or newer). (#1489)
- Resuming a session now routes it through the account pool, as a new session is (Resume interrupted
  still is not), even when your shell startup files set ANTHROPIC_BASE_URL or an API key. (#1219,
  #1499)
- Agent Island > Row details now has a toggle for every part of a session row: model, effort, state,
  agents, merged, open PRs, age and the Command 1-9 shortcut chip; model and effort show only where
  they differ from your Default model and effort. (#1455)
- Agent Sessions panes are terminals only: the Transcript mode and its Terminal | Transcript toggle
  are gone, Command-T and Command-L do nothing in a terminal pane, and X-ray reads every tab from
  dch, so a Prompts or Responses row opens its card. A first message that could not be sent now
  shows over the session's terminal with Copy, Send (pastes it without pressing Return) and
  Dismiss. (#1471)
- Agent Sessions: the Mini sidebar now shows each session's name (its first 8 characters) beside the
  status dot, with the Command number as a small superscript, and hovering a row shows its full name
  after a moment. (#1457)
- Agent Sessions: the slide-in sidebar now opens when you rest the pointer anywhere in the left half
  of where the sidebar would be (not just the window's very edge), stays open while the pointer is
  over it, and waits 1.5 seconds after you move away before it slides out. (#1458)
- The small Command number in the Mini sidebar is readable on every theme. (#1505)
- A session row's detail line (state, counts, age) now follows the UI size: at a smaller size the
  row is no longer held 14 pt tall by an empty age slot. (#1500)

## v2.174.0

- Ships dch 1.39.0 (was 1.28.6). A Claude Code plan waiting for approval now reads as
  waiting for you instead of working or idle. dch now has a config file (`dch --config`) with its own
  auto-allow for permission prompts, off unless you turn it on; it never answers a prompt
  raised by your hooks or "ask" rules, however long the rule. When it is on, Prosper's
  Always allow stands down for those sessions (#792). `dch --ls-json` also reports each
  session's Claude Code session id and transcript path, for the agent window to come.
  A dch attach whose terminal closes while output is still unread no longer hangs on exit, and
  attaching no longer drops output the session had not shown yet.
  Codex sessions started by dch get their own Codex app server when your Codex supports it,
  so agent peers can talk to them. A new dch setting, `detach_key`, picks what `Ctrl-\` does
  in an attached terminal, and the `dch -l` picker has a new look, a "/" filter, Claude session names on
  History rows, and reopens where you left it. When one session is attached in two terminals, the
  pane you focus sets its size (`focus_resize = false` turns that off). dch can now serve its
  sessions to the Prosper iPhone app from a Linux or Mac machine without Prosper
  (`dch serve`, off unless you run it; it tells a device it refuses why), and attach to sessions on your other Macs and dch
  hosts over Tailscale (`dch -a host:name`, `dch --ls --remote`).
- Always allow now checks a prompt that replaces one it left to you while the session is
  still waiting, such as the next of several queued subagent prompts. The prompt left to
  you is never answered. (#791)
- A prompt you answer yourself while Always allow is still confirming its own answer to the
  one before stays yours: Always allow no longer types "1" after your choice. (#794)
- New Agent Sessions window: every coding agent session in one place. Sessions waiting for
  you are on top, then the Agent Island groups and recent history. Selecting one shows its
  Claude Code conversation beside the list: messages, tool calls, diffs and subagents.
  "Open in terminal" (or Return) jumps to the session. Open it from the button next
  to the session count in the Agent Island header, or "Agent Sessions…" in the menu bar menu.
  It adds no polling of its own and reads nothing while closed or hidden; when it cannot show a
  session reliably, it says why and offers "Open in terminal". The island header no longer
  shows an idle count, so the counts that need you stay clear of the notch. (#797)
- You can now talk to a session from the Agent Sessions window, without opening its terminal.
  Type a message when Claude is idle (Return sends, Shift-Return adds a line), or interrupt it
  while it works. Permission prompts and Claude's questions get buttons, including
  multiple-choice questions, questions with previews, and a typed answer of your own. Every
  key that answers a prompt is checked against a fresh read of the screen first, and a
  question is checked against the conversation. Anything Prosper cannot read or confirm says
  why and offers "Open in terminal". An answer from the window counts as your own click, so
  Always allow never types over it. (#798)
- A typed answer of your own (the "Type something." choice) now works from the Agent Sessions
  window, and the Agent Island card reads a question again while that choice is selected. In
  v2.174.0-beta.2 Prosper did not recognize the longer hint line Claude Code shows then, so a
  typed answer stopped at "Couldn't confirm" or the prompt showed as unreadable. "Type
  something." itself is refused as an answer. (#805, #810)
- Remote Terminal hosts now tell the phone which server they run (Prosper or dch), the host's
  macOS version, its name and the protocol version, so the phone can label a host and later
  work with dch-only hosts such as a Linux machine. The protocol is written down in
  `docs/protocol/remote-frames.md`, with sample frames any server can be checked against. (#776)
- A new session started from your iPhone with a command that begins with "-" now runs that
  command. Before, dch read it as its own options, so `-kl` would have closed every session.
  The protocol notes now cover what a `dch serve` host refuses and how big a request may be.
  (#803)
- Remote Terminal now lets in only your own Tailscale devices. Before, any device on your
  tailnet could connect, including devices shared into it. Prosper asks Tailscale who each
  device belongs to before reading anything from it; other people's devices, tagged devices
  and devices Tailscale doesn't know are refused. If Tailscale on this Mac isn't answering,
  devices are refused too, unless you turn on "Allow when Tailscale isn't answering" in
  Settings, which lets any device that can reach this Mac in while Tailscale isn't answering.
  Remote Terminal's settings now say why a device was refused, and when port 8771 is taken
  (say by `dch serve`) or this Mac has no Tailscale address. (#777, #812)
- Renaming a session from your iPhone now reports when dch refuses it (say the session has just
  ended), instead of answering that it worked; a very long name is shortened in that message.
  (#811, #815)
- With Always allow on, clicking an island card whose prompt was already gone now lets Always
  allow check the prompt that replaced it, instead of leaving that one waiting for you until
  Claude Code printed again. Prompts from hooks or ask rules are still left to you. (#795)
- You can now approve Claude's plan from the Agent Sessions window: "Yes, auto-accept edits",
  "Yes, manually approve edits" or "Yes, and use auto mode". They show only when Claude Code
  names the plan file under the plan (it does once it finds an editor), the plan on screen
  matches that file, and every choice is one Prosper knows by name; otherwise the window says
  why and offers "Open in terminal". Clearing the context and bypassing permissions stay in
  the terminal. Multiple-choice questions also take a typed answer of your own with Submit,
  and "Chat about this" works from the window. Always allow never answers a plan. (#802)
- The Agent Sessions window's message box and Interrupt no longer act when the screen shows a
  prompt dch hasn't reported as one: a typed "1" could pick a row there, and Esc would answer
  it "No". The window says Claude is showing a prompt and offers "Open in terminal". (#820)
- Approving a plan from the Agent Sessions window reads the plan file again right before the
  key and sends nothing if it changed since the window showed it; the plan is also compared
  with more of its punctuation. (#824)
- The Agent Island no longer answers a plan approval; its card says to use the Agent Sessions
  window or the terminal. "Chat about this" is off on the card, and no answer is sent while the
  terminal's highlighted row is a text field (a question's "Other" or the plan's feedback row),
  where Claude Code would type the digit instead of answering. (#818, #823)
- Agent Sessions window: choose how much of a conversation you see. Default (the new standard)
  shows each tool step as one line you can click open, hides thinking, keeps the last 3 steps of
  a subagent, and shows Claude's task list as a small "Todos 3/7" chip you can click open. The
  list comes from Claude Code's own task files, so it is whole even when only the end of a long
  conversation is loaded; when those files are not there, the chip counts only once the whole
  conversation is loaded and otherwise reads "Todos" without a count. The opened list starts
  with the tasks still open. Focused shows only your prompt, a one-line count of the tool steps
  (with any errors) and Claude's reply. Verbose shows everything, expanded. Switch in the window
  header or with Option-Command-1, 2 and 3. (#821)
- Agent Sessions window: the Sessions, Sidekicks and History headers fold and unfold (click
  them, or Left and Right on the selected row), remembered per Mac. Send and Interrupt share one
  fixed column, so the message box no longer changes width when Claude starts or stops working,
  and state, age and History status changes no longer move what sits next to them. Text you
  pasted into Claude Code shows without its pasted_content tags. (#828)
- A click on a question whose top has scrolled off the terminal, or whose Other text reads
  "Chat about this", no longer types the click's digit into the Other field: with the terminal's
  highlighted row on Other, nothing is sent. An approve
  click in the Agent Sessions window after the plan left the conversation now says so instead
  of doing nothing. (#825, #826)

## v2.173.0

- **Sidekick pattern syncs with Prosper on iPhone.** Set it on the Mac or the phone and
  both use it: the newer edit wins. The phone side arrives in a Prosper iPhone update;
  until then each keeps its own. (#760)
- **Keep-awake costs less.** While a remote session keeps the Mac awake, the helper only
  runs `pmset` when the setting actually changes, instead of every 10 s. Prosper refreshes
  the hold every 30 s once it is confirmed. The Mac still sleeps within 2 minutes if
  Prosper quits. Idle phone connections are probed every 2 minutes instead of every 30 s.
  Remote wake on a charger checks every 60 s, then less often after long quiet stretches
  of sleep, but never less often than on battery (5 min, or your battery setting if
  shorter). Using the Mac resets it. (#767)
- **Agent Island row details are simpler.** Tasks done, In progress, Queued and Session
  name are gone from Settings and from the session and History rows. Agents, Open PRs
  and Merged stay. Their saved settings are cleared once. (#762)
- **The iPhone Live Activity wakes the phone less.**
  - Blocked and "needs you" still arrive within 2 s, and so does the card's start.
  - Working/idle changes are batched over 25 s.
  - A change in the subagent count alone no longer pushes; the count rides along with
    the next update.
  - A reorder of sessions sends nothing.
  - An unchanged card is refreshed about once an hour instead of every 10 minutes.
  - Installing a Prosper update no longer ends the card and starts a new one.
  - The Mac stops its status heartbeat 12 minutes after nothing is active.
  - The beta update check runs every 30 minutes instead of 10.
  (#766)
- **Prosper on iPhone no longer polls the Mac for the session list.** While Agent
  Island shows Remote Terminal's sessions, the phone keeps one connection open and the Mac
  sends the list only when it changes, from the list Agent Island already reads, so no
  extra session checks run on the Mac. The phone side arrives in a Prosper iPhone update.
  (#765)
- **Agent Island checks sessions less often.** An agent that is printing is read every
  6 seconds instead of every 2, plus once when its output pauses and again when it
  turns idle. A new prompt shows within about 2 seconds, or about 6 while the agent
  keeps printing. With nothing changing the island checks every 30 seconds instead of
  10, and every 60 while the display sleeps or the screen is locked. A closed island
  skips redrawing when only the session ages moved. (#768)
- **System Stats and Clipboard auto-clear use less energy.** Stats now sample every 5 s
  (temperatures and power every 10 s) unless you picked a rate yourself; a saved choice
  stays. The menu bar skips a redraw when nothing it shows changed. Clipboard auto-clear
  no longer wakes every minute: it sets one timer for the copied item's deadline, so it
  also clears on time instead of up to a minute late. (#769)
- **Battery saver for the iPhone Live Activity.** With Battery saver picked on the phone
  (or Low Power Mode on), the card updates at most every 2-3 minutes; "needs you" still
  arrives at once, and so does its clearing. Real-time stays the default. A failed card
  update is retried on the next minute instead of an hour later, and an update install
  that was cancelled no longer keeps Prosper from marking the Mac offline on quit. (#770)
- **Always allow answers prompts with Claude Code's auto-block countdown.** A
  permission prompt showing "will automatically block this request in 1:35" was left to
  you when the countdown ticked while Prosper checked it; only the time may now differ,
  any other change still leaves the prompt to you. The same fix applies to clicking an
  answer on the island. Prompts that offer "Yes, and don’t ask again" (with Claude Code's
  curly apostrophe) now get Yes too; "don't ask again" itself is never picked.
  (#784, #783)
- **Always allow leaves prompts you asked for to you.** When one of your PreToolUse
  hooks asks for confirmation ("Hook … requires confirmation for this command") or one
  of your "ask" permission rules matches ("Permission rule … requires confirmation",
  or "Ask rule … overrides auto mode"), the prompt always waits for you and shows as
  Needs input; you can still answer it from the island. (#790)
- **Always allow and dch's auto-allow no longer both answer.** When dch answers
  permission prompts itself (dch 1.29.2 or newer, full build, `auto_allow = true` in
  its config), Prosper's Always allow stands down for those sessions, so a prompt is
  answered once instead of getting a second "1". The island shows dch's answer as
  "Allowed automatically". If dch leaves a prompt alone, it reaches you as Needs input
  after about 5 seconds. Sessions on a pre-1.29 dch, or with dch's auto-allow off, are
  answered by Prosper as before. Until dch releases the same rule as #790, its own
  auto-allow still answers prompts raised by your hooks and "ask" rules. (#792)

## v2.172.0

- **Always allow answers prompts shown while a background agent runs.** Claude
  Code then lengthens the prompt's footer ("Esc to cancel · … stop background
  agents"), and the island stopped recognising the prompt, so neither Always
  allow nor its card saw it. A footer that starts with "Esc to cancel" now
  counts at any length. (#756)
- **Sidekick pattern is a regex.** One pattern can now catch several kinds of
  session, e.g. `-(qa|reviewer)$`, ignoring case. A pattern that is not a valid
  regex is matched as plain text, and Settings says so. So is a pattern that
  matches an empty name (such as `x*`) or one too slow to check. A saved
  pattern with regex characters now means something new: `.` is any
  character, and `c++` matches any name or alias containing "c", so check
  yours after updating; the default `-qa` is unchanged. A pattern made only of
  lookarounds, such as `(?=-qa)`, matches nothing: write `-qa`. (#759)
- Ships dch 1.28.6. A session no longer reads "Needs input" when a prompt's words
  only appear in its scrollback or a quoted message above the input box, and a
  prompt shown while background agents run (such as an Edit or Write) is now
  seen as waiting and gets its card. (#757, #758)

## v2.171.0

- **Always allow is safer to switch off.** It re-reads the setting right before it
  types "Yes", so a check waiting on a slow session almost never answers after you
  switch it off, and the prompt's card shows at once whenever it does not answer.
  Switching it off and back on during a check keeps its answer and re-checks a
  session still waiting. The setting's footer now says "commands and tool
  calls". (#754, #755)
- **Light themes reach every popover.** The Settings app picker and Chat's history
  and persona popovers no longer open dark under a light theme, so their text and
  search hint are readable. An open popover, such as a pinned Calendar, follows a
  theme switch. (#753)

## v2.170.0

- **Always allow permission prompts.** A new Agent Island setting, off by default.
  When it is on, Prosper answers Claude Code's "Do you want to proceed?" with Yes as
  soon as it appears. The Bash command or MCP tool call then runs without your review,
  and your iPhone gets no Needs input for it. It never picks "Yes, and don't ask again", and it leaves every other
  question to you: choices, plan approvals, and edit and file dialogs. If the answer
  does not take, or the same prompt comes back, you are notified as before. The row
  shows "Allowed automatically" each time.
- **Menu bar popups are readable in Light mode.** With the default theme and macOS set
  to Light, the Sensors and Calendar popups drew some control labels in the colour of
  the control behind them: the Automatic and Manual switch, the Headline and Order
  menus, and the Calendar button. Every popup now follows the Prosper theme instead of
  the menu bar.
- **Kill and Stop all report what dch did.** Stop all and Restart all count a
  session as killed only when its Kill worked. "Kill not run" clears as soon as a
  Kill would run. And a failed Kill under Restart all keeps the row's restart result.

## v2.169.0

- **Both ways to resume from History are visible.** Each History row in Agent Island
  now has a right-click menu with Resume (dch types its "resume all work" message) and
  Resume (no message), plus Pin and Remove. A filled play icon next to the plain
  one resumes with the message.
- **No more duplicate History rows.** Starting a session again by hand under a name
  that is already in History used to leave two rows for that name (both pinned, if it
  was pinned). History now shows one row per name, with the older runs folded into it.
  Pin and Unpin act on all of them; Remove clears the unpinned ones. On the phone,
  Resume, Pin, Unpin and Remove now work on such a name; they used to refuse it.
- **Stop all across tabs, and Kill.** The Agent Island "⋯" menu has a Stop all that
  covers every tab, next to the per-tab one. Kill (right-click a session) and Kill all
  (per tab or every tab) end sessions at once, without the pause message: a turn in
  progress is cut off. Kill also works on a session whose Stop or Restart is still
  waiting. Each asks first, and the question names its scope. A killed session can still
  be resumed from History.
- Ships dch 1.28.5. `dch --say` now types into a busy Claude Code, which queues the
  message instead of skipping it as busy.

## v2.168.0

- **Preset manual fan speed after an overheat cut-off.** While macOS holds the fans after
  the overheat cut-off, you can still pick Manual and a speed in the Sensors popup (or
  from your iPhone). Prosper keeps it as a preset, shows that it's waiting, and applies it
  on its own as soon as macOS hands the fans back. You no longer have to keep retrying.

## v2.167.0

- **Your iPhone's snippets on the Mac.** With "Sync library" on, the phone now sends its own
  snippets to the Mac. They show in snippet search (`sn`) and expand by keyword like the
  Mac's own, grouped under the phone, and stay read-only here: you edit them on the phone.
  A Mac snippet always wins a keyword the phone also uses. Settings › Snippets › From iPhone
  lists each phone's set with a Remove button. Needs the matching Prosper iOS update.
- **macOS Text Replacements in snippets.** Your Text Replacements (System Settings ›
  Keyboard, synced with your iPhone through iCloud) now show in snippet search (`sn`) and
  expand by their shortcut, read-only. They fire only at a word boundary, the way macOS
  does, and are typed exactly as written. Your Mac snippets and your iPhone's win any
  shortcut they share. Turn them off with Settings › Snippets › "Include macOS Text
  Replacements".

## v2.166.0

- **Your extensions on the iPhone.** An extension can now offer its plain text commands on
  the phone's Commands screen by marking them `phone = true` (with an optional
  `phone_argument` hint). They show there only after you tick **Allow on iPhone** on the
  extension's row in Settings › Extensions, and only while "Run commands from iPhone" is on.
  The phone asks before running one. An update that adds, removes or renames a phone
  command, or changes its hint, turns Allow on iPhone off until you tick it again. Commands
  that open a window, need the AI model, show a view or list rows stay off the phone.
  See `extensions.md`.

## v2.165.1

- **Fan control from the iPhone.** The phone's Commands screen gains "Fans: Auto", which
  hands the fans back to macOS, and "Fans: Manual", which sets every fan to a percent of its
  speed range (for example "60%") and replies with the target speed. Both run the same
  path as the fan controls in the System Stats popup, with the same overheat cut-off and
  the same reset on sleep. They show only on a Mac with adjustable fans, and only while
  "Run commands from iPhone" is on.
- **Links in a Remote Terminal snapshot can be tapped.** Bundled dch 1.28.4 keeps the
  clickable links (such as a pull request link in Claude's status line) when it redraws
  a session, so they stay links on the iPhone after reconnecting.

## v2.165.0

- **Agent Island: Resume interrupted counts Claudes running in either session folder.**
  With Remote Terminal isolation on, the iPhone app's Resume count, and the island's when
  it showed only Mac terminal or only Remote Terminal sessions, could include a session
  whose Claude was already running in the other folder; dch then skipped it. They now leave it out, as dch does. When
  Resume all brings back two records of one name, each result shows on its own row, and
  a by-hand resume hint for a Claude config folder starting with `=` pastes correctly in zsh.
- **Prosper as the default browser opens local HTML files and never loses a link.** With
  Prosper set as the default browser, a .html file opened from Finder or another app did
  nothing, and so did every link while the URL Dispatcher extension was off, or the link
  that launched Prosper. Opened files now go through the URL Dispatcher like any link
  (its rules can match them). Without the URL Dispatcher, Prosper opens the link in your
  fallback browser, or Safari, and never in itself.

## v2.164.0

- **Agent Island: Restart stale agents, and Restart all agents (force).** The "⋯" menu's
  Restart all agents only ever restarted agents running an older Claude Code than the one
  installed, so with every agent current it did nothing. It is now named Restart stale
  agents, and a new Restart all agents (force) beside it restarts every agent, busy ones
  too, after asking. The iPhone app's Restart all still restarts stale agents only.

- Ships dch 1.28.3. Resume, Stop and `dch --say` deliver their message again: since
  dch 1.26.0 (Prosper 2.163.0) every one was typed but never sent ("not typed"). A
  resumed session also gets the PATH and environment of your login shell. Stopping or
  reviving a session no longer loses its resume id, and starting a new session under the
  name of a stopped or crashed one keeps the old one in history. Resume no longer starts a
  second copy of a Claude session that is already running, and Resume all skips older
  records of a session that a newer one already covers.
- **Agent Island history: one row per session, even when names repeat.** With dch 1.28,
  a session started under the name of an ended one keeps the ended one as its own History
  row:
  - Resume brings back the session of the row you picked.
  - With dch 1.28.1 or later, the pin and × act on that row alone. With 1.28.0, the
    pin and × on the row that holds the name also cover its older rows, and their tooltips
    say so.
  - Resume and Stop failures that dch 1.28 adds read in plain words. A session that
    could not be resumed still shows the `claude --resume` id to recover it by hand,
    with the session's own `CLAUDE_CONFIG_DIR` when it has one.
  - With dch 1.28.2 or later, Resume interrupted (N) counts only the sessions dch would
    actually bring back: not one whose Claude is already running, and not an older record
    of a session that a newer record already covers. The iPhone app's count agrees, and
    Resume all shows why a session was skipped on that session's own row.
- **Remote Terminal comes back on its own after a failed start.** If port 8771 was busy
  when Prosper started, or Tailscale was not connected yet, the iPhone could not connect
  until Remote Terminal was turned off and on again in Settings. Prosper now tries again
  every few seconds, backing off to once a minute, until it succeeds or you turn Remote
  Terminal off.
- **Command runner: the usual text editing keys work in the search field.** ⌘⌫ deletes
  back to the start of the line again; a hidden Delete Quicklink shortcut had taken it,
  even with no quicklink selected. ↑ and ↓ with ⇧, ⌥, ⌘ or ⌃ now move the caret or
  select text, as in any text field; only plain ↑ and ↓ move between results. Delete
  Quicklink stays in the ⌘K actions menu, without a shortcut.
- **Disabling a built-in extension now turns it off completely.** Several built-in
  extensions do their work in Prosper itself, and disabling them in Settings › Extensions
  left that part running. Now, once disabled:
  - Fallback Search shows no "Search Google for …" rows.
  - Snippets no longer expands keywords as you type.
  - Quicklinks and Menu Commands add no rows to the search, and Menu Commands no longer
    reads the menu bar each time the runner opens.
  - Quickdirs' `qd` and each quickdir's own prefix do nothing.
  - Run Shell no longer runs a command typed after `>`.
  - Open App's `o ` no longer searches apps.

  Re-enabling one brings it back with its settings unchanged.
- **iPhone clipboard sync: smaller image downloads.** The iPhone app can ask the Mac for
  a clipboard image at most 1024 pixels on its long side, the size it keeps anyway. The
  Mac shrinks it and keeps its format and transparency. A smaller image is sent as is.
  Syncing images is much quicker and gets cut off less often when you switch apps. It
  needs an iPhone app that asks for it; older ones still get full-size images.
- **Clipboard History and the command runner can be moved.** Drag either panel by
  its bars:
  - Clipboard History: the bottom bar (its icon, its label or the empty space), or the
    search bar's edges and magnifier.
  - The command runner: the edges around the search field, or its icon or mode chip; with
    a result showing, also the bottom bar (the ⌘ glyph, the empty space or the ↩ hint).

  Each panel reopens where you left it while the pointer is on that screen.

## v2.163.0

- **Agent Island: set the command New session runs.** Settings › Agent Island has a
  New session command field, for example `claude` or `headroom wrap claude --chrome`.
  It starts out filled in with the command you already run: the first time it is
  needed, Prosper reads it from a running agent session, else from the newest History
  entry, and keeps it. With no session and no History it runs `claude` and keeps
  nothing, so a later session can still fill it in. The command is used as typed for
  every folder; clear the field to go back to the inferred one. Words split on spaces,
  and quotes group them; nothing is expanded.
- **Agent Island: pin, remove and clear History.** Each History row has a pin and an X.
  A pinned row stays at the top, is never dropped from the list and is never pruned by
  dch, however old. The X removes a row from History at once. A pinned row has no X, so
  unpin it first. Clear unpinned, in the History header, asks once and then removes every
  row that is not pinned. The controls need dch 1.25.0 or later; Prosper now bundles 1.27.0.
- **Agent Island: Resume without the message.** Each History row has a dim play button
  before its pin and X, and Resume interrupted has a "(no message)" button beside it. They
  bring the agent back with its conversation, as Resume does, but type no resume message.
  The Mac accepts the same request from the iPhone app. All of this needs dch 1.27.0 or
  later, which Prosper now bundles. Sessions still running on an older dch don't block it.
- Ships dch 1.27.0, which can pin, unpin and forget session History records (`dch --pin`,
  `dch --unpin`, `dch --forget`, `dch --forget --all`) and resume without the message
  (`dch --revive … --no-message`). A pinned record is never pruned for age.
  Its terminal parser now comes from Ghostty 1.4.0.
  `DCH_SCROLLBACK` counts lines again, so `dch --read --recent` and `dch --wait --match`
  reach about 2000 lines back by default instead of about 250 in a wide terminal, for
  sessions started or restarted after the update. A resume message is now typed more
  reliably: dch waits up to 30 seconds for it to show in the agent's prompt before
  pressing Enter, so "resume message NOT sent" should be rare.
- **Remote Terminal: the iPhone app can read your snippets and quicklinks.** Over
  Tailscale, the Mac serves its snippets and quicklinks files, read-only and as stored,
  so the phone can offer them too. The phone asks with the version it already has, and
  the Mac answers "unchanged" when nothing changed. A file over 3 MB, or one that is not
  valid JSON, is reported to the phone instead of being sent.
- Agent Island reads a running session's dch record with the same checks dch uses: its
  folders and the record must be yours and closed to others, the record is at most 1 MB
  and never a symlink, and it must belong to that session's socket folder.
- A dch session whose name starts with "-" (dch accepts one, such as "--all") no longer
  turns a button into a command for every session. Agent Island shows no Resume, Restart,
  Stop, pin or X for it, and the iPhone app's Resume, Restart, Stop and Kill refuse it
  with a message.
- **Remote Terminal: the iPhone app can pin, remove and clear History.** The Mac now
  sends pinned History records to the phone first, however old, marked as pinned, and
  runs the phone's pin, unpin, remove and Clear unpinned with the same dch 1.25.0 checks
  as the island's own buttons. A pinned record can't be removed until it is unpinned.
- **Remote Terminal: sync clipboard history with your iPhone.** A new setting, "Sync
  clipboard history with iPhone" (off by default, needs clipboard history on), lets the
  iPhone app browse the Mac's clipboard history and pull any item, and send its own
  clips into it. Large items stream in parts instead of being refused, and the phone can
  resume a pull that dropped. Text and images up to the Mac's own clipboard limits
  join the encrypted history; anything larger, and any file, lands in Downloads, as
  AirDrop does, and appears in history as a file. A transfer is refused only when it
  would leave under 5 GB free.
- **Clipboard History shows what is still arriving from the iPhone.** An item the
  phone is sending appears in Clipboard History at once, with its name, "x of y" and a
  plain progress bar. Pasting it waits until it has arrived, then pastes; Esc while it
  waits cancels the transfer, as ⌘⌫ on the row does. A failed or cancelled transfer
  leaves no row.
- **Remote Terminal: chat with the Mac's local AI model from the iPhone.** When the
  coding agent's model is downloaded, the iPhone app can send it a conversation and
  read the reply as it is written. The phone uses the model chosen in Settings › AI
  Models and never changes it. One phone chat runs at a time, and none while the Mac's
  own agent is mid-turn. A model the phone loaded is unloaded again after 5 minutes
  without a phone chat, so autocomplete comes back; the first reply after a load can
  take 30 seconds or more.
- **Remote Terminal: run a few Prosper commands from the iPhone.** A new setting, "Run
  commands from iPhone" (off by default), lets the iPhone app run a short, fixed list of
  the Mac's built-in commands and show the result: Calculate, unit and currency Convert,
  OpenLid Status, Toggle Mac Awake, Toggle Display Awake, Lock Screen, Turn Display Off,
  Start Screen Saver, and Clear Clipboard Now when that extension is on. Nothing else
  can run from the phone: not Shell, not your scripts, and not any command an installed
  extension adds, even one that reuses a built-in command's name.
- Large text copies (over 64 KB) no longer stall the Mac while clipboard history checks
  them for a link, an email or a color.
- Agent Island: Resume interrupted, Restart all and Stop all are no longer cancelled after
  5 or 15 minutes while dch is still reporting progress. The limit now applies to a
  stretch of silence from dch, not to the whole batch.

## v2.162.0

- **Agent Island: the dch session name is hidden unless you turn it on.** A session with
  an alias used to show its dch name (like "solution-master-7") in grey after its state.
  That name is now a Row details option, Session name, off by default. A session without
  an alias still shows its name as the title. History rows now match: the agent's
  session name is the title, and the dch name follows the same option. VoiceOver reads
  the dch name on both tabs only when the row shows it.
- **Remote Terminal: the iPhone app can resume, restart and stop dch sessions.** Over
  Tailscale, the Mac now serves the Agent Island's History and runs its Resume,
  Restart and Stop for the phone. It uses the same dch and the same version checks
  as the island's own buttons, on the sessions the phone lists. It only acts on a
  session that is live or a record in History, and a row busy on the Mac is busy on
  the phone too. The phone half ships in the iOS app.
- Ships dch 1.24.2, whose session pickers (`dch -l`, the rename picker and the headless
  listings) sort alphabetically by the name they show instead of in folder order.

## v2.161.0

- **Fans: Prosper takes the fans back after the overheat cut-off.** When the Mac reaches
  95 °C while your manual speed is set, Prosper still hands the fans to macOS. Since
  v2.156.0 it then refused your speed until the Mac cooled below 80 °C, which on a lap may
  never happen, so the fans stayed at macOS's own, often slower, speed. Now, about 10 seconds
  after the cut-off, your speed comes back as long as it is at or above the speed macOS is
  running the fans at, or ramping them to. A speed below macOS's still waits for the Mac to
  cool below 80 °C.
- **Agent Island: History shows how each session ended, in plain words.** A session you
  closed reads "closed" (it used to read "killed"), and one that ended on SIGTERM, SIGHUP or
  SIGINT reads "ended (signal N)" instead of "crashed". Only other signals read as a crash.
  The Resume button over the list appears only when there is something to resume: it reads
  "Resume interrupted (N)" and counts the sessions that `dch --revive --all` would bring
  back (an abnormal end in the last 3 days, after running at least 5 minutes). With nothing
  to resume, the History tab is just the list.

## v2.160.0

- **Agent Island: sort by name, and an optional Sidekicks tab.** Settings › Extensions ›
  Agent Island has a new Session list section. Sort sessions keeps Last activity (the
  current order: sessions that need input first, then working, done and idle, newest first
  in each) or switches to Name, a flat A to Z list. Sidekick tabs, off by default, splits the
  list the way the iOS app does: sessions whose name or alias contains the Sidekick pattern
  (`-qa` by default, case ignored) move under a Sidekicks tab, and the rest stay under
  Sessions. The tabs appear only when there is at least one sidekick. The summary beside the
  notch still counts every session.
- **Agent Island: a History tab brings ended sessions back.** Next to Sessions (and
  Sidekicks), History lists the dch sessions that ended, newest first: how each one ended
  (crashed, exited, vanished after a reboot or a kill), when, and its folder. Click one to
  resume it: dch starts it again in its folder and resumes its Claude Code conversation. A
  name that is live again comes back as `<name>-2`. Resume crashed brings back every session
  that crashed, exited with an error or vanished in the last 3 days after running at least 5
  minutes, and only when you click it. The controls run with the newest dch installed
  (Homebrew first) and with your login shell's PATH, so a session started as `claude` or
  through a wrapper finds it again even when Prosper was opened from the Dock. They stay off
  when a session runs a newer dch than that, so they never downgrade one. With no session
  running, the island stays at the notch with a dimmed 0 while History has sessions from the
  last 30 days, and opens on History. An open island now stays open when its last session
  ends; it closes when you click away.
- **Agent Island: restart, stop and start sessions from the island.** Right-click a session
  for Restart agent: dch pauses its Claude Code, restarts it on the installed version and
  resumes the conversation; the row shows each step (Pausing…, Relaunching…, Resuming…), then
  dch's result (or why it skipped it). Stop, in the same menu, pauses the session's Claude
  Code, waits for it to go idle and ends the session; History then lists it as stopped, and
  clicking it there resumes it. When Claude Code does not go idle, the session stays up and
  the row says so. The new ⋯ at the top right holds New session, Restart all agents and Stop
  all. New session offers your recent folders (and Choose folder…) and starts a dch session
  there with the command you last used in it, never resuming an old conversation. Restart all
  agents and Stop all ask first, inline. Restart all restarts only the agents and sessions
  running an older version; Stop all stops the sessions in the tab you are looking at,
  skipping any that run a dch older than 1.24.0; each sums up what it did. Like Resume, these
  run with the newest dch installed and stay off when a session runs a newer one.
- **Fixed: Agent Island shows Claude Code's questions again in sessions with a title.** Claude
  Code draws the session's title in a rule under a question while it waits. The island read
  that line as something after the dialog and showed the last screen lines instead of the
  question and its options. It now reads the question, and when it cannot, the screen lines
  it shows wrap between words instead of mid-word.
- Ships dch 1.24.1, which keeps a record of every session it runs, so a session that ended
  (a crash, a reboot, a kill) can be brought back in its folder with its Claude Code
  conversation resumed (`dch --history`, `dch --revive`) (#578). The record holds the
  session's folder and command line, including a prompt typed as a `claude` argument, for 30
  days in `~/.local/state/dch/sessions`, readable only by you; the environment is never kept.
  It adds `dch --say` (type one message into idle sessions), `dch --stop` (end a session so
  `dch --revive` resumes it later) and `--json` output. Restart agent still skips a Claude
  Code typed into a session's shell, and Stop ends such a session without typing `/exit`
  into it.

## v2.159.0

- **Agent Island: every agent session and its state, over the notch.** A new opt-in
  extension (Settings › Extensions › Agent Island) shows your dch sessions in a black
  island at the top of the screen, modeled on Vibe Island. Beside the notch it shows the
  most urgent state and how many sessions are working or need input. Click it for the list:
  each session with its state (working, needs input, done, idle), its live subagent count
  and the time since its last output. Click a session to bring its terminal to the front.
  A session with no terminal window on this Mac opens in a new window of your terminal
  (Ghostty when installed, else Terminal, or iTerm2, WezTerm, kitty or Alacritty), or
  copies its attach command instead, as you pick in the Agent Island settings (#500).
  If the terminal you picked is uninstalled, the settings show the one used instead,
  and picking that one keeps it (#529).
  A session already attached in tmux or over ssh opens as a second, mirrored view; with
  the copy setting, the first click says so and a second click copies. If the terminal
  fails to open, the attach command is copied and the island says so.
  Ghostty opens the session through its scripting interface: macOS asks once whether
  Prosper may control Ghostty, instead of Ghostty asking to run a script on every click.
  If Ghostty is not running it is started first, and if you decline, the island falls
  back to the script (#505). In Ghostty the session opens as a new tab of the open
  Ghostty window, and in a new window only when Ghostty has none (#527). If Ghostty
  does not answer in time, the attach command is copied instead, so the session never
  opens twice (#529). A click opens exactly one tab even when Ghostty fails while
  answering after it has opened it: no second copy, no script prompt, and no row of
  extra tabs when Ghostty was not running (#545). A session that
  publishes its work through dch also shows its open pull requests as repo#number
  buttons that open in your browser, how many it
  has merged, and its tasks done, in progress and queued (#506). The pull requests get a
  line of their own under the session: up to three, then how many more are pending, with
  the merged count at the right (#525). Row details in the Agent Island settings turn
  each of these on or off: the subagent count, open pull requests, the merged count,
  tasks done, in progress and queued. The three task counts start off (#534). Remote
  Terminal sends the same to the phone's session list (#507).
  While Remote Terminal keeps its sessions separate, a setting picks which sessions to
  show (#474).
- Ships dch 1.22.0, which recognizes Claude Code's Write and Edit permission prompts, so
  Agent Island shows those sessions as needing input, reads a session as waiting on a
  permission only from the prompt's own footer line, and carries each session's pull
  requests and task counts (#474, #494, #506).
- **Agent Island answers a waiting agent.** When a Claude Code session stops on a
  permission prompt or a question, the island shows what it asks under that session, with
  one button per option. A click types the option's number into the session, and only if
  the same prompt, with the same command or question and the same options, is still on
  screen; otherwise nothing is sent and the island says the prompt changed. Long commands
  wrap and are shown in full. A command too long for the card, a prompt with hidden or
  direction-changing characters, or one whose top has scrolled out of the terminal can
  only be denied from the island, and an option too long for the card is shown but
  cannot be picked there; approve those in the terminal. An option that changes the
  session's permission mode (switch to auto mode, accept edits, a plan approval that
  leaves plan mode) is never one click on the island, even when a narrow terminal wraps
  its label; change modes in the terminal (#491). A row that only gives the session
  access to a folder ("always allow access to …") is a rule, not a mode change (#508).
  Prompts without numbered options (codex, cursor, opencode) show their last lines and an
  Open terminal button (#475).
  A question with previews shows its whole question, its options and the preview box,
  shrunk to fit (down to 7 pt, then cut with "…"); its options stay greyed out with
  "Previews are answered in the terminal", since that form is answered with Enter.
  A question that wraps over several terminal lines is now its whole sentence on the
  card, not just its last line (#526).
- **Live status on iPhone.** While you are signed in and Agent Island is on, Prosper
  sends your terminal sessions' names and states (never terminal text) to your Prosper
  account, so the Prosper iPhone app can show them as a Live Activity and tell you when a
  session needs you. The card goes offline when the Mac sleeps, Prosper quits or you sign
  out. It is on by default; turn it off in Settings › General › Remote Terminal (#523).
  Signing out and back in no longer leaves it stopped, it keeps updating after the Mac's
  clock is corrected, and Settings says when this Mac is not activated on your account
  (#532).
- **A terminal session started from the phone opens in your home folder.** It used to
  start in the root of the disk ("/"), Prosper's own working folder (#517).
- **Prosper no longer quits when the Mac goes to sleep with a manual fan speed set and
  the fan helper gone or unreachable.** The error path of the sleep-time fan reset ran
  on the helper connection's queue and stopped the app there; it has been possible
  since v2.123.0 (#479).
- **OpenLid's menu stays open while you switch it.** Keep display awake, Let display
  sleep, the Mac-awake switches and their durations change state and update the menu in
  place, and no row moves: while a switch is on, its durations (and Until… for the Mac)
  stay listed but dimmed. Until… and OpenLid Settings still close the menu, as does a
  click outside or on its icon.
  The status rows (display and Mac state, External display, Battery) no longer look
  clickable. For extension authors: a menu row with no handler or `enabled = false` now
  shows disabled, and `stay = true` keeps the menu open when the row is clicked (#482).
- **OpenLid: keep the Mac awake after unplugging, even while charging.** With "Keep awake
  while plugged in" on, the menu and settings used to lock while the charger was connected.
  Now "Keep awake after unplugging", the durations and Until… stay available and turn the
  plugged-in hold into a keep-awake that survives the unplug. A keep-awake that times out,
  or that you turn off, while charging goes back to the plugged-in hold instead of letting
  the Mac sleep, and the menu says so ("Let it sleep on unplug"). The menu-bar icon, and the
  toggle command's result in the launcher (#504), show 🔌 while the Mac is awake only
  because it is plugged in, so you can tell before closing the lid that it will sleep when
  you unplug; 🔓 and ⚡ now mean it stays awake (#502).
  The icon, the menu and the notice change the moment you plug in or unplug, and the
  notice and status overlay for the plugged-in hold show 🔌 as well (#516).
  Three things no longer end a keep-awake on their own:
  - a Wi-Fi drop while charging (the 2-minute no-network guard now runs on battery only);
  - a late timer from an earlier timed session, even while a newer timed one runs, for
    Mac awake and Display awake alike (#503, #504);
  - a plugged-in hold restored on battery after Prosper restarted, which used to stay
    locked "while plugged in".
  Every automatic on and off is now logged with its reason (#499).
- **The update window shows what changed.** Sparkle now lists the release notes for the
  version it offers, from this changelog (#485).
<!-- Drop the next bullet before promoting v2.159.0 to stable (#478). -->
- **Beta testers: 2.159.0-beta.1 quit as soon as Agent Island was turned on.** Fixed in
  beta.2. If beta.1 now quits right after it starts, download beta.2 from the releases
  page; Agent Island stays on (#478).
<!-- Drop the next bullet before promoting v2.159.0 to stable (#483). -->
- **Beta testers: Agent Island's Bash and Write cards in beta.1 and beta.2 left out the
  command and the file path.** A Bash card showed only "This command requires approval",
  and a click did not check that the command on screen was still the one it was raised
  for. From beta.3 a card shows and compares every line of the prompt, from its title
  through the command or file to the last line above the question (#483).
<!-- Drop the next bullet before promoting v2.159.0 to stable (#536). -->
- **Beta testers: in beta.6 some waiting sessions showed no answer card.** A box drawn
  above the dialog, in a Bash command or in an option label was taken for a preview box,
  and the card was dropped; you could still answer in the terminal. From beta.7 such a
  dialog gets its card again (#536).

## v2.158.1

- **Remote Terminal starts again on macOS 15 through 26, and now also on macOS 14.** The
  dch binary embedded since v2.156.0-beta.5 was built for macOS 27 (and for macOS 15 before
  that), so those systems refused to load it and no session could start. The release build
  now targets macOS 14.0 and refuses to ship any binary built for a newer macOS than the
  app supports (#447).
- **The embedded Remote Terminal binary reports its real version.** dch said 1.19.0 in
  every build since it was pinned, whatever the tag; it now says 1.19.2, and its version
  comes from one place so the tag and the binary can no longer disagree (#448).

## v2.158.0

- **Stable installs check for updates every 4 hours instead of every 10 minutes.** The
  10-minute cadence stays on the beta channel so testers pick up a new beta quickly;
  144 daily checks were about 60 % of a stable install's log lines. Toggling the beta
  channel in Settings switches the cadence at once (#192).
- **Copy Text from Screen no longer hangs for up to 40 s when the accurate text recognizer
  stalls.** The accurate pass gets 5 s; when it has not answered by then, or reads nothing,
  the fast recognizer takes over. Autocomplete's screen reading is unchanged (#335).
- **A launch crash while loading the AI model no longer switches your other Macs.** The
  smaller model the crashed Mac steps down to was written into the synced settings, so
  every Mac on the same account switched with it. The step-down is now per Mac and ends
  with the next model pick there; the synced pick stays what you chose (#439).
- **JS plugins run on Bun 1.4.3.** The plugin host downloads the pinned Bun release on
  first use (checked against the release checksums) and falls back to a Bun already
  installed by Homebrew or the Bun installer, whatever version that is, only when that
  download fails. A local build that bundles a Bun of another version fails instead of
  warning (#182).
- **The coding agent tells Codex the local model's real context window.** Codex sized the
  local model at 272k tokens and never compacted before the 40,960-token llama.cpp context
  overflowed; it now compacts in time. Custom MLX models keep Codex's default (#185).
- **The extension runtime moved to Lua 5.4.9.** Upstream bug fixes only (14 files, no API
  change); the vendored sources match the lua.org release byte for byte (#180).
- **The bundled llama.cpp moved from build b9866 to b11429, the build of llama.cpp v0.6.0
  (ggml 0.26.0).** Inline autocomplete and the GGUF coding-agent engine run on it; no
  settings or model files change (#179).
- **The system-stats poller no longer samples the CPU clock, the power rails or the
  network ping while no popup is open.** Only the popup shows them; the idle app sent
  about 29,000 ping packets a day and read IOReport every tick for nothing. The menu bar
  keeps every reading it shows (#188).
- **Stopping a Codex session no longer parks a thread on its exit.** The teardown used to
  wait for the codex process on a Swift-concurrency thread, often for seconds after it was
  gone; with every such thread busy, the delayed SIGKILL for a group that ignored SIGTERM
  never ran. The wait is gone (the process is reaped anyway) and the SIGKILL escalation
  runs on its own thread (#446).

## v2.157.0

- **The AI Model picker offers the Gemma 4 12B and 26B-A4B QAT checkpoints again when
  the MLX engine is selected.** They were hidden while the bundled MLX library could not
  load them; the current release registers both architectures (the dense 12B and the
  128-expert MoE with about 4B active parameters), so the six rows are back with their
  real download sizes (11 to 28 GB) and the RAM tier each needs (#157, #434).
- **Every AI Model picker row now shows the RAM it needs, and rows this Mac cannot hold
  are disabled.** A stored model that needs more RAM than the Mac has is read as the
  largest row that fits (or no model at all), so the app never loads a checkpoint the
  machine cannot hold. A model load that fails inside the MLX library now reports its
  error in the setup window instead of ending the process, and an inline (MLX) load that
  aborts the process during launch is skipped on the next launch, stepping down to a
  smaller model already on disk (or to none) rather than aborting every launch; no
  download ever starts from that fallback, and a sharded checkpoint whose download was
  cancelled part-way no longer counts as downloaded (so neither the fallback nor the AI
  Models pane treats it as ready). The AI Models pane applies the same rule: Download
  and Use-for are disabled on a row this Mac cannot hold, and an agent row that does not
  fit says how much RAM it needs. The Agent model picker does the same, never starts a
  download for such a row, its RAM warning names the model that runs instead of a pick
  this Mac cannot hold, and an agent model synced from a bigger Mac reads as this Mac's
  default instead of being loaded as-is (#435, #436, #437, #438, #440, #441, #442).
- **Tokenizer and chat-template libraries updated.** swift-transformers 1.3.5 and swift-
  jinja 2.5.1: tokenizers honor the model's byte-fallback setting, and tool definitions
  render into the prompt in the same JSON form the model's own template expects (#171).
- **The on-device AI engine moved to the current MLX release.** The two local patches
  Prosper carried for Gemma 4 QAT checkpoints and for stopping speculative decoding cleanly
  are part of the upstream library now, so the app builds from the stock dependency. The
  upstream library now defaults to balanced prefill chunking; loading and generation were
  verified on-device with the Gemma 4 E2B QAT checkpoint after the move.
- **Changed: the kill command no longer spawns a login shell on every settled
  keystroke.** The process list behind `kill <name>` is read once and reused for 2 s
  while you type; each settled keystroke used to run `ps` through a fresh login shell
  (hundreds of milliseconds each), so the list stuttered and the CPU column jumped. The
  kill itself still looks the pid up fresh and goes through the native guard (#432).

## v2.156.1

- **Fixed: a second click on the open Stats, Mixer or Calendar icon closes the popover
  again on macOS 27.** Since v2.156.0-beta.5 (the first build with the macOS 27
  status-item session) the click on the open item was left to the system, which does
  nothing while that item's session is live, so the popover stayed open. The
  outside-click dismisser now owns the click on the open item and still leaves clicks on
  the other icons to the system. (#430)

- **Fixed: the input switcher could leave a configured app on the other language until
  you switched away and back.** macOS flips the layout back right after an app switch,
  so Prosper re-asserts the configured source twice within 0.6 s. Those re-asserts
  checked the frontmost app through a property that can still name the previous app when
  the activation arrives, so both stood down and the flip stuck. They now stand down
  only when a newer switch or any app activation supersedes them. (#431)

## v2.156.0

- **Fixed: Settings could open narrower than its content, cutting the sidebar and the
  cards off on both sides.** Raising the UI size left an already open window below its
  new minimum width, and the window never grew back. Settings and the coding-agent
  chat now grow to their minimum when the size changes, those two and the Marketplace
  do after a restored frame, and a grown window is kept on its screen. Segmented
  pickers keep their natural width at every UI size, so the System Stats, Calendar
  and Appearance pickers ("Text + Graph", the font styles, Text size, Icon Size, the
  Statistics range) no longer hang past their card, the Settings width stops
  shrinking below the 85% preset's minimum so the widest picker still fits at 70%,
  and the Statistics Activity pickers stack when their row is too narrow instead of
  squeezing their labels.
- **Menu Bar Management drops the ordering engine and the live preview.** Opening the
  extension's settings used to flash both hidden bands open and screenshot the bar every
  time (Screen Recording permission, visible flicker, and a slow pane). The preview strip,
  the screen captures and the opt-in icon-ordering engine are gone; macOS owns the
  left-to-right order (⌘-drag) and remembers it. Hiding, revealing, the reveal shortcut,
  auto-rehide, icon spacing and the chevron style are unchanged. The always-hidden section
  (a second divider further left, shown only by ⌥-clicking the chevron) is gone too: its
  divider never showed until you knew to ⌥-click, and getting an icon back out of it meant
  a ⌘-drag inside the auto-rehide window. Icons that sat left of it are simply hidden icons
  now, revealed by a chevron click. The old saved order is deleted on the first launch with
  Menu Bar Management enabled, so a downgrade to 2.155 will not bring it back.

- **Fixed: the sensors, audio mixer and calendar popovers closed when you clicked
  inside them on macOS 27.** Each popover closes itself on a click outside it. The
  check used to assume a click inside our own popover never reached that watcher;
  on macOS 27 it does, so a click on a fan-speed slider or a mixer control dismissed
  the popover instead. The three popovers now share one dismisser that asks which
  process owns the window under the click: a click on anything of Prosper's — the
  popover, a menu or picker opened from it — keeps it open; a click on another app or
  the desktop closes it.
- **macOS 27: the System Stats, audio mixer and calendar popovers open and close through
  the system menu bar.** macOS 27 gives a status item a session the menu bar drives:
  it begins on the icon click or on keyboard navigation and ends when the icon is
  clicked again, another menu-bar item opens, or the user navigates away. The three
  popovers now follow that session instead of toggling on the button themselves, so
  keyboard menu-bar navigation reaches them, opening another menu-bar item closes
  them, and clicking their own icon no longer flashes the popover closed and open
  again. A pinned calendar lives outside the session and still closes with one click
  on its icon. Older macOS keeps the previous behaviour.
- **Fixed: a trackpad swipe on a Settings page jumped the page after a shortcut list
  slid under the pointer.** Each scroll event used to be routed on its own, so a swipe
  that started on the page handed its tail to the list and the page later resumed the
  cut-off gesture by itself. A swipe now stays with whatever it started on, like the
  rest of macOS: a page swipe keeps scrolling the page even over a list, and a swipe
  that starts on a list never moves the page.
- **Fixed: System Stats could create a second, orphaned menu-bar item** when the saved
  module order listed a module twice.
- **Fixed: Full Disk Access detection on macOS 27.** The check read the user TCC
  database, which macOS 27 no longer exposes, so on accounts without a Safari bookmarks
  file the extension permission rows stayed on "Grant" with access already given. It now
  lists `~/Library/Mail` and `~/Library/Safari` instead.
- **Fixed (macOS 27): hidden menu-bar icons reappeared, or slid behind the « overflow
  button, after switching apps on a display without a notch.** The hidden section is
  sized against the frontmost app's menu width; it is now re-sized after each app
  switch, and toggling while a menu-bar-only app (Spotlight) is frontmost keeps the
  last real measurement instead of guessing. Displays placed left or right of the main one
  are measured correctly, and a hung app no longer stalls the switch.
- **System Stats pauses while the display sleeps or the screen is locked.** The 3 s
  sampling tick and the network ping used to run all night (the openlid extension keeps
  the Mac awake lid-closed); they now stop while nobody can see the widgets and refresh
  immediately on wake. Charts show a gap for that period rather than filled-in samples.
  Opening a stats popover resumes sampling if a missed unlock or wake left the widgets frozen.
- **Fixed: Settings search lost the Dock icon, Panel placement, Inline autocomplete and
  Coding agent switches.** They became rows inside Essentials and Local AI, and search
  indexed only section titles. Row titles are now indexed as keywords of their section,
  so a hit jumps to the section that holds the row.
- **Fixed: Settings search could not find Accessibility, Screen Recording or any toggle
  label, and a System Stats row landed on the top of the pane.** Permission rows and
  toggle labels are indexed too, and a System Stats hit jumps to its module's section.
- **Fixed: Stop did not interrupt the coding agent.** Prosper sent `turn/interrupt` and
  `turn/steer` as notifications, which codex silently drops, so a running shell command
  kept going after Stop; turn ids were also read from the wrong field. Both are now proper
  requests, Stop waits at most 5 s for codex before settling the turn locally, and the
  local-model provider no longer retries a dropped stream for minutes.
- **Fixed: coding agent — a reply that finished instantly could leave the chat on
  "Working", and Stop on the next prompt then settled the wrong turn.** Codex announces a
  turn again once its start call returns, which for a fast turn is after it already
  completed; the controller now remembers completed turns and drops that late announcement.
  Stop pressed during the first-use codex download no longer leaves the chat on "Loading"
  until a second Stop, and the stopped run no longer goes on to load the model and start
  codex once that download finishes. A Stop that lands during the model load or the codex
  start no longer leaves a codex running with no owner, and a prompt re-submitted while a
  stopped run is still downloading shares that download instead of starting a second one
  into the same file.
- **Fixed: coding agent — a prompt sent right after a failed run could fail again or
  vanish.** The failed run's teardown kept the dying codex attached while it shut down, so
  a prompt submitted in that second either reused it (a second error row) or, once it was
  gone, started its own codex and then lost its model load to the old run's release, with
  no error at all. The teardown now detaches the failed run first, so the new prompt gets
  its own codex and picks the thread back up, and a teardown that finishes after a newer
  run has started leaves that run's model and state alone. The same held when codex itself
  died mid-request: its request's late failure no longer shows up as an error on, or tears
  down, the prompt sent after it.
- **Fixed: coding agent — a prompt sent while the previous run's model was still unloading
  could borrow that model and lose it mid-request.** The new run now waits for the unload
  and loads its own. A load that Stop cancelled is likewise unloaded before the next prompt's
  load starts, instead of being torn out from under it once it had already been reused.
- **Fixed: clicking the icon of an open System Stats, audio mixer or calendar popover
  sometimes closed it and reopened it at once.** The popover's own outside-click close and
  the icon's click handling both react to the same click; when the close ran first, nothing
  was left to tell the icon that this click had already closed the popover, so it opened it
  again. The close is now recorded, and a click on the icon within 0.4 s of it, or carrying
  the same event, counts as the closing click and does nothing more. The same guard covers
  the macOS 27 menu-bar session path.
- **Fixed: small UI text in a wide Copy Text from Region selection came back garbled or
  empty.** The accurate recognizer breaks down on captures wider than about 2,600 px, a
  full-width strip on a Retina display: 11 pt text came back as "The duick brown tox
  lumps" or as nothing at all. Captures wider than 2,400 px are now read twice, at full
  width and squeezed to that width with the text height kept, and the read that found
  more text wins, with more digits as the tiebreak, so small text is recovered and a
  20 pt "0 failing" keeps its digit at 3,024 px. The tiebreak can also turn a letter
  into a digit (a 20 pt "IO bound" can come back as "I0 bound").
- **Fixed: the first Copy Text from Region after an update looked like it copied nothing.**
  On macOS 27 the first text recognition in a freshly updated build waits about 25 s while
  the system compiles the recognizer for the Neural Engine, and the app showed nothing during
  that wait; the text reached the clipboard only afterwards. The recognizer is now compiled
  in the background at launch, and a read that still hits the cold start shows "Reading
  text…" on screen until the result replaces it.
- **Updated: the coding agent runs codex 0.162.1** (was 0.139.0). Prosper now always runs
  its own pinned codex, bundled or downloaded on first use into a per-version cache, and a
  Homebrew codex is used only under a developer override
  (`defaults write eu.illegible.prosper agentAllowPathCodex -bool true`). The version that
  actually answers the wire is logged once at start. The "Ask only on failure" approval
  choice is gone (codex removed it); a saved one reads as "Ask on request". A downloaded codex is
  now checked and signed before it is put in place, so a failed step never leaves an
  unsigned binary at the pinned path, and the 210 MB archive is deleted afterwards instead
  of staying in Application Support. The swap into place is atomic, so a crash mid-install
  can no longer leave a missing or half-written codex at the pinned path. The first pinned
  install also removes an earlier unversioned codex from that cache.
- **Updated: Sparkle 2.10.0, TOMLDecoder 0.4.5, GRDB 7.11.1.** The update window now comes
  to the front for a menu-bar app with no Dock icon (Sparkle 2.9.4), delta updates no
  longer leak files or trip over macOS 27 file-system compression, and the TOML parser that
  reads your codex `config.toml` and extension manifests picks up its crash fixes.
- **Fixed: a malformed TOML file can no longer crash Prosper.** A codex `config.toml`, an
  imported hooks or MCP config, or an extension's `extension.toml` with extremely deep
  nesting or over 1 MiB is now treated as malformed and skipped instead of overflowing the
  parser. The check now counts nested inline tables and long dotted keys together, ends
  strings exactly where the parser does, and rejects an unterminated string, so a crafted
  file can no longer hide its nesting from it.
- **Fixed: a tool result handed to the OpenAI-compatible Responses API as a bare number or
  boolean no longer reaches the model empty.** A `function_call_output` whose `output` is
  `5` or `true` is passed on as that text instead of an empty tool result.
- **Fixed: a hand-edited `mcp.json` or `hooks.json` that fails to parse is no longer replaced
  at launch.** The file is left as it is, the last working configuration stays active, and
  the failure is recorded in the system log (Console.app, subsystem `eu.illegible.prosper`)
  so you can fix it. The same holds for a file that exists but cannot be read as text (not
  UTF-8, no read permission, or a directory in its place). A missing file is written back
  from the saved configuration.
- **Fixed: the coding agent's approval card can no longer be fooled by a command that hides
  its tail behind newlines or bidi overrides.** The command shown for approval is now one
  escaped line, as the file and permission summaries already were, and invisible filler
  characters such as Hangul fillers or variation selectors are shown escaped. A long command is
  shown in full in a scrollable box, with a "scroll to read all of it" cue whenever the laid-out
  text is taller than the box (measured, in any script, and against the box's real height, so
  the cue still appears when a small window makes the box shorter). Whitespace padding is shown as a count
  instead of blank space: `␠{400}` for ordinary spaces, `⍽{3}` once the run holds a non-breaking
  space, a tab or another unusual space, so padding that is one shell word cannot pass for a
  word break. A Windows line ending in a command shows as one line break, not two. A file diff
  over 256 K characters is cut there with a line
  saying how much more there is, so a huge diff cannot stall the card. Each argument of the
  command is quoted the way a shell would read it, so `bash -c 'ls; curl x | sh'` can no longer
  pass for four separate words, and `~` or a leading `NAME=value` word is quoted too, since the
  command runs without a shell. A command holding Hebrew or Arabic text is drawn in typed order,
  so `echo א > ב` no longer reads as `echo ב < א`. A file diff on the card shows bidi controls
  and other invisible characters escaped, so a Trojan Source line cannot hide what the agent is
  about to write.
- **Fixed: the coding agent's transcript now shows file diffs, command arguments and command
  output with bidi controls and other invisible characters escaped, like the approval card.**
  Colour codes in command output are dropped instead of showing as raw escape sequences, and a
  session saved before this update is shown escaped when reopened. Error lines and tool-call
  arguments are shown as one escaped line too, so a hidden character in an echoed path can no
  longer reorder the error text, and a two-line command on a tool card is no longer cut to its
  first line (the newline shows as `\n`). A diff cut by exactly one character now reads "1 more
  character not shown". On those one-line card texts a backslash typed right before `n`, `u`,
  `r` or `t` now shows doubled (`\\n`), so a typed `\n` or `\u{202E}` cannot pass for a real
  line break or an escaped control; other backslashes, such as a Windows path, are unchanged.
- **Fixed: an extension watching a folder with `host.fs.watch` no longer crashes Prosper on
  the first file change.** The file-event stream was created without the flag that makes
  macOS hand over the paths in the form Prosper reads; no bundled extension uses
  `host.fs.watch`, which is why nothing had shown it.
- **Fixed: the Window extension no longer shrinks a window to nothing when macOS reports an
  invalid frame for it.** The action now stops as if no window were focused.
- **Fixed: in the System Settings extension, "Screen Saver" and "Passwords" opened nothing on macOS 27.** Screen Saver now opens the Wallpaper pane, where macOS moved it, and Passwords opens the Passwords app.
- **Fixed: an extension's menu bar icon now keeps its position across launches.** Each extension status item is saved under its own name instead of a creation-order slot. The icon moves once to its default spot on the first launch after this update.
- **Changed: when no coding-agent model has been picked, the agent now defaults to a model that fits this Mac's memory.** Macs with 16 to 31 GB get Qwen3.5-9B instead of the 32 GB Qwen3-Coder-30B, smaller Macs Qwen3.5-4B; 32 GB and up keep the 30B coder. This applies to every Mac that never chose a model, not only fresh installs: a Mac under 32 GB that was running the 30B by default moves to the smaller model. The choice is made per Mac and is never written into the synced setting. Removing the custom model the agent was using no longer resets the synced setting either.
- **Fixed: extension timers restored from a corrupted saved schedule no longer crash Prosper at
  launch or fire in a tight loop.** Bad intervals are clamped to the normal 50 ms minimum. A
  schedule that lists the same timer twice keeps the later copy instead of crashing at launch.
  For extension authors: `host.timer.schedule` with `every = false` is now a one-shot on
  `after`, not a repeating timer at the minimum interval; only a number makes a timer repeat.
- **Fixed: a hand-edited saved fan speed whose fan index is spelled unusually (`01`, `+1`) no
  longer crashes Prosper at launch or when the stats popup opens.** Only the plain index
  Prosper writes is read back; other spellings are ignored.
- **Fixed: a symlinked `~/.config/prosper/mcp.json` or `hooks.json` (kept in a dotfiles repo,
  say) is no longer replaced by a plain file when settings change.** Writes follow the link to
  its target, and a link whose target is missing is left alone at launch and filled in on the
  next settings change. Relative links (as GNU stow makes them) and chains of links (as Nix
  home-manager makes them) are followed too; a link loop, or a chain of more than eight
  links, skips the write and logs it instead of replacing a link with a plain file.
- **Fixed: clicking Manual in the fan popup just as the Mac goes to sleep no longer saves
  Manual for fans that sleep put back on automatic.** When the helper's reply arrives after
  the wake, the click is dropped and the fans stay automatic, so the popup no longer shows
  Manual over fans running on their own and the next launch does not re-apply a speed that
  never took.
- **Fixed: typing a huge number, `inf` or `nan` into an extension's number setting no longer
  crashes Prosper.** Non-numbers fall back to the field's minimum. An extension that declares a
  non-finite bound (`min = inf`, `max = -inf`, `nan`) no longer makes every typed value save as
  `inf`, `-inf` or `nan`; such a bound is ignored.
- **Fixed: a stuck plugin child no longer outlives Prosper.** Quitting now waits up to a second
  for the plugin host's processes to exit and force-kills any that ignore the polite shutdown
  signal, so an opencode helper or MCP server in the host's process group cannot linger after
  the app is gone. Quitting also stops the coding agent's codex process and the command it is
  running, instead of leaving them behind, and still does so when codex has just exited on its
  own and Prosper is giving the command it ran its few seconds to stop. That stop is only sent
  to the codex session's own processes, never to an unrelated program that later took over the
  same process-group number, and a command that ignores even the force-kill is logged and tried
  again at the next quit instead of being forgotten.
- **Fixed: quitting Prosper or toggling the hyper key no longer waits forever if `hidutil`
  hangs.** Prosper gives up after five seconds, stops the stuck process together with anything
  it started, logs it, and waits a minute before trying `hidutil` again. If `hidutil` fails or
  hangs while reading the current key mapping, or exits with an error, or prints nothing,
  Prosper leaves the mapping untouched instead of replacing it with an empty one. Quitting
  during the minute-long pause still makes one attempt to remove the Caps Lock mapping, so
  Caps Lock does not keep sending the hyper key after Prosper is gone. If `hidutil` fails to
  remove the mapping, Prosper keeps its note that the mapping is still installed and cleans it
  up at the next launch. A failed install is logged and, as before, retried on the next Caps
  Lock press.
- **Fixed: a codex app-server that stops answering no longer hangs the coding agent.**
  Every request now fails after 60 s (2 minutes for turn requests) with "Agent timed out."
  instead of waiting forever, and a request whose parameters cannot be encoded as JSON
  fails with an error instead of crashing Prosper. Malformed codex output (non-JSON lines,
  frames with no usable id, `id: null` parse errors, replies to unknown requests) is logged
  and skipped, a line over 16 MiB is dropped instead of growing memory without bound, and
  a frame holding a number that cannot be written back as JSON no longer crashes Prosper
  when it is logged.
- **Fixed: a tool call with arguments that cannot be written as JSON no longer crashes
  Prosper.** A model reply whose `arguments` is `null` or a bare number, a parameter
  holding a number JSON cannot encode (such as `-1e999`), or a stored turn replaying such
  a call now falls back to empty arguments instead of taking the app down.
- **Fixed: an extension passing a non-finite or out-of-range number no longer crashes
  Prosper.** `math.huge` or `0/0` in a remote-wake interval, a battery floor, a clipboard
  history limit, a process id or a timer interval now falls back to the default or is
  clamped, with a warning in the extension log, and a menu bar item payload that is a
  plain string or number is encoded instead of raising. A window frame or a
  `host.window.set` coordinate that is not a finite number is refused the same way, and a
  timer delay or interval is capped at 366 days (a huge value used to crash Prosper when the
  timer was armed, including at every launch once it had been saved).
- **Fixed: stopping or ending a coding-agent session left codex's helper processes
  running.** The MCP servers and tools codex starts share its process group; Stop and End
  now shut down that whole group, and a codex that crashes takes its helpers with it, so
  nothing lingers in the background. The same now holds for opencode's plugin host: the
  shells and MCP servers it starts go down with Stop and End, and with the host itself.
- **Fixed: the coding agent's permission card now shows what "Always" grants.** The read,
  write and deny roots, network access and the working directory codex asks for are listed
  in the card before you approve, with special locations named plainly (the whole disk, the
  temp dir); legacy patch approvals show each path on one line. Every key the reply would
  grant is shown, including ones the card does not know (as JSON); control and
  bidirectional-override characters in a path or reason are escaped so a crafted name cannot
  forge or hide a card line, and a command item whose command is not text no longer
  crashes Prosper.
- **Fixed: coding agent approvals answered codex in the wrong shape.** A file-change
  approval now shows the paths and the diff being approved (codex only sends the item id;
  the card looked for fields that do not exist and always read "Apply changes to files").
  Answering a permission request now grants or refuses the requested profile for the turn,
  or for the session with Always, instead of a reply codex could not read. Requests Prosper
  cannot serve, such as MCP elicitation, are refused with a JSON-RPC "method not found"
  error instead of a made-up decision.
- **Fixed: a retired coding-agent model id is no longer rewritten in your settings.** The
  saved pick is resolved to its replacement on read only. The pick syncs between Macs while
  custom models do not, so a Mac without your custom model could overwrite the pick you had
  re-added as a custom model on another one.
- **Fixed: manual fan control fought the thermal kill-switch.** When the helper reset the
  fans to automatic at 95 °C, the app re-applied the saved speed about a second later into
  a chassis still above the cut-off, and the switch fired again on its next tick. The helper
  now refuses manual speeds until the hottest sensor is back under 80 °C, the app waits 30 s
  between failed re-applies, and the 2 s reclaim check only runs while manual control is on.
  The latch is helper-wide, so a reconnect or an app relaunch while the helper is still
  running cannot re-pin the fans into a hot chassis either.
  Three more holes are closed: a helper that starts into a chassis already at the cut-off
  starts with the latch held (it used to clear on every helper start); a fan sensor that
  cannot be read keeps the latch held instead of clearing it early; and when the OS takes
  the fans back and the helper's reset fails, the helper keeps retrying instead of leaving
  the fans unsupervised. A failed first engage from the popup also drops the 2 s reclaim
  check it had armed.
  The popup's 45 s engage watchdog now really fires when the helper registration hangs,
  so the button no longer sticks on "Enabling…" until the hung call returns.
  Retrying while that registration is still hung no longer piles up a blocked thread per
  click: every caller now waits on the one registration already in flight, so a wedged
  background-item service cannot starve the rest of the app.
  And an engage the watchdog gave up on that succeeds later is released again instead of
  pinning the fan behind a card that says it failed, unless a newer engage is still in
  flight and owns the fans. A newer engage that then fails releases everything, and turning
  fan control off no longer tears down the helper connection under an engage that just
  picked it up. Turning it off while saved fan speeds were still being re-applied after a
  reclaim no longer pins the remaining fans again. A re-apply engage the app had already
  given up on that lands after fan control was turned off is released as well, and so is
  one that completes just as the Mac goes to sleep. On Macs with more than one fan, the Mac
  going to sleep just as manual control is switched on no longer leaves the later fans pinned
  through sleep either. Switching to Automatic, or the Mac going
  to sleep, while saved speeds were being re-applied after launch or wake no longer leaves a
  fan pinned. A late re-apply reply no longer releases the fans while the popup is still
  engaging them, and a re-apply that fails after Automatic or sleep landed still releases
  the fans it was holding. Fans no longer stay pinned through sleep when manual control was
  being switched on just as the Mac went to sleep, or when the Mac went to sleep while the
  remaining fans were still being switched on: the fans are reset and the manual setting is
  not saved. The same holds when the first fan's engage only replies after the Mac slept and
  woke: the fans stay on automatic and the setting is not saved.
- **Performance: with inline autocomplete off, mouse clicks no longer pass through Prosper**
  and the global scroll monitor is not installed. The keystroke tap listened for every left
  click and every scroll tick on behalf of autocomplete even when it was disabled. Toggling
  autocomplete rebuilds the tap live.
- **Performance: fewer idle timer wakeups.** The LoRA training scheduler only exists while
  training is enabled, and the analytics, keep-awake and extension repeating timers now give
  the OS leeway to coalesce their wakeups.
- **Fixed (macOS 26+): a drag the system cancelled** (Mission Control gesture, a modal, the lock
  screen) left the Window Snap footprint, layout overlay and palette on screen until the next
  click. The cancel event now ends the drag without snapping.
- **Fixed: the audio mixer logged CoreAudio errors when an app's audio session ended or the
  output device was unplugged.** It kept asking CoreAudio to remove listeners from objects that
  no longer existed; those listeners are now forgotten instead. "Gone" is judged against the
  full device list, so a Bluetooth, AirPlay or aggregate output that drops out of the mixer
  rows for a moment keeps one volume listener instead of ending up with two.
- **Fixed: the coding agent's Bypass switch (no approvals, full filesystem and network
  access) synced across your Macs,** so turning it on for one trusted folder on one Mac
  switched the sandbox off everywhere. Bypass is per device now: it no longer leaves a
  Mac in a sync payload and is ignored in one from an older build. Because a value that
  arrived by sync cannot be told from one you set yourself, every Mac starts this build
  with Bypass off once; turn it back on where you want it. Hooks and MCP servers still
  sync, as before.
- **Fixed: the coding agent's sandbox settings were never applied by codex.** Extra writable
  folders, network access and "Bypass all" are now sent in the form the codex app server reads,
  for new and resumed sessions alike.
- **Fixed: coding-agent hooks and opencode plugins never ran** because codex treated them as
  untrusted. Prosper now marks its own sessions as trusting every hook configured in Settings
  (codex `bypass_hook_trust`), so pre-tool-use hooks and the Bun bridge run again.
- **Fixed (macOS 27): the background helper (lid sleep, remote wake, fan control) could fail to
  register on the first launch of a freshly downloaded copy.** Registration now waits until
  Prosper has cleared the download quarantine from its own bundle, helper files included.
  A strip that fails or hangs is logged and can no longer block the registration.
- **Performance: the clipboard watcher polls once a second instead of every 0.6 s and stops
  while the display sleeps or the screen is locked**, polling once immediately on resume.
- **The Prosper icon now has a stable identity in the menu bar** (`ProsperLauncher` instead of
  the generic `Item-N`), so macOS keeps its position reliably. The position you had carries over.
- **Fixed: a coding-agent crash left the chat on "running" forever.** When codex died or
  was killed mid-turn the error was shown only for non-zero exits and the dead backend was
  kept; a clean exit mid-turn showed nothing. Any unexpected exit now shows one error, and
  the next prompt respawns codex and resumes the same thread. A death while that resume
  is in flight keeps the thread armed too, so the prompt after it still resumes the same
  conversation instead of opening a fresh one, and shows one error row, not two.
- **Fixed (macOS 27): menu bar items are now matched to the display they are on** when
  more than one display is connected, so a second display no longer sees every item or
  skips the display guard. Accessibility reads of a hung app time out after 0.25 s
  throughout, so a stuck app cannot stall a hide or reveal.
- **Fixed (macOS 27): Prosper's own status icons keep their names in Menu Bar Management**
  after the bar reflows; they are identified by an accessibility identifier instead of a
  stale on-screen position.
- **Fixed: Menu Bar Management's "Apply now" for icon spacing now relaunches the apps
  whose icons sit on any display**, not only the main one.
- **Performance: opening Settings no longer walks the model cache or runs the privacy
  checks on the main thread.** The AI Models and Context panes seed themselves once per
  launch and refresh in the background afterwards, so later opens are quicker when large
  models are downloaded, and the first open draws in its final state with no flip.
- **Performance: System Stats widgets no longer re-measure their menu bar width on every
  sample.** A width probe now runs only when something that can move the width changes:
  the style or theme scale, a value wider than the reserved sample (power at 100 W or
  more), or the network rates.
- **Agent: Qwen3.6 35B-A3B (llama.cpp, ~22 GB download, needs 32 GB RAM) is a selectable
  model.** Qwen3-Coder 30B-A3B stays the default.
- **Agent: Qwen3 8B and Nemotron 3 Nano 30B-A3B are replaced by Qwen3.5 9B (~5.7 GB) and
  Nemotron 3.5 Lightning 30B-A3B (~25 GB, UD-Q4_K_M).** Both downloads are pinned to a
  Hugging Face revision, like the inline models, and so are the other six llama.cpp agent
  models. A saved pick of a replaced model moves to its replacement, so a 16 GB Mac is not
  pushed onto the 32 GB default.
- **Fixed: coding agent — Stop pressed while a prompt is still being handed to codex now
  sticks.** The turn is interrupted as soon as codex acknowledges it, and the chat no
  longer flips back to Working. A Stop no longer hides an error the backend already
  reported.
- **Fixed: Inline autocomplete model downloads are pinned to a fixed upstream revision,**
  so a model republished on Hugging Face can't silently change what a fresh download
  installs.
- **Fixed: Fan control — when the overheat cut-off is holding the fans automatic, the**
  **popup now says so** instead of claiming the helper isn't running or wasn't approved,
  and a speed change the helper refuses snaps the slider back to the last speed the
  helper accepted.

## v2.155.0

- **Remote Terminal reports how many subagents each session is running.** The session
  list sent to [Prosper Remote](https://apps.apple.com/app/prosper-remote/id6782528095)
  now carries a live subagent count per session. The bundled dch 1.19 reads it off
  Claude Code's agent panel. The phone shows it next to the session state, as in
  "working · 2 agents", in the session list, on the lock screen and in the Dynamic
  Island. Older phones ignore the field.

## v2.154.1

- **Fixed: menu-bar icon spacing and hiding stopped working in 2.154.0.** That release
  removed the menu-bar item-ordering engine, and the removal took the spacing and
  hide/reveal controls down with it. The whole Menu Bar Management implementation is
  restored to its 2.153.0 state, so spacing, hiding, revealing and the chevron style
  work again exactly as before. The ordering feature is back with it for now; the
  removal will return once the breakage is understood.

## v2.154.0

- **Settings pages are laid out the way you read them.** General now opens with one
  **Essentials** card — launch at login, menu-bar icon, Dock icon and panel placement,
  the four things everyone touches — and the heavier opt-in features sit at the bottom:
  **Remote Terminal**, now with a direct link to the free
  [Prosper Remote](https://apps.apple.com/app/prosper-remote/id6782528095) iPhone/iPad
  app it serves sessions to, and **Local AI**, which merges the inline-autocomplete and
  coding-agent switches into one card. In the sidebar, **AI Models** moved below your
  installed extensions, and the header now carries the real Prosper icon.
- **Menu Bar Management dropped the item-ordering engine and the preview strip.** This
  broke icon spacing and hiding and was reverted in 2.154.1.

## v2.153.0

- **Prosper server moved to a new address.** The account server now lives at
  `prosper.ventsislav-georgiev.com` and sign-in emails come from
  `login@mail.ventsislav-georgiev.com`; the old `illegible.eu` address no longer
  exists. On older builds, sign-in, supporter sync, the extension market and remote
  wake fail until this update. Nothing to redo after updating: remote wake re-arms
  itself with the new address on first launch.

## v2.152.2

- **Quick chat answers again, and no longer stalls translate.** Firing quick chat
  (`c …` or `ask …`) showed nothing for a long time, and translate typed afterwards
  waited behind it, until the model was loaded by hand from AI Models. Quick chat and
  translate run on the same gemma model, but the runner first waited for a second,
  ~4 GB model that neither of them uses. Both now start straight away on the model
  that is already there, and that second model stays out of memory. Latent since
  v2.127.0; not caused by macOS 27.
- **Fan speed slider has clickable 5 % marks.** Thin bars under the manual fan slider
  mark every 5 % (taller at 10 %). Click one to set all fans to that speed; hover shows
  the percent.

## v2.152.1

- **Keep awake with the lid closed works again.** Turning on "Mac awake (lid closed)",
  from Settings or the shortcut, silently did nothing since v2.141.0: the checkbox stayed
  off and the lid still put the Mac to sleep. The openlid extension asked the host for
  the network state through a function name the host does not provide, so every
  activation stopped halfway. The extension now uses the host's real name, and the
  extension test harness exposes the same API as the app so this mismatch cannot hide
  again. Not related to macOS 27.

## v2.152.0

- **Menu Bar Management works on macOS 27.** macOS 27 moved every menu-bar icon into
  a system host process: icons are no longer windows, they never leave the part of the
  bar right of the notch, and the host decides what happens to an icon that does not
  fit. Prosper's hide and reveal, the Settings preview and the spacing relaunch all
  relied on the old model and stopped working after the update. The extension now
  detects the new model and adapts: it reads the bar through Accessibility, sizes its
  divider so the host drops the hidden band from the bar (the band disappears the way
  it did before, with no extra system button), and draws the preview from a screenshot
  of the bar. Hide and reveal, the always-hidden band, the Settings list and preview,
  and spacing for third-party icons work again. Apple's own icons keep the system
  spacing on macOS 27; that spacing is fixed by the system. macOS 26 and earlier keep
  the previous behaviour unchanged. On macOS 27 the extension needs Accessibility
  access and asks for it once.

## v2.151.3

- **The Shortcuts lists stay put — measured this time.** Two previous attempts at
  this changed nothing, and both were wrong about why. The scroll event was being
  caught correctly all along; what put the pane back in motion was handing that
  event on to the list, which forwarded it to the pane internally, a frame later.
  The list is now scrolled directly and the event never reaches that path. While the
  cursor is over a list that can scroll, the pane does not move at all. One visible
  consequence: the lists no longer rubber-band at their ends.

## v2.151.2

- **The Shortcuts lists really do stay put now.** v2.151.1 claimed this and did not
  deliver it: the fix relied on AppKit handing an unused scroll event up the responder
  chain, which is not the route SwiftUI's scroll view takes, so the pane still moved.
  The scroll event is now intercepted before it is dispatched at all — while the
  cursor is over a list that can scroll, the pane does not move, at the ends or
  anywhere else. A list too short to scroll passes the event through as before.

## v2.151.1

- **The Shortcuts lists stay put while you scroll them.** Reaching the top or bottom
  of "Bound" or "All Actions" no longer grabs the whole pane and scrolls that instead.
- **The "＋ Launch an app…" picker sits on the All Actions filter line**, next to the
  list it adds to rather than off in Advanced.
- **Shorter list cards.** Both lists are 30% shorter, so more of the pane is visible
  without scrolling.

## v2.151.0

- **Settings › Shortcuts is one searchable list.** Nine sections across five panes
  collapse into a single table of actions: type a name, press the keys. Everything
  bindable is a row — Prosper's own actions, every extension command, every launcher
  prefix, every app — with one row design instead of seven, a Bound group on top and
  an "Advanced" disclosure for the tap-level features (Hyper Key, Quit Guard, Finder
  keys, Key Remapping). Nothing about your existing shortcuts changes; they just live
  in one place now.
- **Quick links, quick dirs and snippets can take a hotkey.** They could not before:
  both are served natively, so the generic per-item binding machinery never saw them.
  Each saved quick link, quick dir (with or without a prefix) and snippet is now its
  own bindable row, and ⌘⇧K in the launcher binds the highlighted one on the spot —
  the same gesture that used to work only on apps.
- **Shortcut conflicts are visible everywhere.** Any two bound actions sharing a chord
  now say so on both rows, whatever kind they are — previously only app-vs-app
  duplicates were flagged. The ⌘Space/Spotlight warning still appears only when this
  Mac actually uses ⌘Space for Spotlight.
- **The shortcuts that hid in other panes came home.** The six window snaps, the
  menu-bar reveal, the calendar toggle and the two volume-mixer shortcuts were bound
  from four separate panes; they are rows in Shortcuts now, and each former pane links
  there. This also fixes a real bug: a shortcut recorded in the Window, Menu Bar or
  Calendar pane wrote straight to storage without re-registering, so it did nothing
  until the next relaunch.
- **The new list scrolls smoothly, lines up, and reads at a glance.** Each of "Bound"
  and "All Actions" now has its own filter field and its own scroll area, so the long
  list no longer stretched the pane's scroll document across dozens of screens and
  re-measured it mid-scroll — that was the stutter and tearing. Every column is a fixed
  width, so titles, categories and key fields line up on every row whatever kind it is,
  and the reset button keeps its slot instead of sliding the row around. Key combos are
  now rendered one way everywhere — macOS glyphs in macOS order (⌃⌥⇧⌘), derived from the
  keys themselves rather than whatever text happened to be stored — so a manifest-declared
  default no longer shows as `cmd+alt+ctrl+k` and a long chord fits its field. "Advanced"
  starts expanded and visually contains the four tap-level sections that belong to it.
- **"All Actions" is all actions, and the app picker is where you'd look for it.**
  Binding a shortcut no longer makes the row vanish from the list you were looking at:
  "All Actions" is the whole catalog always, and "Bound" is a pinned view of whatever
  currently has a chord. The "＋ Launch an app…" picker moved into Advanced, and picking
  an app now filters the list down to that app's new row instead of appending it,
  unseen, to the bottom of several hundred. Advanced also spells out which of the two
  ways to launch an app you want: the picker binds a plain global hotkey and needs no
  Accessibility permission, while Key Remapping's "Launch App" needs it and buys per-app
  scope, media-key triggers and key swallowing.

## v2.150.0

- **Remote Terminal: the phone's session list now shows the short session names.**
  `dch -l` labels a session with its alias, falling back to the Claude Code session
  name running inside it; the phone showed the raw socket name instead, so
  "prosper" read as "prosper-main" and "hawkvibes" as
  "hawkvibes-feat_encrypted-plane-pilot". The server now applies the same
  precedence — alias, then harness name, then the raw name — so both lists agree.

## v2.149.0

### Fixes
- **The manual fan slider no longer snaps back while you drag it.** The sensors
  popup refreshes fan readings about once a second, and that refresh was
  overwriting the speed you were still dragging with the previously saved one —
  repeatedly, for the whole gesture. Your in-flight value now holds until it is
  actually saved. Automatic recovery of manual fan control after macOS reclaims
  the fans is unchanged, just paused while you are adjusting.
- **Rebuilding the menu-bar menu no longer throws.** Menu rows the app reuses are
  now detached from their previous menu before being re-inserted; previously a
  second rebuild raised “Item to be inserted into menu already is in another
  menu”. No shipping path rebuilt the menu twice, so this was a latent crash
  rather than one you could hit.

## v2.148.0

### Fixes
- **The command runner no longer creates duplicate Prosper icons in the Dock.** The transient runner stays out of the Dock entirely; durable windows such as Settings retain their normal Dock behavior.
- **Cmd+Space conflicts now point to Spotlight’s shortcut setting.** Prosper detects Spotlight even though macOS lets both apps receive the key, then offers to open Keyboard Shortcuts so you can rebind either app.

## v2.143.0

- **New menu-bar defaults: the Vulcan salute at Medium size.** A fresh install (or
  one that never picked an icon or size) now shows the Vulcan 🖖 template glyph at
  the Medium size in the menu bar. Anything you picked explicitly — including the
  classic Prosper icon and the Large size — is untouched and still wins.

### Performance
- **Typing latency**: with an extension key-listener active, every keystroke used to
  make a blocking system call (LaunchServices, over XPC) to name the frontmost app —
  inside the system-wide event tap, where a slow callback stalls every app's input.
  The frontmost app is now cached and refreshed only when you actually switch apps,
  so the per-keystroke path is a memory read.
- **~100-120 MB less memory, permanently**: the bundled spell-correction index (a
  16-20x blowup of a 6 MB dictionary) is gone — typo corrections for the completion
  hints now come from the macOS spell checker, which was already loaded and gives
  better corrections from the full system dictionary.
- **Gigabytes back after AI use**: the idle model unloader only ever freed the MLX
  engine, but the default translate/chat engine is llama.cpp — so after a
  translation, ~3.3 GB of model weights stayed resident until you quit the app. The
  idle unload now frees both engines (the next AI request transparently reloads,
  ~0.4 s), and then asks the allocator to hand freed pages back to the OS.
- **Audio limiter overhead halved**: the boost limiter's per-sample loop was
  rebuilding buffer-list iterators on the real-time audio thread; the buffer layout
  is now resolved once per callback. Output is bit-identical.

### Fixes
- **Screen-context OCR could crash the app**: dragging a sliver-thin capture region
  (or any image with a side of 2px or less) made Vision report the failure twice,
  which trapped. All OCR entry points now have a single result path and return
  empty results instead.
- **Multi-display capture regions**: with a second display arranged *above* the
  primary, caret-context screen captures landed on the wrong spot — the
  AppKit-to-CoreGraphics flip anchored to the topmost display instead of the
  primary one. All conversions now share one primary-anchored helper, unit-tested
  across every arrangement (above, below, left, right, mixed).

## v2.142.0

### Improvements
- **Settings → Appearance: pick your menu-bar icon — and its size.** A new **Menu Bar
  Icon** section (above the theme list) offers the classic Prosper icon (still the
  default), a Vulcan salute 🖖 right next to it, a handful of macOS-native symbols
  (sparkles, bolt, command, terminal, cpu), or any emoji you type. The native symbols
  and the Vulcan preset render as template glyphs, taking the menu bar's own
  white-on-dark / dark-on-light coloring so they sit seamlessly next to the built-in
  status items; a custom emoji keeps its full color, exactly like emoji in the menu
  bar's own text. An **Icon Size** control (Small / Medium / Large — Large is the
  default and matches the previous size) scales whichever icon you picked. Everything
  applies instantly and wins over theme-provided icons until you switch back. The
  swatches preview the exact tint the menu bar will use — the system appearance's
  black or white — rather than the current theme's colors.
- **The built-in themes got a color overhaul.** The recently added themes blended
  together — several were near-duplicates and a few even rendered error text in a gray
  indistinguishable from their accent (Graphite, Silver). Every non-default theme now
  has a clearly distinct accent, deeper light-theme contrast, and readable alert/success
  colors (all themes clear WCAG AA); Gold, Rose and Contrast Dark were re-tuned away
  from their look-alikes, and two new themes — **Lime** and **Fern** — fill the gaps.
  Default and Amber are untouched. The theme list now also groups all dark themes
  first, then all light ones.

### Fixes
- **Settings → Appearance**: the Appearance pane now repaints fully the moment you pick
  a theme — previously every other window changed while the pane's own cards and theme
  list kept the old colors until you switched sections and back.
- **Volume mixer**: the popup no longer slides down a point when the system output goes
  from muted to sound (and back up on mute) while it is open. The menu-bar glyph swap
  was resizing the button the popup anchors to; every glyph now renders in a fixed box.

## v2.141.0

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
- **Settings → Appearance**: picking a theme no longer resets your scroll position,
  and the whole window repaints to the new palette immediately — including the
  theme list itself. The selected theme row can be moved with ↑/↓, with no focus
  ring drawn around the list, and scrolling the pane stays smooth.

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
