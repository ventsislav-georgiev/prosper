-- Tests for the base64 extension. Run via scripts/test-extensions.sh.
-- Live transforms b64_encode/b64_decode + the base64_open window command.

local h = require("harness")
local host, env = h.makeHost{}
local G = h.load(h.dir() .. "init.lua", host)

-- ── Encode / decode parity with Foundation ───────────────────────────────────
h.eq(G.b64_encode("hello"), "aGVsbG8=", "encode hello")
h.eq(G.b64_encode(""), "", "encode empty")
h.eq(G.b64_encode("Man"), "TWFu", "encode 3 bytes (no padding)")
h.eq(G.b64_decode("aGVsbG8="), "hello", "decode hello")
h.eq(G.b64_decode(""), "", "decode empty")

-- Round-trip.
h.eq(G.b64_decode(G.b64_encode("Prosper 🚀")), "Prosper 🚀", "utf8 round-trip")

-- Invalid Base64 → "" (pane stays empty mid-typing), not a sentinel.
h.eq(G.b64_decode("not base64!"), "", "illegal chars decode to empty")
h.eq(G.b64_decode("aGVsbG8"), "", "bad length decodes to empty")
h.eq(G.b64_encode(nil), "", "nil encodes to empty")
h.eq(G.b64_decode(nil), "", "nil decodes to empty")

-- ── base64_open launches a live converter window ─────────────────────────────
G.base64_open("base64 hello")
h.eq(env.window.kind, "converter", "opens a converter window")
h.eq(env.window.left.value, "hello", "left pane seeded with the arg")
h.eq(env.window.right.value, "aGVsbG8=", "right pane derived from the arg")
h.eq(env.window.forward, "b64_encode", "left→right transform wired")
h.eq(env.window.backward, "b64_decode", "right→left transform wired")

-- A bare verb opens an empty window.
env.window = nil
G.base64_open("b64")
h.eq(env.window.left.value, "", "bare verb → empty left pane")
h.eq(env.window.right.value, "", "bare verb → empty right pane")

print("ok base64")
