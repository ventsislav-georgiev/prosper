import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { sendApns } from "../src/pushLogic.mjs";
import {
  putToken,
  deleteTokens,
  postSessions,
  runCron,
  purgeMacStatements,
  purgeAccountStatements,
} from "../src/pushStore.mjs";

// A D1 stand-in over node:sqlite, so the real SQL and migrations run. APNs is a fake
// fetch behind the real sendApns: nothing leaves the process.
function d1(db) {
  const make = (sql, args = []) => ({
    bind: (...a) => make(sql, a),
    first: async () => {
      const r = db.prepare(sql).get(...args);
      return r ? { ...r } : null;
    },
    all: async () => ({ results: db.prepare(sql).all(...args).map((r) => ({ ...r })) }),
    run: async () => ({ meta: { changes: Number(db.prepare(sql).run(...args).changes) } }),
    runSync: () => ({ meta: { changes: Number(db.prepare(sql).run(...args).changes) } }),
  });
  return {
    prepare: (sql) => make(sql),
    batch: async (stmts) => {
      db.exec("BEGIN");
      try {
        const out = stmts.map((s) => s.runSync());
        db.exec("COMMIT");
        return out;
      } catch (e) {
        db.exec("ROLLBACK");
        throw e;
      }
    },
  };
}

const ALICE = "alice@example.com";
const BOB = "bob@example.com";
const MAC = "a".repeat(64);
const BOB_MAC = "b".repeat(64);
const PHONE = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";
const PHONE2 = "9C2D4E11-0000-4000-8000-000000000002";
const tok = (c) => c.repeat(64);
const T0 = 1_800_000_000;

function setup() {
  const raw = new DatabaseSync(":memory:");
  for (const f of ["0001_init.sql", "0006_push.sql"]) {
    raw.exec(readFileSync(new URL(`../migrations/${f}`, import.meta.url), "utf8"));
  }
  raw.prepare(`INSERT INTO devices VALUES (?, ?, ?, 0, 0)`).run(ALICE, MAC, "Studio");
  raw.prepare(`INSERT INTO devices VALUES (?, ?, ?, 0, 0)`).run(BOB, BOB_MAC, "Bob's Mac");
  const clock = { now: T0 };
  const answers = new Map(); // token -> {status, reason}
  const calls = [];
  const fetchFn = async (url, init) => {
    const token = url.split("/").pop();
    calls.push({ url, token, headers: init.headers, body: JSON.parse(init.body) });
    const a = answers.get(token) ?? { status: 200 };
    return new Response(a.status === 200 ? null : JSON.stringify({ reason: a.reason }), { status: a.status });
  };
  const pending = [];
  const deps = {
    db: d1(raw),
    send: (p) => sendApns(fetchFn, { jwt: "test-jwt", topic: "eu.illegible.prosperios" }, p),
    now: () => clock.now,
    defer: (p) => pending.push(p),
  };
  const settle = async () => {
    while (pending.length) await pending.shift();
  };
  const rows = (sql, ...a) => raw.prepare(sql).all(...a).map((r) => ({ ...r }));
  const takeCalls = () => calls.splice(0);
  return { raw, deps, clock, answers, settle, rows, takeCalls };
}

const sessions = (seq, list) => ({ mac_id: MAC, seq, sessions: list });
const S = (name, state, extra = {}) => ({ name, state, ...extra });

async function registerPhone(t, device = PHONE, c = "1") {
  assert.equal((await putToken(t.deps, ALICE, { device_id: device, kind: "alert", token: tok(c), env: "production" })).status, 204);
  assert.equal(
    (await putToken(t.deps, ALICE, { device_id: device, kind: "la_start", token: tok(String(Number(c) + 1)), env: "production" })).status,
    204,
  );
}

// ---- tokens -----------------------------------------------------------------

test("tokens: a phone install id needs no devices row; re-post replaces", async () => {
  const t = setup();
  const r = await putToken(t.deps, ALICE, { device_id: PHONE, kind: "alert", token: tok("1"), env: "production" });
  assert.equal(r.status, 204);
  await putToken(t.deps, ALICE, { device_id: PHONE, kind: "alert", token: tok("2"), env: "sandbox" });
  const got = t.rows(`SELECT email, device_id, kind, activity_id, token, env FROM push_tokens`);
  assert.deepEqual(got, [{ email: ALICE, device_id: PHONE, kind: "alert", activity_id: "", token: tok("2"), env: "sandbox" }]);
  assert.equal((await putToken(t.deps, ALICE, { device_id: "x", kind: "alert", token: tok("1"), env: "production" })).status, 400);
  assert.equal((await putToken(t.deps, ALICE, null)).status, 400);
});

test("tokens: la_update with a foreign or unknown mac_id is 403", async () => {
  const t = setup();
  const body = (mac_id) => ({ device_id: PHONE, kind: "la_update", token: tok("3"), env: "production", activity_id: "act-1", mac_id });
  assert.deepEqual(await putToken(t.deps, ALICE, body(BOB_MAC)), { status: 403, error: "forbidden" });
  assert.equal((await putToken(t.deps, ALICE, body("c".repeat(64)))).status, 403);
  assert.equal(t.rows(`SELECT * FROM push_tokens`).length, 0);
  assert.equal((await putToken(t.deps, ALICE, body(MAC))).status, 204);
  assert.equal((await putToken(t.deps, BOB, body(MAC))).status, 403, "Bob cannot watch Alice's Mac");
});

test("tokens: a newer activity replaces the phone's older card token for the same Mac", async () => {
  const t = setup();
  const la = (activity_id, c) => ({ device_id: PHONE, kind: "la_update", token: tok(c), env: "production", activity_id, mac_id: MAC });
  await postSessions(t.deps, ALICE, { mac_id: MAC, seq: 1 }); // online, or the card is ended at once
  await putToken(t.deps, ALICE, la("act-1", "3"));
  await putToken(t.deps, ALICE, la("act-2", "4"));
  await t.settle();
  assert.deepEqual(
    t.rows(`SELECT activity_id, token FROM push_tokens WHERE kind = 'la_update'`),
    [{ activity_id: "act-2", token: tok("4") }],
  );
  const born = t.rows(`SELECT created_at FROM push_tokens WHERE kind = 'la_update'`)[0].created_at;
  t.clock.now += 3600;
  await putToken(t.deps, ALICE, la("act-2", "5")); // token rotation, same activity
  await t.settle();
  assert.deepEqual(t.rows(`SELECT token, created_at, updated_at FROM push_tokens WHERE kind = 'la_update'`), [
    { token: tok("5"), created_at: born, updated_at: t.clock.now },
  ]);
});

test("DELETE tokens: by activity, by kind, or every token of the phone; never another account", async () => {
  const t = setup();
  await registerPhone(t);
  await putToken(t.deps, BOB, { device_id: PHONE, kind: "alert", token: tok("9"), env: "production" });
  assert.equal((await deleteTokens(t.deps, ALICE, { device_id: PHONE, kind: "la_start" })).status, 204);
  assert.deepEqual(t.rows(`SELECT email, kind FROM push_tokens ORDER BY email`), [
    { email: ALICE, kind: "alert" },
    { email: BOB, kind: "alert" },
  ]);
  await deleteTokens(t.deps, ALICE, { device_id: PHONE });
  assert.deepEqual(t.rows(`SELECT email FROM push_tokens`), [{ email: BOB }]);
  assert.equal((await deleteTokens(t.deps, ALICE, { device_id: "bad" })).status, 400);
});

// ---- sessions ---------------------------------------------------------------

test("sessions: 403 for a Mac that is not an activated device of the account", async () => {
  const t = setup();
  assert.deepEqual(await postSessions(t.deps, ALICE, { mac_id: BOB_MAC, seq: 1, sessions: [] }), {
    status: 403,
    error: "forbidden",
  });
  assert.equal((await postSessions(t.deps, ALICE, { mac_id: "c".repeat(64), seq: 1 })).status, 403);
  assert.equal(t.rows(`SELECT * FROM push_macs`).length, 0);
  assert.equal((await postSessions(t.deps, ALICE, { mac_id: MAC, seq: 1 })).status, 204);
});

test("sessions: 400 on a bad body, including the 20-session cap", async () => {
  const t = setup();
  const many = Array.from({ length: 21 }, (_, i) => S(`s${i}`, "idle"));
  assert.deepEqual(await postSessions(t.deps, ALICE, sessions(1, many)), { status: 400, error: "too_many_sessions" });
  assert.equal((await postSessions(t.deps, ALICE, sessions(1, [S("a", "busy")]))).status, 400);
  assert.equal((await postSessions(t.deps, ALICE, null)).status, 400);
});

test("sessions: a stale seq changes nothing", async () => {
  const t = setup();
  await postSessions(t.deps, ALICE, sessions(200, [S("a", "working")]));
  await postSessions(t.deps, ALICE, sessions(200, [S("a", "idle")]));
  await postSessions(t.deps, ALICE, sessions(150, [S("a", "idle")]));
  assert.deepEqual(t.rows(`SELECT seq, snapshot FROM push_macs`), [{ seq: 200, snapshot: JSON.stringify([S("a", "working")]) }]);
});

test("sessions: 60 posts per Mac per minute, then 429", async () => {
  const t = setup();
  t.clock.now = 1_800_000_040; // 20 s left in this minute window
  for (let i = 1; i <= 60; i++) assert.equal((await postSessions(t.deps, ALICE, { mac_id: MAC, seq: i })).status, 204, `#${i}`);
  assert.deepEqual(await postSessions(t.deps, ALICE, { mac_id: MAC, seq: 61 }), { status: 429, error: "rate_limited" });
  t.clock.now += 20; // next minute
  assert.equal((await postSessions(t.deps, ALICE, { mac_id: MAC, seq: 62 })).status, 204);
});

// ---- end to end -------------------------------------------------------------

test("flow: start edge -> push-to-start; card token -> catch-up; blocked -> priority 10 + alert", async () => {
  const t = setup();
  await registerPhone(t);
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "idle")]));
  await t.settle();
  assert.deepEqual(t.takeCalls(), [], "idle only: nothing");

  t.clock.now += 10;
  await postSessions(t.deps, ALICE, sessions(2, [S("a", "working")]));
  await t.settle();
  let calls = t.takeCalls();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].token, tok("2"), "push-to-start token");
  assert.equal(calls[0].headers["apns-topic"], "eu.illegible.prosperios.push-type.liveactivity");
  assert.equal(calls[0].headers["apns-push-type"], "liveactivity");
  assert.equal(calls[0].headers["apns-priority"], "5");
  assert.equal(calls[0].body.aps.event, "start");
  assert.equal(calls[0].body.aps.timestamp, t.clock.now);
  assert.equal(calls[0].body.aps["stale-date"], t.clock.now + 900);
  assert.deepEqual(calls[0].body.aps.attributes, { mac_id: MAC, mac_name: "Studio" });
  assert.deepEqual(calls[0].body.aps["content-state"].counts, { blocked: 0, working: 1, idle: 0, done: 0 });

  // The phone registers the card's update token: it is caught up at once.
  t.clock.now += 5;
  await postSessions(t.deps, ALICE, sessions(3, [S("a", "working"), S("b", "idle")]));
  await putToken(t.deps, ALICE, { device_id: PHONE, kind: "la_update", token: tok("3"), env: "production", activity_id: "act-1", mac_id: MAC });
  await t.settle();
  calls = t.takeCalls();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].token, tok("3"));
  assert.equal(calls[0].body.aps.event, "update");
  assert.equal(calls[0].body.aps["content-state"].counts.idle, 1, "the current state, not the start one");

  // A session enters blocked: urgent card update + one loud alert, no new start.
  t.clock.now += 70;
  await postSessions(t.deps, ALICE, sessions(4, [S("a", "working"), S("b", "blocked", { alias: "Fix it" })]));
  await t.settle();
  calls = t.takeCalls();
  const update = calls.find((c) => c.token === tok("3"));
  const alert = calls.find((c) => c.token === tok("1"));
  assert.equal(calls.length, 2, "a phone with a card gets no push-to-start");
  assert.equal(update.headers["apns-priority"], "10");
  assert.equal(update.body.aps.event, "update");
  assert.equal(alert.headers["apns-push-type"], "alert");
  assert.equal(alert.headers["apns-topic"], "eu.illegible.prosperios");
  assert.equal(alert.headers["apns-priority"], "10");
  assert.match(alert.headers["apns-collapse-id"], /^[0-9a-f]{32}$/);
  assert.deepEqual(alert.body, {
    aps: { alert: { title: "Studio", body: "Fix it needs you" }, sound: "default", "thread-id": MAC },
    mac_id: MAC,
    session: "b",
  });
});

test("flow: a second phone without a card still gets push-to-start", async () => {
  const t = setup();
  await registerPhone(t, PHONE, "1");
  await registerPhone(t, PHONE2, "5");
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "idle")]));
  await putToken(t.deps, ALICE, { device_id: PHONE, kind: "la_update", token: tok("3"), env: "production", activity_id: "act-1", mac_id: MAC });
  await t.settle();
  t.takeCalls();
  await postSessions(t.deps, ALICE, sessions(2, [S("a", "working")]));
  await t.settle();
  const calls = t.takeCalls();
  assert.deepEqual(calls.map((c) => [c.token, c.body.aps.event]).sort(), [
    [tok("3"), "update"],
    [tok("6"), "start"],
  ]);
});

test("cleanup: 410 and 400 BadDeviceToken/DeviceTokenNotForTopic delete the token, other errors keep it", async () => {
  const t = setup();
  await registerPhone(t, PHONE, "1");
  await registerPhone(t, PHONE2, "5");
  await putToken(t.deps, ALICE, { device_id: "C0FFEE00-0000-4000-8000-000000000003", kind: "alert", token: tok("7"), env: "sandbox" });
  await putToken(t.deps, ALICE, { device_id: "C0FFEE00-0000-4000-8000-000000000004", kind: "alert", token: tok("8"), env: "sandbox" });
  t.answers.set(tok("1"), { status: 410, reason: "Unregistered" });
  t.answers.set(tok("5"), { status: 400, reason: "BadDeviceToken" });
  t.answers.set(tok("7"), { status: 400, reason: "DeviceTokenNotForTopic" });
  t.answers.set(tok("8"), { status: 500, reason: "InternalServerError" });
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "blocked")]));
  await t.settle();
  assert.equal(t.takeCalls().filter((c) => c.headers["apns-push-type"] === "alert").length, 4);
  assert.deepEqual(
    t.rows(`SELECT token FROM push_tokens WHERE kind = 'alert'`).map((r) => r.token),
    [tok("8")],
  );
});

test("cron: a Mac silent for 180 s lapses; its cards end online:false, dismissal +600", async () => {
  const t = setup();
  await registerPhone(t);
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "working")]));
  await putToken(t.deps, ALICE, { device_id: PHONE, kind: "la_update", token: tok("3"), env: "production", activity_id: "act-1", mac_id: MAC });
  await t.settle();
  t.takeCalls();
  t.clock.now += 179;
  await runCron(t.deps);
  assert.deepEqual(t.takeCalls(), []);
  t.clock.now += 1;
  await runCron(t.deps);
  const calls = t.takeCalls();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].body.aps.event, "end");
  assert.equal(calls[0].body.aps["dismissal-date"], t.clock.now + 600);
  assert.equal(calls[0].body.aps["content-state"].online, false);
  assert.deepEqual(calls[0].body.aps["content-state"].sessions, []);
  assert.deepEqual(t.rows(`SELECT online, snapshot FROM push_macs`), [{ online: 0, snapshot: "[]" }]);
  assert.equal(t.rows(`SELECT * FROM push_tokens WHERE kind = 'la_update'`).length, 0);
  await runCron(t.deps);
  assert.deepEqual(t.takeCalls(), [], "once");
});

test("offline post ends the cards at once", async () => {
  const t = setup();
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "working")]));
  await putToken(t.deps, ALICE, { device_id: PHONE, kind: "la_update", token: tok("3"), env: "production", activity_id: "act-1", mac_id: MAC });
  await t.settle();
  t.takeCalls();
  await postSessions(t.deps, ALICE, { mac_id: MAC, seq: 2, offline: true });
  await t.settle();
  const [c] = t.takeCalls();
  assert.equal(c.body.aps.event, "end");
  assert.equal(c.body.aps["content-state"].online, false);
  assert.equal(c.body.aps["dismissal-date"], t.clock.now + 600);
  assert.equal(t.rows(`SELECT * FROM push_tokens`).length, 0);
});

test("cron: idle for 10 min ends the card now; a live card is re-pushed every 10 min", async () => {
  const t = setup();
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "working")]));
  await putToken(t.deps, ALICE, { device_id: PHONE, kind: "la_update", token: tok("3"), env: "production", activity_id: "act-1", mac_id: MAC });
  await t.settle();
  t.takeCalls();
  const beat = async (seq) => postSessions(t.deps, ALICE, { mac_id: MAC, seq });
  t.clock.now += 590;
  await beat(2);
  await runCron(t.deps);
  assert.deepEqual(t.takeCalls(), []);
  t.clock.now += 10;
  await runCron(t.deps);
  let calls = t.takeCalls();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].body.aps.event, "update");
  assert.equal(calls[0].headers["apns-priority"], "5");
  assert.equal(calls[0].body.aps["stale-date"], t.clock.now + 900);

  await postSessions(t.deps, ALICE, sessions(3, [S("a", "idle")]));
  await t.settle();
  t.takeCalls();
  const idleAt = t.clock.now;
  for (let s = 4; t.clock.now < idleAt + 599; s++) {
    t.clock.now += 60;
    if (t.clock.now >= idleAt + 600) t.clock.now = idleAt + 599;
    await beat(s);
    await runCron(t.deps);
  }
  assert.deepEqual(t.takeCalls().map((c) => c.body.aps.event).filter((e) => e === "end"), []);
  t.clock.now = idleAt + 600;
  await runCron(t.deps);
  calls = t.takeCalls();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].body.aps.event, "end");
  assert.equal(calls[0].body.aps["dismissal-date"], t.clock.now);
  assert.equal(calls[0].body.aps["content-state"].online, true);
  assert.equal(t.rows(`SELECT * FROM push_tokens`).length, 0);
});

test("cron: a card token older than iOS's 8 h limit is purged, so the next edge can start a card", async () => {
  const t = setup();
  await registerPhone(t);
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "idle")]));
  await putToken(t.deps, ALICE, { device_id: PHONE, kind: "la_update", token: tok("3"), env: "production", activity_id: "act-1", mac_id: MAC });
  await t.settle();
  // The activity began 8 h minus 1 s ago (a token rotation keeps created_at).
  t.raw.prepare(`UPDATE push_tokens SET created_at = ? WHERE kind = 'la_update'`).run(t.clock.now - 8 * 3600 + 1);
  await runCron(t.deps);
  assert.equal(t.rows(`SELECT * FROM push_tokens WHERE kind = 'la_update'`).length, 1);
  t.raw.prepare(`UPDATE push_tokens SET created_at = ? WHERE kind = 'la_update'`).run(t.clock.now - 8 * 3600);
  await runCron(t.deps);
  assert.equal(t.rows(`SELECT * FROM push_tokens WHERE kind = 'la_update'`).length, 0);
  t.takeCalls();
  await postSessions(t.deps, ALICE, sessions(2, [S("a", "working")]));
  await t.settle();
  assert.deepEqual(t.takeCalls().map((c) => c.body.aps.event), ["start"]);
});

test("a card registered while the Mac is offline ends at once (absent, never stale)", async () => {
  const t = setup();
  await putToken(t.deps, ALICE, { device_id: PHONE, kind: "la_update", token: tok("3"), env: "production", activity_id: "act-1", mac_id: MAC });
  await t.settle();
  const [c] = t.takeCalls();
  assert.equal(c.body.aps.event, "end");
  assert.equal(c.body.aps["content-state"].online, false);
  assert.equal(t.rows(`SELECT * FROM push_tokens`).length, 0);
});

// ---- purges -----------------------------------------------------------------

test("purges: deleteDevice drops the Mac's row and its cards; deleteAccount drops everything of the email", async () => {
  const t = setup();
  await registerPhone(t);
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "idle")]));
  await postSessions(t.deps, BOB, { mac_id: BOB_MAC, seq: 1 });
  await putToken(t.deps, ALICE, { device_id: PHONE, kind: "la_update", token: tok("3"), env: "production", activity_id: "act-1", mac_id: MAC });
  await putToken(t.deps, BOB, { device_id: PHONE2, kind: "alert", token: tok("9"), env: "production" });
  await t.settle();
  await t.deps.db.batch(purgeMacStatements(t.deps.db, ALICE, MAC));
  assert.deepEqual(t.rows(`SELECT email FROM push_macs`), [{ email: BOB }]);
  assert.deepEqual(t.rows(`SELECT email, kind FROM push_tokens ORDER BY email, kind`), [
    { email: ALICE, kind: "alert" },
    { email: ALICE, kind: "la_start" },
    { email: BOB, kind: "alert" },
  ]);
  await t.deps.db.batch(purgeAccountStatements(t.deps.db, ALICE));
  assert.deepEqual(t.rows(`SELECT email FROM push_tokens`), [{ email: BOB }]);
  assert.deepEqual(t.rows(`SELECT email FROM push_macs`), [{ email: BOB }]);
});
