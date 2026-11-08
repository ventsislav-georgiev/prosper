# Remote frames protocol, version 1.0

This is the wire contract between a remote-terminal **server** (Prosper's `DchSessionServer`
today, `dch serve` later) and its **clients** (the Prosper iPhone app, `dch` as a client). It
describes what Prosper's server does as of v2.174.0 (#776: the 0x08 keys `server`, `os`,
`name` and `proto`, and this document) and #800 (the `create` and `paste_image` ops). The code is in
`app/Sources/ProsperApp/Server/DchConnection.swift` (`DchFrame`, `DchConnection`) and
`DchSessionServer.swift`.

The conformance set in [`golden/`](golden/) runs against any server: see
[Golden frames](#golden-frames).

## Transport and trust

- Plain TCP, port 8771, IPv4 only. No TLS, no tokens, no pairing: Tailscale is the trust
  boundary.
- Prosper binds the first IPv4 address in 100.64.0.0/10 it finds on any interface, which is
  Tailscale's on a normal Mac. With none it does not listen (it retries with backoff); it never
  falls back to a wider address. That range is not Tailscale's alone: see
  [M10](#known-gaps). No IPv6 in 1.0.
- Prosper drops every peer whose address is not an IPv4 address in 100.64.0.0/10, IPv6
  included, before it reads a byte (the client sees a close).
- Prosper then lets in only the host owner's own devices: the owner check (#777, see
  [Decided defaults](#decided-defaults-for-dch-serve)), also before it reads a byte.
- A server must never bind a wider address than its Tailscale one on its own; `dch serve`
  binds another only when its operator names it (`--bind`). See
  [Decided defaults](#decided-defaults-for-dch-serve) for the rules `dch serve` follows.

## Versioning

- The server states its version in the 0x08 reply as `proto`: `"<major>.<minor>"`, decimal.
  This document is `1.0`.
- A minor bump only adds: new optional keys, new frames, new `ops` names. A client ignores
  keys and `ops` it does not know.
- A major bump breaks. A client that reads a newer major than its own refuses the host
  (shows it as unsupported and sends nothing else); the phone does so since TestFlight
  build 162 (Q5). A 0x08 reply with no `proto` is a pre-#776 Prosper, which is 1.0.
- A client states its own version in the 0x08 request as `{"proto": "<major>.<minor>"}`; the
  phone sends `{"proto": "1.0"}` since TestFlight build 162 (Q1). `dch serve` answers a newer
  major than its own with 0x13 instead of 0x18. Prosper ignores the request payload, so it
  refuses nobody (see [M2](#known-gaps)). A request with no `proto` (an empty payload, an older
  phone) is 1.0.

## Framing

Every frame, in both directions:

```
+--------+----------------------+-------------------+
| type   | length               | payload           |
| 1 byte | u32, big-endian      | `length` bytes    |
+--------+----------------------+-------------------+
```

- Control payloads are UTF-8 JSON (an object or an array, per frame). An empty payload is
  length 0. A server must accept a JSON request as length 0, `{}` or the documented object,
  as each frame below says.
- Data payloads (0x10, 0x19, 0x0a) are raw bytes.
- Frames may arrive split across TCP reads or several to a read; both sides reassemble.
- **Send limit: 8 MiB** (`8 << 20`) per frame, the phone's `ProsperTransport.maxFrame`. The
  phone closes the connection on a longer length prefix. Prosper enforces this on the frames
  that can grow (libraryResp, clipboardResp, clipboardItem's data chunks of 1 MiB); a pty 0x10
  frame is at most 32 KiB of output. Prosper does not check it on every frame: see
  [Known gaps and open questions](#known-gaps-and-open-questions) (M1).
- **Receive guard: 256 MiB** (`256 << 20`). A length prefix over it is garbage: the server
  closes the connection and reads nothing more from it. A length of exactly 256 MiB is
  accepted. Prosper sends `0x13 {"message": "frame too large"}` as the last frame before the
  close; other servers may, and a client must not rely on it. This is a guard, not a size
  anyone should send: the phone does send a pasted photo as one 0x0a (17 MB for a 4032 px PNG)
  and a big paste as one 0x10.
- **Core control requests stay under 64 KiB.** A client keeps every core-subset control
  request (0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x2e) under 64 KiB (`64 << 10`). A server
  may answer a larger one with `0x13 {"message": "frame too large"}` and close; `dch serve`
  does. 0x10 data and the Mac-only frames are bounded only by the server's own receive guard
  (Prosper's is the 256 MiB above, `maxRequestFrame`).

## Connections

- **One operation per connection.** A request/reply verb gets its reply and the client closes.
  An attach, a create and a watch own their connection for its life.
- **Replies are matched by type, not by order.** Requests may be pipelined on one connection,
  but a client must not assume replies come back in the order it sent the requests:
  - A client must not pipeline two requests whose replies can share a type. 0x13 answers
    every error and 0x14 answers kill, rename, 0x0a, 0x17 and most `ops` verbs, so after
    one of those a client waits for its reply before it sends another request that gets a
    reply.
  - Frames that get no reply (0x10 input, 0x05 resize, 0x07 redraw) may follow any request
    at once: a server handles a connection's frames in the order they arrive. The phone
    sends 0x0a and then the ctrl-V 0x10 without waiting for the 0x14, and Prosper sets the
    pasteboard before it reads the next frame.
  - 0x08 → 0x18, 0x03 → 0x11 and 0x09 → 0x19 never answer 0x13, so they may be pipelined
    with each other. The exceptions: `dch serve` answers a 0x08 that states a newer major
    `proto` with 0x13 (see [Versioning](#versioning)), and a frame over a size guard may get
    0x13 then a close: Prosper's receive guard on any type, the 64 KiB core-request limit on
    `dch serve` (see [Framing](#framing)).
  - Prosper answers 0x03, 0x04 and 0x06 at once, in the order they arrive; 0x09 too on a
    connection that has not attached.
  - These replies can trail replies to frames sent after them: 0x08 (Prosper waits up to
    0.25 s for a dch version probe), 0x09 on an attached connection (it reads dch's screen
    off the connection), and every `ops`-gated request but 0x02 and 0x0a (Mac-only frames run
    off the connection too). 0x0a is gated yet answered at once, before the next frame is
    read; 0x02 gets no reply (its session's output follows).
  - The phone sends one request per connection.
- **One in flight.** These Mac-only requests allow one in flight per connection: 0x0b-0x0f,
  0x15, 0x16, 0x1e, 0x1f, 0x22-0x26, 0x28, 0x29, 0x2c, 0x2d. Another of them while one is in
  flight gets `0x13 {"message": "busy with an earlier request"}` at once, ahead of the first
  one's reply. The others are never refused as busy:
  - the base frames, 0x02 create, 0x0a putClipboard and 0x17 putClipboardText are handled even
    while a request is in flight;
  - a second 0x2e on a connection that is already watching is ignored (no reply);
  - a 0x2e on a connection that attached, chatted, uploaded or has a request in flight gets
    `0x13 {"message": "watch needs its own connection"}`.
- **Unknown frame types are ignored**: no reply, the connection stays open. A client tells an
  old server by a missing reply (the phone gives 0x08 two seconds).
- Everything malformed is a 0x13 reply, except for the base frames, 0x02 create and 0x0a
  putClipboard, which answer as each one's section says (0x01 and 0x02 fall back to their
  defaults, 0x04 and 0x06 answer 0x14, 0x0a answers 0x14, see [M11](#known-gaps)), and a length
  over the receive guard, which closes.
- **When Prosper closes a connection.** A client must expect a close at any time. Only 0x12
  exit means the session ended; every other close is a refusal, a dropped link or the
  client's own FIN. Prosper closes:
  - on a length prefix over the receive guard (0x13 `frame too large` first);
  - after 0x12 exit (the FIN follows the frame);
  - when an attach or create fails to spawn (0x13 first, see below);
  - when another connection attaches to the same session (the newest wins; no frame);
  - when an attached session's output has not been taken by the socket for 20 s;
  - when a frame of a 0x16 reply (the 0x1a header or a 0x10 chunk) has not been taken by
    the socket for 60 s;
  - on a watch stream: when a fifth stream of the same device opens (the device's oldest
    stream is closed), when 32 frames are unsent, or when the server loses its list;
  - during a 0x23 clipboardUpload, when the Mac's user cancels the incoming item;
  - when the server stops (Remote Terminal turned off; a failed listener alone closes no
    connection);
  - at once, for a peer outside 100.64.0.0/10 (no frame is read or sent);
  - once the owner check refuses the peer (#777; at most 2 s after accept, no frame is read
    or sent);
  - at once, for a connection that reaches a listener Prosper has just replaced (a race
    while it rebinds; no frame is read or sent);
  - **at once, when the client closes its sending side** (its FIN, a half-close with
    `shutdown(SHUT_WR)` included). Replies still pending then are dropped: 0x08's (it can
    wait up to 0.25 s), 0x09's on an attached connection, any `ops`-gated one. A reply
    Prosper sent just before the FIN can be lost too. **A client must not half-close before
    it has read every reply it waits for.**

## Replies every frame shares

| Type | Name | Payload |
|------|------|---------|
| 0x13 | error | `{"message": string}`: one line, shown to the user as written. |
| 0x14 | ok | Empty for kill, rename, putClipboard; a JSON object where the frame says so. A client accepts both. |

## `ops`: what a client may send

0x08's reply carries `ops`, an array of strings. The **base frames** (0x01, 0x03-0x09, 0x10)
are not in `ops`: a server that answers 0x08 serves them. Every other request is sent **only
when its op is listed**, so a server answers exactly what it advertises and need not answer the
rest.

Two base-range frames are capabilities too: `create` (0x02) and `paste_image` (0x0a). A server
lists each when it serves it. Older Prosper served them without listing them, so a client gates
them like this:
- **new session (0x02)**: allowed when `server` is `"prosper"` or absent, or `create` is in
  `ops`. Every Prosper that answers 0x08 serves 0x02 (both first shipped in v2.123.0).
- **image paste (0x0a)**: allowed when `server` is `"prosper"` or absent, or `paste_image` is in
  `ops`. "Absent" is not exact here: no released Prosper sends `server` before v2.174.0, and
  0x0a first shipped in v2.134.0, so a Prosper from v2.123.0 to v2.133.x passes this gate yet
  ignores 0x0a (an unknown frame type). Nothing hangs: the phone sends 0x0a without waiting
  for its 0x14 and then the ctrl-V, so on such a Mac the image is dropped and the ctrl-V pastes
  whatever the Mac's clipboard already held.

Prosper lists both, always (#800). `dch serve` lists `create` only with `--allow-create`, and
`paste_image` only once it supports 0x0a; the two are independent. On Prosper, neither "Run
commands from iPhone" nor clipboard sync limits 0x02 or 0x0a: those settings gate only the
`commands` and `clipboard` frames.

Prosper's ops and their frames:

| op | Frames it gates | Prosper lists it |
|----|-----------------|------------------|
| `history` | 0x0b | always |
| `revive` | 0x0c | always |
| `revive_no_message` | 0x0c's `"no_message": true` | while the control dch is 1.27.0+ |
| `restart` | 0x0d | always |
| `stop` | 0x0e | always |
| `library` | 0x0f | always |
| `pin` | 0x24 | always |
| `forget` | 0x25, 0x26 | always |
| `snippets_put` | 0x2c | always |
| `sidekick` | 0x2d (and the 0x2e stream's sidekick frame) | always |
| `clipboard` | 0x15, 0x16, 0x17, 0x22, 0x23 | while clipboard sync is on |
| `clipboard_max_side` | 0x16's `max_side` | only beside `clipboard` |
| `chat` | 0x1e, 0x1f | while the agent model is on disk |
| `commands` | 0x28, 0x29 | while "Run commands from iPhone" is on |
| `watch` | 0x2e | while Agent Island lists Remote Terminal's socket dir |
| `create` | 0x02 | always (dch serve: only with `--allow-create`) |
| `paste_image` | 0x0a | always (dch serve: only once it supports 0x0a) |

## Core subset and Mac-only frames

A **dch server** serves the core subset; everything else is Mac-only and absent from its `ops`.

| Type | Name | Direction | Core | Gate |
|------|------|-----------|------|------|
| 0x08 | machineInfo | C→S | yes | base |
| 0x18 | machineInfoResp | S→C | yes | |
| 0x03 | list | C→S | yes | base |
| 0x11 | listResp | S→C | yes | |
| 0x2e | watch | C→S | yes | `watch` |
| 0x01 | attach | C→S | yes | base |
| 0x02 | create | C→S | yes | `create` (or `server` `"prosper"`/absent) |
| 0x10 | data | both | yes | base |
| 0x05 | resize | C→S | yes | base |
| 0x07 | redraw | C→S | yes | base |
| 0x09 | snapshot | C→S | yes | base |
| 0x19 | snapshotResp | S→C | yes | |
| 0x12 | exit | S→C | yes | |
| 0x04 | kill | C→S | yes | base |
| 0x06 | rename | C→S | yes | base |
| 0x13 | error | S→C | yes | |
| 0x14 | ok | S→C | yes | |
| 0x0a | putClipboard | C→S | no (Mac) | `paste_image` (or `server` `"prosper"`/absent) |
| 0x0b-0x0f, 0x15-0x17, 0x1a-0x1f, 0x20-0x2d | see below | | no (Mac) | per `ops` |

## Core frames

### 0x08 machineInfo → 0x18 machineInfoResp

Request: empty, `{}` or `{"proto": string}` (see [Versioning](#versioning)). Prosper ignores the
payload. Reply: one 0x18; `dch serve` answers 0x13 instead when `proto` states a newer major than
its own. Prosper never answers 0x08 with an error.

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `device_id` | string | **yes** | Stable id of the host. Without it the phone's `decodeMachineInfo` returns nil and treats the host as a legacy Mac with no ops. Prosper: lowercase hex SHA-256 of the host UUID. dch: hash of `/etc/machine-id`, or a UUID kept in its state dir. **Never derived from an IP.** |
| `hostname` | string | yes | The host's name for display. Prosper sends the computer name (`Host.current().localizedName`); dch sends `gethostname()`. |
| `ops` | [string] | yes | See [`ops`](#ops-what-a-client-may-send), `create` and `paste_image` included. Unknown names are ignored. |
| `server` | string | yes (1.0) | `"prosper"` or `"dch"`. |
| `os` | string | yes (1.0) | Human-readable OS and version: `"macOS 27.0"`, `"Linux 6.8"`. |
| `name` | string | yes (1.0) | Display name. Prosper: the computer name (equal to `hostname`). |
| `proto` | string | yes (1.0) | `"1.0"`. See [Versioning](#versioning). |
| `wakeId` | string | no | Prosper's remote-wake id, only while remote wake is set up. **A dch server leaves it absent.** |

Example (Prosper, clipboard sync off, no model, commands off, no watch):

```json
{"device_id": "3f9a…", "hostname": "Studio", "name": "Studio", "server": "prosper",
 "os": "macOS 27.0", "proto": "1.0",
 "ops": ["history", "revive", "restart", "stop", "library", "pin", "forget", "snippets_put",
         "sidekick", "create", "paste_image"]}
```

A `dch serve` without `--allow-create` does not list `create`; it lists `paste_image` only once
it supports 0x0a, whatever `--allow-create` says.

### 0x03 list → 0x11 listResp

Request: empty. Reply: one 0x11, a JSON array of rows. **The row order is unspecified;
clients sort.** Prosper sends rows sorted by name when it answers from Agent Island's list, but
in `dch --ls-json` order, which is unsorted, when it forks dch instead: with no island list for
Remote Terminal's directory, and after a kill, rename, create, attach, revive, restart or stop
until the island publishes again at least 5 s later. Each row's keys are sorted.

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `name` | string | yes | The dch session name: what attach, kill and rename take. |
| `alias` | string | no | Display alias (dch's alias, else the Claude Code session name); absent when empty. |
| `state` | string | no | `working`, `idle`, `blocked` or `done`; absent when unknown. |
| `agents` | int | no | Live subagents; absent when 0. |
| `meta` | object | no | `{"prs": {"open": [{url, repo, title, num?}], "merged"?: int}}`; only allowlisted `https://github.com/<owner>/<repo>/pull/<n>` URLs. |
| `meta_epoch` | int | no | When `meta` last changed (epoch seconds); absent when unknown. |

A payload that is not a JSON array is an error on the phone (it keeps its rows). No error reply.

### 0x2e watch (gate: `watch`)

The live list, pushed (#765). On a connection of its own.

Request: empty, `{}` or `{"device_id": string}`. `device_id` is optional: without it the server
keys the stream by the peer's address for the per-device stream cap, as Prosper does. The phone
sends it (Q8).

Errors, each a 0x13 and the stream does not open:
- the payload is not a JSON object: `malformed watch request: send {}`;
- the connection already attached, chatted, uploaded or has a request in flight:
  `watch needs its own connection`;
- the server has no list to stream (Prosper: Agent Island does not list Remote Terminal's dir;
  the client falls back to polling 0x03).

A second 0x2e on a connection that is already a stream is ignored: no reply, the stream goes on.

Stream, all server to client, until either side closes:
1. **Snapshot first**: one 0x11 listResp with the whole list.
2. If `sidekick` is in ops: `0x14 {"sidekick": {"pattern": string, "updated": int}}`, then again
   whenever the pattern changes, at most one per second (the trailing value always sent).
3. **Changes**: a 0x11 whenever the payload differs from the last one sent, **coalesced** to at
   most one per second; the trailing change is always sent. A change back to what the client
   has sends nothing.
4. **Heartbeat**: `0x14 {}` after 25 s with nothing else sent. A client calls 60 s of silence dead.
5. At most 4 streams per device: a fifth closes that device's oldest. A client that stops
   reading (32 frames unsent) is closed rather than buffered. A server that loses its list
   closes every stream; the client reconnects, is refused and polls.

A watch stream does not count as an attached client for Prosper's keep-awake.

### 0x01 attach, 0x02 create, and the attached connection

Requests:
- 0x01 attach: `{"name": string, "cols": int, "rows": int}`. On Prosper, and on `dch serve`
  with `--allow-create`, it is attach-or-create (dch's `-n`): an attach to a name with no live
  session, a session whose master is gone included, starts it. `dch serve` without
  `--allow-create` answers an attach to a name not in its list with 0x13
  `{"message": "no session named <name> …"}` and starts nothing. A client that wants a new
  session sends 0x02 where `create` is listed.
- 0x02 create: `{"name"?: string, "command": [string], "cols": int, "rows": int}`. No name: dch
  picks one. `command` empty: the default shell. The command is never read as flags: Prosper
  spawns `dch -E [-n <name>] -- <command...>` (#803), so `["-kl"]` runs a program named `-kl`.
  A nameless create gets its name from dch, and 1.0 does not announce it: the client learns it
  from its next 0x11 list or from the watch stream (a later minor may add a key that carries it).
- `cols`/`rows` set the session's initial window size; 80×24 when missing.

The connection then carries one session:
- **Redraw on attach.** The server's first 0x10 bytes are a full repaint of the session's
  screen. Prosper gets this by spawning a real `dch -E -f -n <name>` client in a pty, so the
  master repaints for the new client. `dch serve` must send the same repaint on attach.
- 0x10 data, client to server: raw bytes for the session's input (keys, pastes).
- 0x10 data, server to client: raw pty output.
- 0x05 resize `{"cols": int, "rows": int}`: the session's window size (80×24 for a missing key).
  No reply.
- 0x07 redraw (empty): force a repaint (Prosper shrinks the pty a row and restores it). No reply.
- 0x05 and 0x07 on a connection that has not attached are ignored: no reply, no error (Prosper:
  there is no pty to size or repaint).
- 0x09 snapshot (empty) → 0x19 snapshotResp: raw ANSI of the session's current screen from
  dch's VT mirror (the output of `dch --read --ansi`), with the caret appended as
  `ESC[row;colH` when known. Prosper and `dch serve` (Q4) answer it the same way. **Empty**
  when the server has no screen to offer, for example: no mirror (a lite build, a master that
  predates dch 1.2), a connection that has not attached, an attached create with no session
  name (Prosper), or a `dch --read` that fails or prints nothing (Prosper). The client keeps
  what it has. 0x09 never answers 0x13
  (a frame-too-large 0x13 aside, see [Framing](#framing)): a server with no screen to offer
  sends an empty 0x19.
- 0x12 exit `{"code": int}`: the session's client exited; the server then closes (the FIN
  follows the frame). `code` is the exit status of the dch client the server ran, not of the
  session's program: a create of `exit 3` can report 0. No golden fixture asserts a code (the
  format cannot express it).
- The client detaches by closing the TCP connection. The session lives on.
- One client per session: the newest attach to a session retires the server's older
  connections attached to it (Prosper).
- A second attach or create on the same connection is ignored. Attach or create on a
  watch, chat or clipboardUpload connection: 0x13 `"<kind> connections cannot attach or create"`.
- A failed spawn (Prosper: `forkpty` fails, the Mac is out of ptys or processes): 0x13
  `{"message": "Could not start the session: ..."}`, then close; the 0x13 is sent as the last
  frame before the FIN. Frames the client sent after the attach on that connection are
  discarded.
- A 0x13 in answer to the attach or create (or any 0x13 followed by the server's FIN) is
  terminal for that connection: the client shows the message and does not reconnect to the
  same name on its own (a user action may retry). It is not a dropped link; an automatic
  reconnect would usually get the same 0x13. A 0x13 answering a later control frame on a live
  session (a refused kill, "busy with an earlier request", a kind that needs its own
  connection) is not terminal: the session stays attached.
- 0x10 on a connection with no session (and no upload) is dropped.

### 0x04 kill, 0x06 rename

- 0x04 kill `{"name": string}` → 0x14 (empty). Ends the session (`dch -k`). A name starting
  with `-` → 0x13 `a session name starting with - can't be passed to dch` (both servers). A malformed
  payload or an unknown name still answers 0x14: dch's result is not reported.
- 0x06 rename `{"name": string, "alias": string}` → 0x14 (empty). `alias` `""` (or missing)
  clears it. Always 0x14, as kill. A name starting with `-`: `dch serve` answers 0x13 as for
  kill; Prosper answers 0x14, since it runs `dch -m <name> <alias>` and `-m` takes the next two
  arguments verbatim, so such a name is harmless there.
- Both keep this in 1.0, `dch serve` included (Q2): failure is not reported, and 0x13 is only
  for a name starting with `-` (kill on both servers, rename on `dch serve` only).

## Mac-only frames (Prosper)

Each is sent only while its op is listed and gets exactly one final reply (0x13 on any
failure, the message written for the user). For which ones allow one in flight, see
[Connections](#connections). Exception: 0x0a answers 0x14 even when Prosper could not read the
bytes as an image (see [M11](#known-gaps)); its gate is `paste_image` or a Prosper server (see
[`ops`](#ops-what-a-client-may-send)).

| Type | Name | Request | Reply | Op |
|------|------|---------|-------|----|
| 0x0a | putClipboard | raw image bytes | 0x14 (empty), after the Mac's pasteboard holds it; also when the bytes are not an image (M11) | `paste_image` (the phone sends it on the attached connection before ctrl-V) |
| 0x0b | history | empty or `{}` | 0x1b `[{name, alias?, end, last_seen, started, runtime, cwd?, command?, agent_name?, takes, pinned?}]` | `history` |
| 0x0c | revive | `{"name"}` or `{"all": true}`, plus `"no_message"?: bool` | 0x14 `{"names": [string]}` | `revive` (`revive_no_message`) |
| 0x0d | restart | `{"names": [string]}` or `{"all": true}` | 0x14 `{"names"}` | `restart` |
| 0x0e | stop | `{"names": [string]}` | 0x14 `{"names"}` | `stop` |
| 0x0f | library | empty, `{}` or `{"etag": hex}` | 0x1c `{etag, unchanged: true}` or `{etag, snippets, quicklinks, errors?}` | `library` |
| 0x24 | pin | `{"name", "pin": bool}` | 0x14 `{"names"}` | `pin` |
| 0x25 | forget | `{"name"}` | 0x14 `{"names", "message"?}` | `forget` |
| 0x26 | forgetAll | empty or `{}` | 0x14 `{cleared, skipped, failed}` | `forget` |
| 0x2c | putPhoneSnippets | `{device_id, device_name?, hash, snippets}` | 0x14 `{count, hash}` | `snippets_put` |
| 0x2d | sidekickSync | `{"pattern": string, "updated": int ms}` | 0x14 `{pattern, updated}` (the newer wins) | `sidekick` |
| 0x15 | clipboardList | `{limit?: 1-100, before?: id, since?: ISO8601}` | 0x1d `[{id, date, kind, source, size, text?, thumb?, name?}]` | `clipboard` |
| 0x16 | clipboardItem | `{id, offset?, max_side?}` | 0x1a `{id, date, kind, source, size, sha256, name?, mime?}`, 0x10 chunks (≤1 MiB), then 0x14 | `clipboard` |
| 0x17 | putClipboardText | `{"text"}` | 0x14 | `clipboard` |
| 0x22 | addClipboardHistory | `{"items": [..]}` (≤100) | 0x14 `{added, skipped}` | `clipboard` |
| 0x23 | clipboardUpload | `{id, date, kind, source: "iPhone", size, sha256, name?, mime?, live?}`, then 0x10 chunks | 0x14 `{added}` or `{skipped}` | `clipboard` |
| 0x1e | models | empty or `{}` | 0x27 `[{id, name, loaded}]` | `chat` |
| 0x1f | chat | `{model?, messages: [{role, content}], max_tokens?}` | 0x20 `{text}` deltas, then 0x21 `{stop}` | `chat` |
| 0x28 | commands | empty or `{}` | 0x2a `[{id, title, subtitle?, ext, argument?, icon?}]` | `commands` |
| 0x29 | runCommand | `{id, argument?}` | 0x2b `{text, detail?}` | `commands` |

A clipboardUpload, a chat and a watch each need a connection of their own; such a connection
never attaches. A 0x23 or 0x1f on an attached connection gets 0x13
`clipboardUpload needs its own connection` / `chat needs its own connection`.

## Golden frames

`golden/*.json` holds language-neutral fixtures for the core subset, and `golden/run.py`
(Python 3, stdlib only) runs them against `host:port`:

```
python3 docs/protocol/golden/run.py 100.x.y.z:8771             # read-only fixtures
python3 docs/protocol/golden/run.py 100.x.y.z:8771 --mutating  # also 07, 08, 12, 14, 15, 16: they run dch
```

Without `--mutating` the runner skips, and prints as SKIP, every fixture marked `mutating`:
07 (kill runs `dch -k`), 08 (rename runs `dch -m`), both on a name no session should have, and
12, 14 and 15 (each attach starts a session, `golden-776`, `golden-776-14` and `golden-776-15`,
and each cleanup kills its own; 15 ends it by typing `exit` and ^D into it), and 16 (a 0x02
create of `golden-776-16`, killed by its cleanup). Run `--mutating` only against a test server,
never a host with sessions someone uses.

15 assumes the session runs a shell (dch's default command) that reads input once it has
started: it is a smoke check of exit and close. A shell whose rc files discard type-ahead, or
stay silent past the step's 5 s, fails it falsely. 16 checks the same close without typing: a
0x02 create with `"command": ["/bin/sh", "-c", "exit 3"]`. 12, 14, 15 and 16 each start a new
session, so each needs `create` in `ops` (`requires_op`): a `dch serve` without `--allow-create`
refuses an attach to an unknown name (see [0x01 attach](#0x01-attach-0x02-create-and-the-attached-connection)),
and the runner skips all four there.

Not in the set, because the format cannot express them: the 0x12 frame before 15's and 16's close (pty
output of no fixed frame count comes first, and `expect` takes the next frame), and attach on
a watch connection (the frame between the snapshot and the 0x13 depends on a second op,
`sidekick`, and `requires_op` names one). Prosper's unit tests pin both.

It exits 0 when every fixture that applies passes. Prosper's CI runs the same files against an
in-process server with fakes for dch (`RemoteFramesGoldenTests`); that test fails with a clear
message when `docs/protocol/golden` is not beside `app/`.

### Fixture format

One JSON object per file:

| Key | Meaning |
|-----|---------|
| `id` | Name for the report. |
| `about` | What it pins. |
| `requires_op` | Run only when the server's 0x08 `ops` lists it. |
| `mutating` | Changes server state: run only with `--mutating`. |
| `cleanup` | Hex frames sent on a fresh connection after the fixture, pass or fail. |
| `steps` | In order, on one connection. |

A step is one of:
- `{"send": "<hex>"}`: these bytes, as one write. Whitespace in hex is ignored.
- `{"expect": <frame>}`: the next frame, whole within 5 s of the step's start, must match.
  The 5 s is armed again at every step, not once per connection (both runners; Prosper's
  tests pin it).
- `{"expect_close": true}`: the server closes the connection within 5 s of the step's start
  (EOF or reset). Bytes that arrive before the close are ignored, but do not extend the 5 s:
  a session that keeps drawing and never closes fails the step.
- `{"expect_quiet": <seconds>}`: for that long, no frame other than 0x10 arrives and the
  connection stays open (0x10 is pty output, which may come at any time on an attached
  connection). Pins "no reply".

A `<frame>` is `{"type": "<hex byte>"}` plus at most one of:
- `"json": <shape>`: the payload is JSON matching the shape;
- `"payload": "<hex>"`: the payload is exactly these bytes (`""` is empty);
- `"nonempty": true`: the payload has at least one byte.

Every frame received must also be within the 8 MiB send limit.

### Shapes

A shape matches by keys and types; values are fixed only where they are deterministic.

- `"string"`, `"int"`, `"number"`, `"bool"`, `"object"`, `"array"`, `"any"`. `int` is a JSON
  number with no fraction (not a bool); `number` is any JSON number.
- `"string~<regex>"`: a string the regex matches in full, to the last character: a trailing
  newline the regex does not match fails (Python's `re.fullmatch`).
- `{"key": shape, "?opt": shape}`: an object with every plain key, each `?`-prefixed key
  optional; other keys are allowed (a minor version may add them).
- `[shape]`: an array whose every element matches; `[]`: any array.

## Known gaps and open questions

Where Prosper's server, the phone and this spec do not yet line up. Nothing here changes the
rules above; each item is either a known limit of the code or a decision still open.

### Known gaps

- **M1. No general send limit.** Prosper checks the 8 MiB limit only on libraryResp and the
  clipboard frames. listResp, historyResp (thousands of pinned records), snapshotResp,
  commandsResp, modelsResp and chatDelta are sent unchecked; one over 8 MiB makes the phone
  drop the connection.
- **M2. Prosper refuses no client version.** The phone states `{"proto": "1.0"}` in 0x08 and
  `dch serve` refuses a newer major (Q1), but Prosper ignores the payload, so a newer-major
  client is answered as a 1.0 one.
- **M3. `create` advertising** (resolved, #800). Prosper lists `create` since #800; an older
  Prosper serves 0x02 without listing it, which the client rule in
  [`ops`](#ops-what-a-client-may-send) covers (`server` `"prosper"` or absent allows it).
- **M4. 0x0a's gate** (resolved, #800). 0x0a is gated on `paste_image`, which Prosper lists
  since #800, or a Prosper server (an older one lists nothing). A dch host without 0x0a lists
  no `paste_image`, so the phone hides its paste-image key there. 0x07 and 0x09 stay base
  frames in the core subset.
- **M5. kill and rename never report failure.** 0x04 and 0x06 answer an empty 0x14 even for a
  malformed request or an unknown session; only a name starting with `-` gets 0x13 (kill on
  both servers, rename on `dch serve` only: Prosper's rename answers 0x14). Kept in 1.0 for
  every server (Q2).
- **M6. The watch stream's sidekick frame.** Prosper sends `0x14 {"sidekick"}` on every stream
  (it always lists `sidekick`). This spec makes it conditional on `sidekick` in `ops`, so a dch
  server need not invent one.
- **M7. Any tailnet peer is trusted** (resolved, #777). Prosper checked only the peer's
  address, so every device on the tailnet, nodes shared into it included, could connect. Since
  #777 it runs the owner check on every connection; see
  [Decided defaults](#decided-defaults-for-dch-serve).
- **M8. `hostname` is not a DNS name on Prosper.** It carries the computer name, the same value as
  `name`. A dch server sends `gethostname()`.
- **M9. Replies can trail.** Prosper's 0x08 reply waits up to 0.25 s for a dch version probe,
  0x09 on an attached connection forks `dch --read`, and every `ops`-gated request runs off the
  connection, so a request pipelined behind one of these can be answered first. See
  [Connections](#connections).
- **M10. The bind trusts the whole 100.64.0.0/10 range.** Prosper binds the first IPv4 address
  in 100.64.0.0/10 on any interface and accepts any peer in that range. Other VPNs use the same
  CGNAT range (Cloudflare WARP's 100.96.0.0/12, NordVPN Meshnet). With one of them up, Prosper
  may bind that interface instead of Tailscale's and trust that network's peers. Prosper does
  not tell Tailscale's interface apart today.
- **M11. 0x0a answers 0x14 for bytes that are not an image.** Prosper sets the pasteboard only
  when it can read the bytes as an image, but answers an empty 0x14 either way, so a client
  cannot tell a paste that did nothing.

### Decided defaults for `dch serve`

Answers already given to the dch team, and dch's own answers to what was asked of it (the
former Q11-Q15). They are the defaults `dch serve` builds to; where Prosper differs today, the
gap above or the item says so.

- **Bind address.** `dch serve` binds one IPv4 address, port 8771:
  - by default the host's Tailscale IPv4: the first line of `tailscale ip -4` when the
    `tailscale` CLI is on `PATH`. When the CLI is on `PATH` but fails, times out or prints
    nothing (tailscaled stopped, logged out, NeedsLogin), it refuses to start ("tailscale
    reported no address"), with no fallback: an ISP's CGNAT address is in 100.64.0.0/10 too
    (dch, was Q11);
  - only when the CLI is not on `PATH`: the first IPv4 address in 100.64.0.0/10 on any
    interface, as Prosper finds it (which carries [M10](#known-gaps) over);
  - `--bind <ipv4>` overrides it and relaxes nothing: the 100.64.0.0/10 peer gate and the owner
    check still apply, so a non-tailnet bind admits nobody, and `dch serve` says so in a
    startup warning. A wildcard (`0.0.0.0`) or any other non-unicast address is refused at
    startup. A test-only loopback bypass (an explicit environment variable plus a loopback
    bind) exists for dch's CI (dch, was Q13);
  - with no address found and no `--bind`, it refuses to start (Prosper instead retries with
    backoff; the phone sees no difference: nothing listens either way);
  - when the bind fails (any error), it exits non-zero with a clear message; EADDRINUSE names
    Prosper or another `dch serve` as the likely holder. No retry loop: the service manager
    restarts it (systemd `After=`/`Wants=tailscaled.service`, `Restart=on-failure`,
    `RestartSec=5`; launchd `KeepAlive`) (dch, was Q12);
  - when `<tailscale ip>:8771` is taken (Prosper serves that Mac, say), it refuses to start;
    there is no alternate port in 1.0. Prosper, finding the port taken (by `dch serve`, say),
    keeps retrying and says so in Remote Terminal's settings ("Port 8771 on your Tailscale
    address is in use (dch serve?)"). *Pending operator confirmation*; dch agrees
    ([Q10](#open-questions)).
- Accept peers only from 100.64.0.0/10. No IPv6 in 1.0.
- **A refused peer gets no frame.** Every refusal (the address, the owner check, a tagged
  peer, whois unavailable) is decided right after accept, before a byte is read, and the
  server closes the connection: no frame is read or sent. Prosper does this for every one of
  them (`DchSessionServer.accept`: a peer `allowPeer` refuses is cancelled at once; any other
  connection is not started until the owner check answers, and is cancelled when it refuses).
  The client's connect succeeds, then it sees EOF or a reset, and a request it already sent
  gets no reply. A client cannot tell this from a dropped link.
- **The owner check** (#777) compares the peer's whois `UserProfile.ID` with the host's
  `Self.UserID`, not login names. Trust is per node: every process on an owner's device, other
  local users on an owner's Mac included, and every LAN host behind an owner's subnet router
  gets in; `dch serve` is the same. Prosper (`DchOwnerCheck`) and `dch serve` (v1.33.1) share
  these rules:
  - ask the `tailscale` CLI: `tailscale status --json --peers=false` for the host,
    `tailscale whois --json <ip>` for the peer;
  - refuse this host's own addresses (any local user or app can connect from them, and whois
    would name the host's owner) with no whois, and the host's own node when whois names it.
    Loopback is left to the address gate;
  - treat a node as tagged when it has `Tags` or its user is `tagged-devices`;
  - refuse a peer whois does not know, and one whois fails for (or answers unreadably) while
    `tailscale status` works: Tailscale is answering and cannot vouch for it;
  - refuse a whois answer with no `Node`. Once the host's node id is known, Prosper and dch
    v1.33.1 also refuse a `Node` with no `StableID` (v1.33.0 needs a numeric `Node.ID`);
  - remember a refusal Tailscale answered for 30 s, asking nothing for that address meanwhile.

  Where they differ:
  - **The host's own node.** Prosper matches status `Self.ID` with whois `Node.StableID`, as
    strings. `dch serve` v1.33.0 parses both `Self.ID` and whois `Node.ID` as digits, which only
    some self-hosted control servers give (on tailscale.com `Self.ID` is a `n...CNTRL` string); since
    v1.33.1 (dch #088) it compares `StableID` strings like Prosper.
  - **The host's state.** Prosper reads the host from `tailscale status` on every decision and
    requires `BackendState` `Running`; a host that answers anything else (`Starting` after
    wake, `NeedsLogin`, `Stopped`) is refused as answering, never relaxed, and not remembered,
    so the next connection asks again. `dch serve` reads the host owner once at startup and
    checks no `BackendState`.
  - **Which CLI.** Prosper tries `/Applications/Tailscale.app/Contents/MacOS/Tailscale` (the App
    Store and standalone apps), `/opt/homebrew/bin/tailscale`, `/usr/local/bin/tailscale`
    (Homebrew's tailscaled) and `/opt/local/bin/tailscale` (MacPorts) in that order, and uses
    the first whose status answers `Running`: an installed app with its daemon off hands over
    to a running Homebrew tailscaled. `dch serve` uses the first `tailscale` on its `PATH` (then
    `/usr/bin`, `/usr/local/bin`, `/opt/homebrew/bin`), else the app's, whether or not it answers.
  - **The bound.** Prosper bounds each decision at 2 s. A timeout before `tailscale status`
    answered counts as not answering; one after it (whois hung) is refused as answering. Prosper
    does not remember a timeout.
  - **Repeats.** Prosper also remembers an allowed owner's device for 30 s, and connections
    from an address whose check is in flight wait for that check (one whois per phone burst of
    handshake, watch and attach); `dch serve` asks again per connection.

  Prosper logs one line per cause (not per connection) and shows the last refusal in Remote
  Terminal's settings ("Couldn't verify 100.64.0.1: Tailscale isn't answering (...). Turning on
  "Allow when Tailscale isn't answering" would let it in."), cleared when an owner's device next
  connects. `dch serve --check-peer <ip>` prints the decision for one address; Prosper has no
  such dry run.
- **A tagged host**, *pending operator confirmation*. No user owns a tagged host: its
  `Self.UserID` is the tagged-devices identity. Prosper has no `--allow-user`: on a tagged host
  it refuses every peer, with "this Mac is a tagged Tailscale device, so no user owns it" in its
  settings. `dch serve` refuses to start there unless given
  `--allow-user <login or numeric user id>`, repeatable. It then accepts only peers whose
  whois user is one of those: a number is compared exactly with `UserProfile.ID`, a login with
  `UserProfile.LoginName`, ASCII case-insensitively. The docs recommend ids (dch, was Q15).
- **`--allow-user` on an untagged host** is refused at startup ("--allow-user is only for
  tagged hosts; an untagged host serves its owner") (dch, was Q14).
- **Tagged peers** are refused, with no flag to allow one in 1.0. *Pending operator
  confirmation*; dch agrees ([Q9](#open-questions)).
- **Whois unavailable** (tailscaled down or its LocalAPI unreachable), *pending operator
  confirmation*: fail closed by default, so the peer is refused as above and `dch serve` logs a
  line. `--whois-optional` relaxes only Tailscale not answering (whois and status both fail):
  that peer is accepted and a warning is logged. It never relaxes a whois failure while status
  works, nor startup: `dch serve` always needs the host owner (`Self.UserID`) when it starts,
  and refuses to start without it. Prosper's equivalent is the setting "Allow when Tailscale
  isn't answering" (off by default; key `remoteAllowWhenTailscaleDown`): it covers no CLI
  installed, every CLI failing to start or to reach tailscaled, and the 2 s bound passing
  before `tailscale status` answered. While it is on and Tailscale isn't answering, any peer
  that passed the address gate gets in unverified, another user's or a tagged one included.
  Prosper has no startup check: it asks for the host owner per decision, so the same setting
  covers it.

### Open questions

| Id | Question | Asked of |
|----|----------|----------|
| Q1 | Should clients send `{"proto": "1.0"}` in the 0x08 request, so a server can refuse a newer major with 0x13 (Prosper ignores the payload today, so this is compatible)? (M2) **Answered: yes.** `dch serve` accepts `{"proto": "1.0"}` and answers 0x13 to a newer major; the phone sends `{"proto": "1.0"}` since TestFlight build 162; see [Versioning](#versioning). | dch, prosper-ios |
| Q2 | Should `dch serve` keep kill and rename's empty 0x14, or answer 0x13 on failure (fixtures 07 and 08 would then allow either)? (M5) **Answered: keep the empty 0x14** in 1.0 (0x13 only for a name starting with `-`); see [0x04 kill, 0x06 rename](#0x04-kill-0x06-rename). | dch |
| Q3 | Should Prosper list `create` in `ops`, so the phone gates 0x02 the same way on every server? (M3) **Answered: yes** (#800); see [`ops`](#ops-what-a-client-may-send). | Prosper, prosper-ios |
| Q4 | May `dch serve` answer 0x09 with an empty 0x19 when it has no screen read to offer? **Answered:** it answers from dch's VT mirror (as `dch --read --ansi`) with the caret appended; an empty 0x19 only when it has no screen to offer (for example no mirror in a lite build, or a connection that has not attached; Prosper also for an attached nameless create or a failed `dch --read`); never 0x13 (a frame-too-large 0x13 aside). See [0x01 attach, 0x02 create](#0x01-attach-0x02-create-and-the-attached-connection). | dch |
| Q5 | The phone ignores `proto` today. It should refuse a host whose major is above 1. **Answered:** it does since TestFlight build 162; see [Versioning](#versioning). | prosper-ios |
| Q6 | Gate the phone's paste-image (0x0a) on an op, since a dch host has no Mac clipboard? (M4) **Resolved** (#800): on `paste_image`, or a Prosper server; see [`ops`](#ops-what-a-client-may-send). | prosper-ios |
| Q7 | Gate "new session" on `create` for `server: "dch"` until Q3 is settled? (M3) **Resolved** (#800): on `create`, or a Prosper server; see [`ops`](#ops-what-a-client-may-send). | prosper-ios |
| Q8 | The phone's 0x2e client is not on its main branch yet: confirm it sends `{"device_id"}`. **Answered: yes** (prosper-ios confirmed); see [0x2e watch](#0x2e-watch-gate-watch). | prosper-ios |
| Q9 | How does a `dch serve` operator allow a tagged peer node (a flag naming tags, or none in 1.0)? Working default, *pending operator confirmation*: tagged peers are refused in 1.0, no flag; dch agrees. | dch, operator |
| Q10 | Prosper and `dch serve` on the same Mac both want `<tailscale ip>:8771`; the second bind fails. Should `dch serve` take another port there, and how would the phone find it? Working default, *pending operator confirmation*: `dch serve` refuses to start when `<tailscale ip>:8771` is taken ("Prosper already serves this Mac"); no alternate port in 1.0; dch agrees. | dch, prosper-ios |
