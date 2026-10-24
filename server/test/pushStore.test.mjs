import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { sendApns, collapseId } from "../src/pushLogic.mjs";
import {
  putToken as putTokenAs,
  deleteTokens,
  postSessions,
  runCron,
  purgeMacStatements,
  purgeAccountStatements,
  logoutStatements,
  sessionCleanupStatements,
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
// The session token_hash each account posts under (sessions rows exist in setup).
const HASH = { [ALICE]: "a1".repeat(32), [BOB]: "b1".repeat(32) };
const putToken = (deps, email, body, hash = HASH[email]) => putTokenAs(deps, email, body, hash);

function setup() {
  const raw = new DatabaseSync(":memory:");
  for (const f of ["0001_init.sql", "0006_push.sql", "0007_push_harden.sql"]) {
    raw.exec(readFileSync(new URL(`../migrations/${f}`, import.meta.url), "utf8"));
  }
  raw.prepare(`INSERT INTO devices VALUES (?, ?, ?, 0, 0)`).run(ALICE, MAC, "Studio");
  raw.prepare(`INSERT INTO devices VALUES (?, ?, ?, 0, 0)`).run(BOB, BOB_MAC, "Bob's Mac");
  for (const email of [ALICE, BOB]) {
    raw.prepare(`INSERT INTO sessions VALUES (?, ?, 0, 0, NULL)`).run(HASH[email], email);
  }
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
    more: 0,
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

// ---- #524: QA #357 hardening ------------------------------------------------

const phoneId = (i) => `PHONE-${String(i).padStart(4, "0")}`;
const alertBody = (device_id, c = "1") => ({ device_id, kind: "alert", token: tok(c), env: "production" });
const cardBody = (device_id, mac_id, c = "3") => ({ device_id, kind: "la_update", token: tok(c), env: "production", activity_id: `act-${device_id}-${mac_id.slice(0, 4)}`, mac_id });
const phones = (t, email = ALICE) =>
  t.rows(`SELECT DISTINCT device_id FROM push_tokens WHERE email = ? ORDER BY device_id`, email).map((r) => r.device_id);

test("M1: at most 10 install ids per account; an 11th evicts the least recently updated with all its rows", async () => {
  const t = setup();
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "idle")])); // online, so a card is kept
  for (let i = 1; i <= 10; i++) {
    t.clock.now += 1;
    await registerPhone(t, phoneId(i));
    if (i === 2) await putToken(t.deps, ALICE, cardBody(phoneId(2), MAC));
  }
  t.clock.now += 1;
  await putToken(t.deps, ALICE, alertBody(phoneId(1), "7")); // phone 1 is used again: phone 2 is now the oldest
  await putToken(t.deps, BOB, alertBody(phoneId(99)));
  await t.settle();
  t.clock.now += 1;
  await putToken(t.deps, ALICE, alertBody(phoneId(1), "8")); // a known phone at the cap evicts nobody
  assert.equal(phones(t).length, 10);
  t.clock.now += 1;
  assert.equal((await putToken(t.deps, ALICE, alertBody(phoneId(11)))).status, 204);
  const left = phones(t);
  assert.equal(left.length, 10);
  assert.ok(left.includes(phoneId(11)), "the new phone always gets in");
  assert.ok(left.includes(phoneId(1)), "recently updated: kept");
  assert.ok(!left.includes(phoneId(2)), "least recently updated: evicted");
  assert.deepEqual(t.rows(`SELECT kind FROM push_tokens WHERE device_id = ?`, phoneId(2)), [], "alert, la_start and its card all go");
  assert.deepEqual(phones(t, BOB), [phoneId(99)], "another account is untouched");
});

test("M1: a new phone in the same second as the others still gets in", async () => {
  const t = setup();
  for (let i = 1; i <= 10; i++) await putToken(t.deps, ALICE, alertBody(phoneId(i)));
  await putToken(t.deps, ALICE, alertBody("0000-first-by-name"));
  const left = phones(t);
  assert.equal(left.length, 10);
  assert.ok(left.includes("0000-first-by-name"));
});

test("M1 (QA probe): an install-id flood leaves 10 phones and the cron run within its send budget", async () => {
  const t = setup();
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "working")]));
  for (let i = 1; i <= 1000; i++) {
    t.clock.now += 1;
    await putToken(t.deps, ALICE, cardBody(phoneId(i), MAC, "3"));
  }
  await t.settle();
  assert.deepEqual(phones(t), Array.from({ length: 10 }, (_, i) => phoneId(991 + i)));
  t.takeCalls();
  t.clock.now += 600; // lapse
  await runCron(t.deps);
  assert.equal(t.takeCalls().length, 10, "one end per surviving card");
});

test("M1: the cron stays within its budget per run, lapses oldest first; the rest runs next minute", async () => {
  const t = setup();
  const macs = ["1", "2", "3", "4"].map((c) => c.repeat(64));
  for (const m of macs) t.raw.prepare(`INSERT INTO devices VALUES (?, ?, ?, 0, 0)`).run(ALICE, m, "Mac");
  // Mac k last posted at T0 + 10k; three phones hold a card on each.
  for (const [k, m] of macs.entries()) {
    t.clock.now = T0 + 10 * k;
    await postSessions(t.deps, ALICE, { mac_id: m, seq: 1, sessions: [S("a", "working")] });
    for (const ph of [PHONE, PHONE2, phoneId(3)]) await putToken(t.deps, ALICE, cardBody(ph, m, String(k + 1)));
  }
  await t.settle();
  t.takeCalls();
  t.deps.budget = 12; // a lapse with 3 cards costs 3 sends + 3 queries
  t.clock.now = T0 + 300; // every Mac lapsed
  const ended = async () => {
    await runCron(t.deps);
    const calls = t.takeCalls();
    assert.ok(calls.length <= 6, `${calls.length} sends`);
    return [...new Set(calls.map((c) => c.token[0]))].sort();
  };
  assert.deepEqual(await ended(), ["1", "2"], "the two oldest lapses (3 sends each)");
  assert.deepEqual(t.rows(`SELECT online FROM push_macs ORDER BY mac_id`).map((r) => r.online), [0, 0, 1, 1]);
  t.clock.now += 60;
  assert.deepEqual(await ended(), ["3", "4"]);
  assert.deepEqual(await ended(), []);
});

test("L1: a token carries its session; logout and the daily cleanup take it, other sessions' rows stay", async () => {
  const t = setup();
  const second = "c1".repeat(32);
  t.raw.prepare(`INSERT INTO sessions VALUES (?, ?, 0, 0, ?)`).run(second, ALICE, T0 + 100);
  await registerPhone(t, PHONE); // Alice, session HASH[ALICE]
  await putToken(t.deps, ALICE, alertBody(PHONE2, "5"), second);
  await putToken(t.deps, BOB, alertBody(PHONE, "9"));
  const hashes = () => t.rows(`SELECT device_id, kind, token_hash FROM push_tokens WHERE email = ? ORDER BY device_id, kind`, ALICE);
  assert.deepEqual(hashes(), [
    { device_id: PHONE, kind: "alert", token_hash: HASH[ALICE] },
    { device_id: PHONE, kind: "la_start", token_hash: HASH[ALICE] },
    { device_id: PHONE2, kind: "alert", token_hash: second },
  ]);
  // A re-post from a new session moves the row to it.
  await putToken(t.deps, ALICE, alertBody(PHONE, "1"), second);
  assert.equal(hashes()[0].token_hash, second);
  await t.deps.db.batch(logoutStatements(t.deps.db, HASH[ALICE]));
  assert.deepEqual(hashes().map((r) => [r.device_id, r.kind]), [[PHONE, "alert"], [PHONE2, "alert"]], "la_start of the old session went");
  assert.deepEqual(t.rows(`SELECT token_hash FROM sessions ORDER BY token_hash`).map((r) => r.token_hash), [HASH[BOB], second].sort());
  assert.equal(t.rows(`SELECT * FROM push_tokens WHERE email = ?`, BOB).length, 1, "Bob untouched");

  // Daily cleanup: the second session has expired; a pre-0007 row ('' hash) has no session either.
  t.raw.prepare(`INSERT INTO push_tokens (email, device_id, kind, activity_id, token, env, created_at, updated_at)
    VALUES (?, 'LEGACY-PHONE', 'alert', '', ?, 'production', 0, 0)`).run(BOB, tok("6"));
  await t.deps.db.batch(sessionCleanupStatements(t.deps.db, T0 + 101));
  assert.deepEqual(hashes(), []);
  assert.deepEqual(t.rows(`SELECT device_id, token_hash FROM push_tokens`), [{ device_id: PHONE, token_hash: HASH[BOB] }]);
  assert.deepEqual(t.rows(`SELECT token_hash FROM sessions`), [{ token_hash: HASH[BOB] }], "a non-expiring session stays");
  await t.deps.db.batch(sessionCleanupStatements(t.deps.db, T0 + 100));
  assert.equal(t.rows(`SELECT * FROM push_tokens`).length, 1, "expires_at = now is not expired yet");
});

test("L2 (QA probe): a seq of 9e12 is a 400 and stores nothing; the Mac keeps posting", async () => {
  const t = setup();
  assert.deepEqual(await postSessions(t.deps, ALICE, sessions(9_000_000_000_000, [S("a", "idle")])), { status: 400, error: "invalid_seq" });
  assert.deepEqual(await postSessions(t.deps, ALICE, sessions(T0 * 1000 + 3600_000 + 1, [])), { status: 400, error: "invalid_seq" });
  assert.equal(t.rows(`SELECT * FROM push_macs`).length, 0);
  assert.equal((await postSessions(t.deps, ALICE, sessions(T0 * 1000 + 3600_000, [S("a", "idle")]))).status, 204);
  assert.equal((await postSessions(t.deps, ALICE, sessions(T0 * 1000 + 3600_001, []))).status, 400);
});

test("L3 (QA probe): bidi names are a 400; the Mac name has the class stripped in the payload", async () => {
  const t = setup();
  for (const ch of ["‮", "⁦", "\u0085", " ", "﻿"]) {
    assert.deepEqual(await postSessions(t.deps, ALICE, sessions(1, [S(`ab${ch}cd`, "blocked")])), { status: 400, error: "invalid_session" });
    assert.equal((await postSessions(t.deps, ALICE, sessions(1, [S("a", "blocked", { alias: `x${ch}` })]))).status, 400);
  }
  t.raw.prepare(`UPDATE devices SET name = ? WHERE device_id = ?`).run("‮Stu⁦dio\u0085", MAC);
  await registerPhone(t);
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "blocked")]));
  await t.settle();
  const calls = t.takeCalls();
  assert.equal(calls.find((c) => c.body.aps.event === "start").body.aps.attributes.mac_name, "Studio");
  assert.equal(calls.find((c) => c.headers["apns-push-type"] === "alert").body.aps.alert.title, "Studio");
});

test("L4 (QA probe): blocked across a lapse alerts once; the return pushes a start, no second alert", async () => {
  const t = setup();
  await registerPhone(t);
  await postSessions(t.deps, ALICE, sessions(1, [S("s", "idle")])); // the row exists: later posts update it
  t.clock.now += 10;
  await postSessions(t.deps, ALICE, sessions(2, [S("s", "blocked")]));
  await t.settle();
  const kinds = () => t.takeCalls().map((c) => (c.headers["apns-push-type"] === "alert" ? "alert" : c.body.aps.event)).sort();
  assert.deepEqual(kinds(), ["alert", "start"]);
  t.clock.now += 180;
  await runCron(t.deps);
  assert.equal(t.rows(`SELECT online FROM push_macs`)[0].online, 0);
  t.clock.now += 60;
  await postSessions(t.deps, ALICE, sessions(3, [S("s", "blocked")]));
  await t.settle();
  assert.deepEqual(kinds(), ["start"]);
  assert.equal(t.rows(`SELECT blocked FROM push_macs`)[0].blocked, `["s"]`);
});

// Lands `hook` between a statement's load and its write: the first `times` statements
// whose SQL contains `marker` await hook() before they run.
function interpose(t, marker, hook, times = 1) {
  const db = t.deps.db;
  let left = times;
  const wrap = (st) => ({
    ...st,
    bind: (...a) => wrap(st.bind(...a)),
    run: async () => {
      if (left > 0) {
        left--;
        await hook();
      }
      return st.run();
    },
  });
  t.deps.db = { ...db, prepare: (sql) => (left > 0 && sql.includes(marker) ? wrap(db.prepare(sql)) : db.prepare(sql)) };
}

test("L5: a lapse landing between a post's load and its upsert is not overwritten; the post re-reduces", async () => {
  const t = setup();
  await registerPhone(t);
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "working")]));
  await putToken(t.deps, ALICE, cardBody(PHONE, MAC));
  await t.settle();
  t.takeCalls();
  t.clock.now += 180;
  interpose(t, "INSERT INTO push_macs", () => runCron(t.deps));
  await postSessions(t.deps, ALICE, sessions(2, [S("a", "working")]));
  await t.settle();
  const calls = t.takeCalls();
  assert.deepEqual(calls.map((c) => [c.token, c.body.aps.event]), [[tok("3"), "end"], [tok("2"), "start"]], "lapse ended the card; the post started a new one");
  assert.deepEqual(t.rows(`SELECT seq, online, snapshot, rev FROM push_macs`), [
    { seq: 2, online: 1, snapshot: JSON.stringify([S("a", "working")]), rev: 3 },
  ]);
});

test("L5: a post landing between the cron's load and its update wins; the cron does nothing", async () => {
  const t = setup();
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "working")]));
  await putToken(t.deps, ALICE, cardBody(PHONE, MAC));
  await t.settle();
  t.takeCalls();
  t.clock.now += 180;
  interpose(t, "UPDATE push_macs SET online", () => postSessions(t.deps, ALICE, sessions(2, [S("a", "working")])));
  await runCron(t.deps);
  await t.settle();
  assert.deepEqual(t.takeCalls(), [], "no end for a Mac that just posted");
  assert.deepEqual(t.rows(`SELECT online, last_seen FROM push_macs`), [{ online: 1, last_seen: t.clock.now }]);
  assert.equal(t.rows(`SELECT * FROM push_tokens WHERE kind = 'la_update'`).length, 1, "the card stays");
});

test("L5: a newer seq landing between a post's load and its upsert is not overwritten", async () => {
  const t = setup();
  await registerPhone(t);
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "working")]));
  await t.settle();
  t.takeCalls();
  interpose(t, "INSERT INTO push_macs", () => postSessions(t.deps, ALICE, sessions(3, [S("a", "blocked")])));
  await postSessions(t.deps, ALICE, sessions(2, [S("a", "idle")]));
  await t.settle();
  assert.deepEqual(t.rows(`SELECT seq, snapshot FROM push_macs`), [{ seq: 3, snapshot: JSON.stringify([S("a", "blocked")]) }]);
  assert.equal(t.takeCalls().filter((c) => c.headers["apns-push-type"] === "alert").length, 1, "only the seq 3 post pushed");
});

test("L5: a post that loses the rev race twice is a 503 busy, writes and sends nothing", async () => {
  const t = setup();
  await registerPhone(t);
  await postSessions(t.deps, ALICE, sessions(1, [S("a", "working")]));
  await t.settle();
  t.takeCalls();
  const bump = async () => t.raw.prepare(`UPDATE push_macs SET rev = rev + 1 WHERE mac_id = ?`).run(MAC);
  interpose(t, "INSERT INTO push_macs", bump, 2); // a concurrent writer before each upsert
  assert.deepEqual(await postSessions(t.deps, ALICE, sessions(2, [S("a", "blocked")])), { status: 503, error: "busy" });
  await t.settle();
  assert.deepEqual(t.takeCalls(), []);
  assert.deepEqual(t.rows(`SELECT seq, rev FROM push_macs`), [{ seq: 1, rev: 3 }]);
  // The Mac's retry goes through.
  assert.equal((await postSessions(t.deps, ALICE, sessions(3, [S("a", "blocked")]))).status, 204);
  await t.settle();
  assert.equal(t.takeCalls().filter((c) => c.headers["apns-push-type"] === "alert").length, 1);
});

// ---- #524 round 2: the free plan's 50 subrequests per invocation -------------

// Counts what Cloudflare counts: each statement run (first/all/run), each batch call
// and each APNs send.
function countSubrequests(t) {
  const n = { d1: 0, apns: 0 };
  const { db, send } = t.deps;
  const wrap = (st) => ({
    ...st,
    bind: (...a) => wrap(st.bind(...a)),
    first: () => (n.d1++, st.first()),
    all: () => (n.d1++, st.all()),
    run: () => (n.d1++, st.run()),
  });
  t.deps.db = { prepare: (sql) => wrap(db.prepare(sql)), batch: (stmts) => (n.d1++, db.batch(stmts)) };
  t.deps.send = (p) => (n.apns++, send(p));
  return n;
}

const SESSION_CHECK = 2; // requireSession: the session SELECT and its last_seen UPDATE

test("worst-case post: 10 phones, 20 sessions entering blocked, a retry and a drop stay within 50 subrequests", async () => {
  const t = setup();
  const MAC2 = "2".repeat(64);
  t.raw.prepare(`INSERT INTO devices VALUES (?, ?, ?, 0, 0)`).run(ALICE, MAC2, "Other");
  const twenty = (state) => Array.from({ length: 20 }, (_, i) => S(`s${String(i).padStart(2, "0")}`, state));
  await postSessions(t.deps, ALICE, { mac_id: MAC2, seq: 1, sessions: [S("x", "working")] });
  await postSessions(t.deps, ALICE, sessions(1, twenty("working")));
  for (let i = 1; i <= 10; i++) {
    const c = String(i % 10);
    await putToken(t.deps, ALICE, alertBody(phoneId(i), c));
    await putToken(t.deps, ALICE, { device_id: phoneId(i), kind: "la_start", token: tok(c) + "1", env: "production" });
    await putToken(t.deps, ALICE, cardBody(phoneId(i), MAC2, c + "2"));
    if (i <= 5) await putToken(t.deps, ALICE, cardBody(phoneId(i), MAC, c + "3")); // half hold a card on this Mac
  }
  await t.settle();
  t.takeCalls();
  t.answers.set(tok("1"), { status: 410, reason: "Unregistered" }); // phone 1's alert token is dead
  t.clock.now += 61;
  const n = countSubrequests(t);
  interpose(t, "INSERT INTO push_macs", async () => {
    t.raw.prepare(`UPDATE push_macs SET rev = rev + 1 WHERE mac_id = ?`).run(MAC); // a concurrent writer: one retry
  });
  assert.equal((await postSessions(t.deps, ALICE, sessions(2, twenty("blocked")))).status, 204);
  await t.settle();
  const calls = t.takeCalls();
  const alerts = calls.filter((c) => c.headers["apns-push-type"] === "alert");
  assert.equal(alerts.length, 10, "one alert per phone");
  assert.equal(alerts[0].body.aps.alert.body, "s00 and 19 more need you");
  assert.deepEqual(calls.filter((c) => c.body.aps?.event === "update").length, 5);
  assert.deepEqual(calls.filter((c) => c.body.aps?.event === "start").length, 5);
  assert.equal(n.apns, 20);
  assert.equal(n.d1, 9, "device, 2 x (load, upsert), card/start/alert SELECTs, one drop batch");
  assert.ok(n.d1 + n.apns + SESSION_CHECK <= 50, `${n.d1} + ${n.apns} + ${SESSION_CHECK}`);
  assert.equal(t.rows(`SELECT * FROM push_tokens WHERE kind = 'alert' AND device_id = ?`, phoneId(1)).length, 0, "the drop ran");
});

test("aggregate alert: body under the first in card order, userInfo session = that name, collapse-id per Mac", async () => {
  const t = setup();
  await registerPhone(t, PHONE, "1");
  await registerPhone(t, PHONE2, "5");
  await postSessions(t.deps, ALICE, sessions(1, [S("z", "working"), S("b", "working")]));
  await t.settle();
  t.takeCalls();
  t.clock.now += 10;
  await postSessions(t.deps, ALICE, sessions(2, [S("z", "blocked"), S("b", "blocked", { alias: "Fix it" })]));
  await t.settle();
  const alerts = t.takeCalls().filter((c) => c.headers["apns-push-type"] === "alert");
  assert.deepEqual(alerts.map((c) => c.token).sort(), [tok("1"), tok("5")]);
  for (const a of alerts) {
    assert.deepEqual(a.body, {
      aps: { alert: { title: "Studio", body: "Fix it and 1 more need you" }, sound: "default", "thread-id": MAC },
      mac_id: MAC,
      session: "b",
      more: 1,
    });
    assert.equal(a.headers["apns-collapse-id"], await collapseId(MAC));
  }
  // A single one keeps its own collapse-id.
  t.clock.now += 200;
  await postSessions(t.deps, ALICE, sessions(3, [S("z", "working"), S("b", "blocked", { alias: "Fix it" })]));
  await postSessions(t.deps, ALICE, sessions(4, [S("z", "blocked"), S("b", "blocked", { alias: "Fix it" })]));
  await t.settle();
  const [single] = t.takeCalls().filter((c) => c.headers["apns-push-type"] === "alert");
  assert.equal(single.body.aps.alert.body, "z needs you");
  assert.equal(single.headers["apns-collapse-id"], await collapseId(MAC, "z"));
});

test("cron over many Macs: subrequests stay within PUSH_CRON_BUDGET + 2; the rest lapses next minute", async () => {
  const t = setup();
  const macs = Array.from({ length: 20 }, (_, i) => `${String(i).padStart(2, "0")}`.repeat(32));
  for (const [k, m] of macs.entries()) {
    t.raw.prepare(`INSERT INTO devices VALUES (?, ?, ?, 0, 0)`).run(ALICE, m, "Mac");
    t.clock.now = T0 + k;
    await postSessions(t.deps, ALICE, { mac_id: m, seq: 1, sessions: [S("a", "working")] });
    if (k % 4 !== 3) for (const ph of [PHONE, PHONE2, phoneId(3)]) await putToken(t.deps, ALICE, cardBody(ph, m, "3"));
  }
  await t.settle();
  t.takeCalls();
  t.clock.now = T0 + 600; // all 20 lapsed; 15 with 3 cards, 5 with none
  const left = () => t.rows(`SELECT COUNT(*) AS n FROM push_macs WHERE online = 1`)[0].n;
  const base = t.deps;
  let runs = 0;
  while (left() > 0) {
    t.deps = { ...base }; // each run counts afresh
    const n = countSubrequests(t);
    await runCron(t.deps);
    runs++;
    assert.ok(n.d1 + n.apns <= 44 + 2, `run ${runs}: ${n.d1} + ${n.apns}`);
    t.clock.now += 60;
    assert.ok(runs < 10);
  }
  assert.ok(runs >= 3, `${runs} runs: the budget was binding`);
});
