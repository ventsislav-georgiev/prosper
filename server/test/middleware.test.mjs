import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { stripTypeScriptTypes } from "node:module";
import { DatabaseSync } from "node:sqlite";
import { postSessions } from "../src/pushStore.mjs";

// #1089. node 24 strips types but cannot resolve middleware.ts's extensionless "./util":
// strip the types here, point that import at util.ts, and load the real file from a data: URL.
const mwSrc = readFileSync(new URL("../src/middleware.ts", import.meta.url), "utf8");
const utilUrl = new URL("../src/util.ts", import.meta.url).href;
const js = stripTypeScriptTypes(mwSrc, { mode: "strip" }).replace('"./util"', JSON.stringify(utilUrl));
assert.ok(js.includes(utilUrl), "the util import was rewritten");
const { requireSession } = await import(`data:text/javascript;base64,${Buffer.from(js).toString("base64")}`);

const TOKEN = "fake-session-token";
const HASH = createHash("sha256").update(TOKEN).digest("hex");
const EMAIL = "alice@example.com";
const MAC = "a".repeat(64);
const now = () => Math.floor(Date.now() / 1000);

// A D1 stand-in over node:sqlite that records the rows each write statement changed.
function world({ lastSeen, expiresAt = null }) {
  const raw = new DatabaseSync(":memory:");
  for (const f of ["0001_init.sql", "0006_push.sql", "0007_push_harden.sql", "0008_push_mode.sql", "0009_push_kind_index.sql", "0010_sessions_expires_index.sql"]) {
    raw.exec(readFileSync(new URL(`../migrations/${f}`, import.meta.url), "utf8"));
  }
  raw.prepare(`INSERT INTO devices VALUES (?, ?, ?, 0, 0)`).run(EMAIL, MAC, "Studio");
  raw.prepare(`INSERT INTO sessions VALUES (?, ?, 0, ?, ?)`).run(HASH, EMAIL, lastSeen, expiresAt);
  const writes = []; // [statement head, rows changed]
  const make = (sql, args = []) => ({
    bind: (...a) => make(sql, a),
    first: async () => raw.prepare(sql).get(...args) ?? null,
    all: async () => ({ results: raw.prepare(sql).all(...args) }),
    run: async () => {
      const changes = Number(raw.prepare(sql).run(...args).changes);
      writes.push([sql.trim().split(/\s+/).slice(0, 3).join(" "), changes]);
      return { meta: { changes } };
    },
  });
  const db = { prepare: (sql) => make(sql) };
  const lastSeenNow = () => raw.prepare(`SELECT last_seen FROM sessions WHERE token_hash = ?`).get(HASH).last_seen;
  return { raw, db, writes, lastSeenNow };
}

// One request through the real requireSession; returns the response status (200 = next ran).
async function request(w, token = TOKEN) {
  const waits = [];
  let out = 200;
  const c = {
    req: { header: (n) => (n === "Authorization" ? `Bearer ${token}` : undefined) },
    env: { DB: w.db },
    executionCtx: { waitUntil: (p) => waits.push(p) },
    set: () => {},
    json: (_b, status) => ((out = status), status),
  };
  await requireSession(c, async () => {});
  await Promise.all(waits);
  return out;
}

const writeRows = (w, head) => w.writes.filter(([h]) => h.startsWith(head)).reduce((n, [, r]) => n + r, 0);

test("#1089: a session seen within the hour writes no row; a stale one is refreshed once", async () => {
  const fresh = world({ lastSeen: now() - 3599 });
  const before = fresh.lastSeenNow();
  assert.equal(await request(fresh), 200);
  assert.equal(writeRows(fresh, "UPDATE sessions"), 0);
  assert.equal(fresh.lastSeenNow(), before, "last_seen untouched");

  const stale = world({ lastSeen: now() - 3601 });
  assert.equal(await request(stale), 200);
  assert.equal(writeRows(stale, "UPDATE sessions"), 1);
  assert.ok(now() - stale.lastSeenNow() <= 2, "last_seen is now");
  assert.equal(await request(stale), 200); // the next request is fresh again
  assert.equal(writeRows(stale, "UPDATE sessions"), 1, "no second write");
});

test("#1089: session expiry is unchanged: an expired or unknown token is 401 and writes nothing", async () => {
  const expired = world({ lastSeen: 0, expiresAt: now() - 1 });
  assert.equal(await request(expired), 401);
  assert.equal(await request(world({ lastSeen: 0 }), "some-other-token"), 401);
  assert.equal(expired.writes.length, 0);
  const live = world({ lastSeen: 0, expiresAt: now() + 60 });
  assert.equal(await request(live), 200);
  assert.equal(writeRows(live, "UPDATE sessions"), 1, "an unexpired session is refreshed as before");
});

test("#1089: rows written by one plain heartbeat: 1 now (the Mac's push_macs row), was 2 with the session UPDATE", async () => {
  const w = world({ lastSeen: now() }); // seen just now: the common heartbeat
  const deps = { db: w.db, send: async () => ({ ok: true }), now, defer: () => {} };
  const post = (seq) => postSessions(deps, EMAIL, { mac_id: MAC, seq, sessions: [{ name: "api", state: "working" }] });
  assert.equal((await post(1)).status, 204); // first post: creates the row (an edge)
  w.writes.length = 0;
  assert.equal(await request(w), 200);
  assert.equal((await post(2)).status, 204); // heartbeat: same sessions, next seq
  const total = w.writes.reduce((n, [, r]) => n + r, 0);
  assert.deepEqual(w.writes, [["UPDATE sessions SET", 0], ["INSERT INTO push_macs", 1]], "the session UPDATE matched nothing");
  assert.equal(total, 1);
  // The same heartbeat under the old UPDATE (no WHERE on last_seen) wrote one more.
  assert.equal(w.raw.prepare(`UPDATE sessions SET last_seen = ?1 WHERE token_hash = ?2`).run(now(), HASH).changes, 1);
});
