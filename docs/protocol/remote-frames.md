# Remote frames protocol, version 1.0

This is the wire contract between a remote-terminal **server** (Prosper's `DchSessionServer`
today, `dch serve` later) and its **clients** (the Prosper iPhone app, `dch` as a client). It
describes what Prosper's server does as of v2.174.0 (#776: the 0x08 keys `server`, `os`,
`name` and `proto`, and this document). The code is in
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
- A server must never bind a wider address than its Tailscale one. See
  [Decided defaults](#decided-defaults-for-dch-serve) for the rules `dch serve` follows.

## Versioning

- The server states its version in the 0x08 reply as `proto`: `"<major>.<minor>"`, decimal.
  This document is `1.0`.
- A minor bump only adds: new optional keys, new frames, new `ops` names. A client ignores
  keys and `ops` it does not know.
- A major bump breaks. A client that reads a newer major than its own refuses the host
  (shows it as unsupported and sends nothing else). A 0x08 reply with no `proto` is a
  pre-#776 Prosper, which is 1.0.
- The client sends no version today (the 0x08 request payload is empty and ignored), so a
  server has nothing to refuse on yet. See [Known gaps and open questions](#known-gaps-and-open-questions) (M2, Q1).

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

## Connections

- **One operation per connection.** A request/reply verb gets its reply and the client closes.
  An attach, a create and a watch own their connection for its life.
- **Replies are matched by type, not by order.** Requests may be pipelined on one connection,
  but a client must not assume replies come back in the order it sent the requests:
  - Prosper answers 0x03, 0x04, 0x06, and 0x09 on a connection that has not attached at once,
    in the order they arrive.
  - These replies can trail replies to frames sent after them: 0x08 (Prosper waits up to
    0.25 s for a dch version probe), 0x09 on an attached connection (it reads dch's screen
    off the connection), and every `ops`-gated request (Mac-only frames run off the
    connection too).
  - Kill and rename both answer an empty 0x14, so a client that pipelines them tells the
    replies apart only by that arrival order. The phone sends one request per connection.
- **One in flight.** These Mac-only requests allow one in flight per connection: 0x0b-0x0f,
  0x15, 0x16, 0x1e, 0x1f, 0x22-0x26, 0x28, 0x29, 0x2c, 0x2d. Another of them while one is in
  flight gets `0x13 {"message": "busy with an earlier request"}` at once, ahead of the first
  one's reply. The others are never refused as busy:
  - the base frames, 0x0a putClipboard and 0x17 putClipboardText are answered even while a
    request is in flight;
  - a second 0x2e on a connection that is already watching is ignored (no reply);
  - a 0x2e on a connection that attached, chatted, uploaded or has a request in flight gets
    `0x13 {"message": "watch needs its own connection"}`.
- **Unknown frame types are ignored**: no reply, the connection stays open. A client tells an
  old server by a missing reply (the phone gives 0x08 two seconds).
- Everything malformed is a 0x13 reply, or for the base frames, as listed, except a length
  over the receive guard, which closes.
- **When Prosper closes a connection.** A client must expect a close at any time. Only 0x12
  exit means the session ended; every other close is a refusal or a dropped link. Prosper
  closes:
  - on a length prefix over the receive guard (0x13 `frame too large` first);
  - after 0x12 exit (the FIN follows the frame);
  - when an attach or create fails to spawn (0x13 first, see below);
  - when another connection attaches to the same session (the newest wins; no frame);
  - when an attached session's output has not been taken by the socket for 20 s;
  - when a 0x16 data chunk has not been taken by the socket for 60 s;
  - on a watch stream: a fifth stream of the same device, 32 frames unsent, or the server
    losing its list;
  - during a 0x23 clipboardUpload, when the Mac's user cancels the incoming item;
  - when the server stops (Remote Terminal turned off; a failed listener alone closes no
    connection);
  - at once, for a peer outside 100.64.0.0/10 (no frame is read or sent).

## Replies every frame shares

| Type | Name | Payload |
|------|------|---------|
| 0x13 | error | `{"message": string}`: one line, shown to the user as written. |
| 0x14 | ok | Empty for kill, rename, putClipboard; a JSON object where the frame says so. A client accepts both. |

## `ops`: what a client may send

0x08's reply carries `ops`, an array of strings. The **base frames** (0x01-0x0a, 0x10) are
not in `ops`: a server that answers 0x08 serves them. Every other request is sent **only when
its op is listed**, so a server answers exactly what it advertises and need not answer the
rest. Prosper's ops and their frames:

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
| `create` | 0x02 (dch serve only, with `--allow-create`) | never: Prosper serves 0x02 unlisted (see [M3](#known-gaps-and-open-questions)) |

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
| 0x02 | create | C→S | yes | base on Prosper; `create` on dch |
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
| 0x0a | putClipboard | C→S | no (Mac) | base, sent ungated by the phone |
| 0x0b-0x0f, 0x15-0x17, 0x1a-0x1f, 0x20-0x2d | see below | | no (Mac) | per `ops` |

## Core frames

### 0x08 machineInfo → 0x18 machineInfoResp

Request: empty (any payload is ignored). Reply: one 0x18, never an error.

| Key | Type | Required | Meaning |
|-----|------|----------|---------|
| `device_id` | string | **yes** | Stable id of the host. Without it the phone's `decodeMachineInfo` returns nil and treats the host as a legacy Mac with no ops. Prosper: lowercase hex SHA-256 of the host UUID. dch: hash of `/etc/machine-id`, or a UUID kept in its state dir. **Never derived from an IP.** |
| `hostname` | string | yes | The host's name for display. Prosper sends the computer name (`Host.current().localizedName`); dch sends `gethostname()`. |
| `ops` | [string] | yes | See [`ops`](#ops-what-a-client-may-send). Unknown names are ignored. |
| `server` | string | yes (1.0) | `"prosper"` or `"dch"`. |
| `os` | string | yes (1.0) | Human-readable OS and version: `"macOS 27.0"`, `"Linux 6.8"`. |
| `name` | string | yes (1.0) | Display name. Prosper: the computer name (equal to `hostname`). |
| `proto` | string | yes (1.0) | `"1.0"`. See [Versioning](#versioning). |
| `wakeId` | string | no | Prosper's remote-wake id, only while remote wake is set up. **A dch server leaves it absent.** |

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

Request: empty, `{}` or `{"device_id": string}`. Prosper keys streams by `device_id`, else by
the peer's address.

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
- 0x01 attach: `{"name": string, "cols": int, "rows": int}`. dch's `-n` is attach-or-create:
  an attach to a session whose master is gone starts it again.
- 0x02 create: `{"name"?: string, "command": [string], "cols": int, "rows": int}`. No name: dch
  picks one. `command` empty: the default shell.
- `cols`/`rows` default to 80×24 when missing.

The connection then carries one session:
- **Redraw on attach.** The server's first 0x10 bytes are a full repaint of the session's
  screen. Prosper gets this by spawning a real `dch -E -f -n <name>` client in a pty, so the
  master repaints for the new client. `dch serve` must send the same repaint on attach.
- 0x10 data, client to server: raw bytes for the session's input (keys, pastes).
- 0x10 data, server to client: raw pty output.
- 0x05 resize `{"cols": int, "rows": int}`: the session's window size (80×24 for a missing key).
  No reply.
- 0x07 redraw (empty): force a repaint (Prosper shrinks the pty a row and restores it). No reply.
- 0x09 snapshot (empty) → 0x19 snapshotResp: raw ANSI of the session's current screen from
  dch's VT mirror, with the caret appended as `ESC[row;colH` when known. **Empty = no mirror**
  (and always empty on a connection that has not attached); the client keeps what it has.
- 0x12 exit `{"code": int}`: the session's client exited; the server then closes (the FIN
  follows the frame).
- The client detaches by closing the TCP connection. The session lives on.
- One client per session: the newest attach to a session retires the server's older
  connections attached to it (Prosper).
- A second attach or create on the same connection is ignored. Attach or create on a
  watch, chat or clipboardUpload connection: 0x13 `"<kind> connections cannot attach or create"`.
- A failed spawn (Prosper: `forkpty` fails, the Mac is out of ptys or processes): 0x13
  `{"message": "Could not start the session: ..."}`, then close; the 0x13 is sent as the last
  frame before the FIN. Frames the client sent after the attach on that connection are
  discarded.
- 0x10 on a connection with no session (and no upload) is dropped.

### 0x04 kill, 0x06 rename

- 0x04 kill `{"name": string}` → 0x14 (empty). Ends the session (`dch -k`). A name starting
  with `-` → 0x13 `a session name starting with - can't be passed to dch`. A malformed
  payload or an unknown name still answers 0x14: dch's result is not reported.
- 0x06 rename `{"name": string, "alias": string}` → 0x14 (empty). `alias` `""` (or missing)
  clears it. Always 0x14, as kill.

## Mac-only frames (Prosper)

Each is sent only while its op is listed and gets exactly one final reply (0x13 on any
failure, the message written for the user). For which ones allow one in flight, see
[Connections](#connections). Exception: 0x0a is not gated and answers 0x14 even when Prosper
could not read the bytes as an image (see [M11](#known-gaps)).

| Type | Name | Request | Reply | Op |
|------|------|---------|-------|----|
| 0x0a | putClipboard | raw image bytes | 0x14 (empty), after the Mac's pasteboard holds it; also when the bytes are not an image (M11) | none (phone sends it on the attached connection before ctrl-V) |
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
python3 docs/protocol/golden/run.py 100.x.y.z:8771 --mutating  # also 07, 08 and 12, which run dch
```

Without `--mutating` the runner skips, and prints as SKIP, every fixture marked `mutating`:
07 (kill runs `dch -k`), 08 (rename runs `dch -m`), both on a name no session should have, and
12 (attach starts a session `golden-776`, then its cleanup kills it). Run `--mutating` only
against a test server, never a host with sessions someone uses.

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
- `{"expect": <frame>}`: the next frame, within 5 s, must match.
- `{"expect_close": true}`: the server closes the connection within 5 s (EOF or reset). Bytes
  that arrive before the close are ignored.
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
- **M2. Version refusal is one-sided.** The 0x08 request carries no version, so only the client
  can refuse a newer major. A server cannot refuse a newer client.
- **M3. `create` is not advertised by Prosper.** Prosper always serves 0x02 but never lists
  `create` in `ops`; `dch serve` lists it only with `--allow-create`. A client cannot gate
  create on `ops` alone across both servers yet.
- **M4. The phone sends 0x0a, 0x07 and 0x09 without an `ops` gate.** They are base frames.
  0x07 and 0x09 are in the core subset; 0x0a (paste an image into the Mac's clipboard) has no
  meaning on a dch host, which leaves the phone's paste-image key doing nothing there.
- **M5. kill and rename never report failure.** 0x04 and 0x06 answer an empty 0x14 even for a
  malformed request or an unknown session; only a name starting with `-` gets 0x13.
- **M6. The watch stream's sidekick frame.** Prosper sends `0x14 {"sidekick"}` on every stream
  (it always lists `sidekick`). This spec makes it conditional on `sidekick` in `ops`, so a dch
  server need not invent one.
- **M7. Any tailnet peer is trusted.** Prosper checks the peer's address (IPv4 in
  100.64.0.0/10; IPv6 is refused), not who it is: every device on the tailnet, including
  nodes shared into it, can connect. The owner check (#777, Tailscale whois per connection)
  closes this; see [Decided defaults](#decided-defaults-for-dch-serve).
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

Answers already given to the dch team. They are the defaults `dch serve` builds to; where
Prosper differs today, the gap above says so.

- Bind the host's Tailscale IPv4 address only. Without one, refuse to start.
- Accept peers only from 100.64.0.0/10.
- No IPv6 in 1.0.
- The owner check (#777) compares the whois `UserProfile.ID` of the peer with the host's
  `Self.UserID`, not login names.
- Tagged nodes are refused unless explicitly allowed.
- Whois unavailable: fail closed and log a line, behind a flag. This default may still change.

### Open questions

| Id | Question | Asked of |
|----|----------|----------|
| Q1 | Should clients send `{"proto": "1.0"}` in the 0x08 request, so a server can refuse a newer major with 0x13 (Prosper ignores the payload today, so this is compatible)? (M2) | dch, prosper-ios |
| Q2 | Should `dch serve` keep kill and rename's empty 0x14, or answer 0x13 on failure (fixtures 07 and 08 would then allow either)? (M5) | dch |
| Q3 | Should Prosper list `create` in `ops`, so the phone gates 0x02 the same way on every server? (M3) | Prosper, prosper-ios |
| Q4 | May `dch serve` answer 0x09 with an empty 0x19 when it has no screen read to offer? | dch |
| Q5 | The phone ignores `proto` today. It should refuse a host whose major is above 1. | prosper-ios |
| Q6 | Gate the phone's paste-image (0x0a) on an op, since a dch host has no Mac clipboard? (M4) | prosper-ios |
| Q7 | Gate "new session" on `create` for `server: "dch"` until Q3 is settled? (M3) | prosper-ios |
| Q8 | The phone's 0x2e client is not on its main branch yet: confirm it sends `{"device_id"}`. | prosper-ios |
