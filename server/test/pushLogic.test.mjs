import { test } from "node:test";
import assert from "node:assert/strict";
import {
  parseTokenBody,
  parseDeleteBody,
  parseSessionsBody as parseSessionsBodyAt,
  contentState,
  cut,
  reduceSessions,
  cronStep,
  emptyMac,
  startPayload,
  alertPayload,
  laPayload,
  collapseId,
  classifyApns,
  sendApns,
  importP8,
  signApnsJwt,
  cleanMacName,
  readBody,
  cronBudget,
  planCron,
  restartStep,
  wantsCard,
} from "../src/pushLogic.mjs";

const S = (name, state, extra = {}) => ({ name, state, ...extra });
const bytes = (o) => new TextEncoder().encode(JSON.stringify(o)).length;
const HEX = "ab".repeat(32);
const PHONE = "3F2504E0-4F89-11D3-9A0C-0305E82C3301";
const NOW_S = 2_000_000_000; // the Worker's clock for the seq bound
const parseSessionsBody = (b, now = NOW_S) => parseSessionsBodyAt(b, now);

// ---- validation -------------------------------------------------------------

test("parseTokenBody: phone install id is format-checked only", () => {
  for (const device_id of [PHONE, "abcdefgh", "a".repeat(64), "A-1-b-2-c"]) {
    assert.ok(parseTokenBody({ device_id, kind: "alert", token: HEX, env: "production" }).value, device_id);
  }
  for (const device_id of ["abcdefg", "a".repeat(65), "has_underscore", "has space1", 12345678, null]) {
    assert.equal(parseTokenBody({ device_id, kind: "alert", token: HEX, env: "production" }).error, "invalid_device_id");
  }
});

test("parseTokenBody: kind/env enums, token hex, la_update needs activity + mac", () => {
  const base = { device_id: PHONE, token: HEX, env: "sandbox" };
  assert.equal(parseTokenBody({ ...base, kind: "voip" }).error, "invalid_kind");
  assert.equal(parseTokenBody({ ...base, kind: "alert", env: "dev" }).error, "invalid_env");
  assert.equal(parseTokenBody({ ...base, kind: "alert", token: "xyz" }).error, "invalid_token");
  assert.equal(parseTokenBody({ ...base, kind: "la_update", mac_id: HEX }).error, "invalid_activity_id");
  assert.equal(parseTokenBody({ ...base, kind: "la_update", activity_id: "act-1" }).error, "invalid_mac_id");
  assert.equal(parseTokenBody({ ...base, kind: "alert", activity_id: "act-1" }).error, "unexpected_field");
  assert.equal(parseTokenBody({ ...base, kind: "la_start", mac_id: HEX }).error, "unexpected_field");
  assert.deepEqual(parseTokenBody({ ...base, kind: "la_update", activity_id: "act-1", mac_id: HEX }).value, {
    ...base,
    kind: "la_update",
    activity_id: "act-1",
    mac_id: HEX,
  });
  assert.deepEqual(parseTokenBody({ ...base, kind: "alert", activity_id: null }).value.activity_id, "");
  for (const b of [null, [], "x", 1]) assert.equal(parseTokenBody(b).error, "invalid_body");
});

test("parseDeleteBody: device required, kind/activity optional", () => {
  assert.deepEqual(parseDeleteBody({ device_id: PHONE }).value, { device_id: PHONE, kind: null, activity_id: null });
  assert.equal(parseDeleteBody({ device_id: "short" }).error, "invalid_device_id");
  assert.equal(parseDeleteBody({ device_id: PHONE, kind: "x" }).error, "invalid_kind");
  assert.equal(parseDeleteBody({ device_id: PHONE, kind: "alert", activity_id: "a" }).error, "unexpected_field");
  assert.ok(parseDeleteBody({ device_id: PHONE, kind: "la_update", activity_id: "a" }).value);
});

test("parseSessionsBody: cap 20, lengths, enums, duplicates, offline", () => {
  const ok = (sessions, extra = {}) => parseSessionsBody({ mac_id: HEX, seq: 1, sessions, ...extra });
  const many = (n) => Array.from({ length: n }, (_, i) => S(`s${i}`, "idle"));
  assert.equal(ok(many(20)).value.sessions.length, 20);
  assert.equal(ok(many(21)).error, "too_many_sessions");
  assert.ok(ok([S("😀".repeat(64), "idle", { alias: "é".repeat(64) })]).value, "64 code points is fine");
  assert.equal(ok([S("x".repeat(65), "idle")]).error, "invalid_session");
  assert.equal(ok([S("a", "idle", { alias: "x".repeat(65) })]).error, "invalid_session");
  assert.equal(ok([S("", "idle")]).error, "invalid_session");
  assert.equal(ok([S("a\nb", "idle")]).error, "invalid_session");
  for (const state of ["running", "toString", "", 1]) assert.equal(ok([S("a", state)]).error, "invalid_session", String(state));
  assert.equal(ok([S("a", "idle", { agents: -1 })]).error, "invalid_session");
  assert.equal(ok([S("a", "idle", { agents: 1.5 })]).error, "invalid_session");
  assert.equal(ok([S("a", "idle"), S("a", "working")]).error, "duplicate_session");
  assert.deepEqual(ok([S("a", "working", { alias: "", agents: 2 })]).value.sessions, [S("a", "working", { agents: 2 })]);
  assert.equal(ok([], { offline: true }).error, "offline_with_sessions");
  assert.deepEqual(parseSessionsBody({ mac_id: HEX, seq: 5, offline: true }).value, {
    mac_id: HEX,
    seq: 5,
    offline: true,
    sessions: null,
  });
  assert.equal(parseSessionsBody({ mac_id: HEX, seq: 5 }).value.sessions, null, "bare = heartbeat");
  for (const seq of [0, -1, 1.5, "1", null]) assert.equal(parseSessionsBody({ mac_id: HEX, seq }).error, "invalid_seq");
  assert.equal(parseSessionsBody({ mac_id: "", seq: 1 }).error, "invalid_mac_id");
  assert.equal(parseSessionsBody({ mac_id: HEX, seq: 1, offline: "yes" }).error, "invalid_offline");
  assert.equal(parseSessionsBody({ mac_id: HEX, seq: 1, sessions: {} }).error, "invalid_sessions");
});

test("seq: over 1 h ahead of the Worker's clock is a 400 (a far-future seq would lock the Mac out)", () => {
  const at = (seq, now = NOW_S) => parseSessionsBodyAt({ mac_id: HEX, seq }, now);
  const edge = NOW_S * 1000 + 3600 * 1000;
  assert.equal(at(edge).value.seq, edge, "exactly 1 h ahead is fine");
  assert.equal(at(edge + 1).error, "invalid_seq");
  assert.equal(at(9_000_000_000_000).error, "invalid_seq", "QA probe: 9e12");
  assert.equal(parseSessionsBodyAt({ mac_id: HEX, seq: 1 }).error, "invalid_seq", "no clock: fails closed");
});

// Every code point of each class range, one by one, in a name and in an alias:
// Cc, Zl, Zp and a sample of Cf (the bidi controls, U+061C, U+00AD, the Arabic
// number signs, U+200B, U+2060..U+2064, U+206A..U+206F, U+FFF9..U+FFFB, U+E0001).
const RANGES = [
  [0x00, 0x1f], [0x7f, 0x7f], [0x80, 0x9f], [0x200e, 0x200f], [0x202a, 0x202e],
  [0x2066, 0x2069], [0x2028, 0x2029], [0xfeff, 0xfeff],
  [0x061c, 0x061c], [0x00ad, 0x00ad], [0x0600, 0x0605], [0x200b, 0x200b], [0x2060, 0x2064],
  [0x206a, 0x206f], [0xfff9, 0xfffb], [0xe0001, 0xe0001],
];
// Text, including the two Cf exceptions (ZWJ, the tags) and U+FE0F (Mn).
const NEIGHBOURS = [0x20, 0x7e, 0xa0, 0x200d, 0x2010, 0x2027, 0x202f, 0x2065, 0xfe0f, 0xfefe, 0xff01, 0xe0020, 0xe0067, 0xe007f];
const ENGLAND = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}";
const FAMILY = "\u{1F468}‍\u{1F469}‍\u{1F467}";

test("names and aliases: Cc, Cf (but ZWJ and the tags), Zl and Zp are a 400", () => {
  const ok = (sessions) => parseSessionsBody({ mac_id: HEX, seq: 1, sessions });
  for (const [lo, hi] of RANGES) {
    for (let c = lo; c <= hi; c++) {
      const ch = String.fromCodePoint(c);
      const hex = c.toString(16);
      assert.equal(ok([S(`ab${ch}cd`, "idle")]).error, "invalid_session", `name U+${hex}`);
      assert.equal(ok([S("a", "idle", { alias: `x${ch}` })]).error, "invalid_session", `alias U+${hex}`);
    }
  }
  for (const c of NEIGHBOURS) {
    const ch = String.fromCodePoint(c);
    assert.ok(ok([S(`ab${ch}cd`, "idle", { alias: `x${ch}` })]).value, `U+${c.toString(16)} is text`);
  }
  assert.ok(ok([S("👩‍💻 dev", "idle")]).value, "a ZWJ emoji sequence passes");
  assert.ok(ok([S(`${FAMILY} home`, "idle")]).value, "a ZWJ family emoji passes");
  assert.ok(ok([S(`${ENGLAND} deploy`, "idle", { alias: ENGLAND })]).value, "a subdivision flag passes");
  assert.ok(ok([S("❤️ ship", "idle")]).value, "U+FE0F passes");
  for (const ch of ["­", "؀", "￹", "؜"]) assert.equal(ok([S(`a${ch}b`, "idle")]).error, "invalid_session");
});

test("cleanMacName: the same class is stripped from devices.name, never rejected", () => {
  for (const [lo, hi] of RANGES) {
    for (let c = lo; c <= hi; c++) assert.equal(cleanMacName(`St${String.fromCodePoint(c)}udio`), "Studio", c.toString(16));
  }
  assert.equal(cleanMacName("‮oidutS⁦"), "oidutS");
  assert.equal(cleanMacName("Studio Mac"), "Studio Mac");
  assert.equal(cleanMacName(`${ENGLAND} ${FAMILY}❤️`), `${ENGLAND} ${FAMILY}❤️`, "flag, family, FE0F kept");
  assert.equal(cleanMacName("‮\u0085"), "Mac", "nothing left: the default");
  assert.equal(cleanMacName(null), "Mac");
  assert.equal(cleanMacName("x".repeat(70)), "x".repeat(64));
  assert.equal(cleanMacName("a\ud800b"), "a�b", "well-formed");
});

// A body stream that counts its pulls: chunk(i) -> Uint8Array, or null to close.
function counted(chunk) {
  const s = { pulls: 0, cancelled: false };
  s.body = new ReadableStream(
    {
      pull(c) {
        const x = chunk(s.pulls++);
        x ? c.enqueue(x) : c.close();
      },
      cancel() {
        s.cancelled = true;
      },
    },
    { highWaterMark: 0 },
  );
  return s;
}

test("readBody: a body over 32768 bytes is too large, by content-length or as it streams", async () => {
  const enc = (t) => new TextEncoder().encode(t);
  const req = (body, cl) => ({ headers: new Headers(cl === undefined ? {} : { "content-length": String(cl) }), body: counted((i) => (i === 0 ? enc(body) : null)).body });
  assert.deepEqual(await readBody(req('{"a":1}')), { value: { a: 1 } });
  assert.deepEqual(await readBody(req("not json")), { value: null });
  assert.deepEqual(await readBody({ headers: new Headers(), body: null }), { value: null }, "no body");
  assert.deepEqual(await readBody(new Request("https://w/p", { method: "POST", body: '{"r":2}' })), { value: { r: 2 } }, "a real Request");
  const unread = { headers: new Headers({ "content-length": "32769" }), body: { getReader: () => assert.fail("read past the cap") } };
  assert.deepEqual(await readBody(unread), { tooLarge: true });
  const exact = JSON.stringify({ p: "x".repeat(32768 - 8) });
  assert.equal(enc(exact).length, 32768);
  assert.ok((await readBody(req(exact))).value, "32768 bytes is fine");
  assert.ok((await readBody(req(exact, 32768))).value, "content-length 32768 is fine");
  assert.deepEqual(await readBody(req(exact + " ")), { tooLarge: true }, "no content-length: counted as it streams");

  // QA probe: a chunked 4 MiB body. The read stops just past 32 KB and is cancelled.
  const big = counted((i) => (i < 512 ? new Uint8Array(8192).fill(0x20) : null));
  assert.deepEqual(await readBody({ headers: new Headers(), body: big.body }), { tooLarge: true });
  assert.ok(big.pulls <= 6, `${big.pulls} chunks pulled of 512`);
  assert.equal(big.cancelled, true);
  // Under the cap, in several chunks: parsed whole.
  const parts = ['{"sessions":[', '"a",', '"b"]}'].map(enc);
  const small = counted((i) => parts[i] ?? null);
  assert.deepEqual(await readBody({ headers: new Headers(), body: small.body }), { value: { sessions: ["a", "b"] } });
  assert.equal(small.cancelled, false);
});

test("cronBudget: PUSH_CRON_BUDGET clamped to [13, 48]; unset or junk is 44", () => {
  assert.equal(cronBudget(undefined), 44);
  assert.equal(cronBudget("junk"), 44);
  assert.equal(cronBudget(""), 44);
  assert.equal(cronBudget("44"), 44);
  assert.equal(cronBudget("30"), 30);
  assert.equal(cronBudget("13"), 13);
  assert.equal(cronBudget("12"), 13, "the largest step (10 cards + 3) always fits");
  assert.equal(cronBudget("0"), 13);
  assert.equal(cronBudget("-5"), 13);
  assert.equal(cronBudget("48"), 48);
  assert.equal(cronBudget("49"), 48, "2 up front + 48 = 50");
  assert.equal(cronBudget("100000"), 48);
});

// ---- content-state ----------------------------------------------------------

test("contentState: urgency order then name, cap 6, more, counts", () => {
  const sessions = [
    S("z", "idle"),
    S("b", "working"),
    S("a", "done"),
    S("c", "blocked", { alias: "Fix it", agents: 2 }),
    S("a2", "working"),
    S("y", "idle"),
    S("x", "idle"),
    S("d", "blocked"),
  ];
  const cs = contentState(sessions);
  assert.deepEqual(
    cs.sessions.map((s) => s.name),
    ["c", "d", "a2", "b", "a", "x"],
  );
  assert.equal(cs.more, 2);
  assert.deepEqual(cs.counts, { blocked: 2, working: 2, idle: 3, done: 1 });
  assert.deepEqual(cs.sessions[0], { name: "c", alias: "Fix it", state: "blocked", agents: 2 });
  assert.deepEqual(Object.keys(cs), ["v", "online", "counts", "sessions", "more"], "no timestamps");
  assert.equal(cs.v, 1);
  assert.equal(cs.online, true);
  assert.deepEqual(contentState([], false), {
    v: 1,
    online: false,
    counts: { blocked: 0, working: 0, idle: 0, done: 0 },
    sessions: [],
    more: 0,
  });
  assert.equal(contentState(sessions.slice(0, 6)).more, 0);
});

test("contentState: names and aliases cut to 40 characters (code points)", () => {
  const cs = contentState([S("n".repeat(64), "idle", { alias: "😀".repeat(64) })]);
  assert.equal(cs.sessions[0].name, "n".repeat(40));
  assert.equal([...cs.sessions[0].alias].length, 40);
  assert.equal(cs.sessions[0].alias, "😀".repeat(40), "no split surrogate pair");
  assert.equal(cut("short"), "short");
  assert.equal(cut("x".repeat(41)).length, 40);
});

test("worst-case start/update/alert payloads stay under 4 KB", () => {
  // A lone surrogate (legal in a JSON body) would re-escape to 6 bytes, so it is a 400;
  // the worst left is a 4-byte character per code point.
  assert.equal(parseSessionsBody({ mac_id: HEX, seq: 1, sessions: [S("\ud800", "idle")] }).error, "invalid_session");
  const fat = "😀".repeat(63);
  const sessions = Array.from({ length: 20 }, (_, i) =>
    S(fat + String.fromCharCode(0x41 + i), "blocked", { alias: fat + String.fromCharCode(0x61 + i), agents: 999 }),
  );
  assert.ok(parseSessionsBody({ mac_id: HEX, seq: 1, sessions }).value, "the body itself is valid");
  const cs = contentState(sessions);
  const name = "😀".repeat(64);
  const mac = "f".repeat(128);
  const now = 2_000_000_000;
  const start = bytes(startPayload(cs, now, mac, name));
  assert.ok(start > 2000 && start < 4096, `start ${start}`);
  assert.ok(bytes(laPayload("end", cs, now, { "dismissal-date": now + 600 })) < 4096);
  assert.ok(bytes(alertPayload(mac, name, [{ name: sessions[0].name, label: sessions[0].alias }])) < 4096);
});

// ---- edges ------------------------------------------------------------------

const post = (seq, sessions) => ({ mac_id: HEX, seq, offline: false, sessions });
const beat = (seq) => ({ mac_id: HEX, seq, offline: false, sessions: null });
const step = (prev, input, now) => reduceSessions(prev, input, now);

test("seq: at or below the stored one is ignored", () => {
  const a = step(null, post(100, [S("a", "idle")]), 1000);
  assert.equal(step(a.mac, post(100, [S("a", "working")]), 1001), null);
  assert.equal(step(a.mac, post(99, [S("a", "working")]), 1001), null);
  assert.equal(step(a.mac, beat(100), 1001), null);
  assert.equal(step(a.mac, post(101, [S("a", "working")]), 1001).mac.seq, 101);
});

test("start edge: none-active -> active, or a session entering blocked; never steady", () => {
  const idle = step(null, post(1, [S("a", "idle")]), 1000);
  assert.equal(idle.push.start, false, "idle only: no card");
  const work = step(idle.mac, post(2, [S("a", "working")]), 1100);
  assert.equal(work.push.start, true, "idle -> working");
  assert.equal(work.mac.started_at, 1100);
  const still = step(work.mac, post(3, [S("a", "working"), S("b", "idle")]), 1200);
  assert.equal(still.push.start, false, "steady working is not an edge");
  assert.equal(still.push.update, true, "but the content changed");
  const blocked = step(still.mac, post(4, [S("a", "working"), S("b", "blocked")]), 1300);
  assert.equal(blocked.push.start, true, "entering blocked is an edge");
  const done = step(blocked.mac, post(5, [S("a", "done"), S("b", "done")]), 1400);
  assert.equal(done.push.start, false);
  const back = step(done.mac, post(6, [S("a", "blocked"), S("b", "done")]), 1500);
  assert.equal(back.push.start, true, "done -> blocked");
  // Mac lapsed/offline: whatever it had is gone, so active again is an edge.
  const off = step(back.mac, { mac_id: HEX, seq: 7, offline: true, sessions: null }, 1600);
  assert.equal(step(off.mac, post(8, [S("a", "working")]), 1700).push.start, true);
});

test("start edge: no second push-to-start within 60 s", () => {
  const a = step(null, post(1, [S("a", "working")]), 1000);
  assert.equal(a.push.start, true);
  const b = step(a.mac, post(2, [S("a", "blocked")]), 1059);
  assert.equal(b.push.start, false, "the first start is still landing");
  assert.equal(b.mac.started_at, 1000);
  const c = step(b.mac, post(3, [S("a", "working")]), 1070);
  const d = step(c.mac, post(4, [S("a", "blocked")]), 1100);
  assert.equal(d.push.start, true, "60 s later an edge starts again");
});

test("alert edge: into blocked from any other state, at most once per 120 s per session", () => {
  const a = step(null, post(1, [S("a", "working", { alias: "Fix it" }), S("b", "idle")]), 1000);
  assert.deepEqual(a.push.alerts, []);
  const b = step(a.mac, post(2, [S("a", "blocked", { alias: "Fix it" }), S("b", "idle")]), 1010);
  assert.deepEqual(b.push.alerts, [{ name: "a", label: "Fix it" }]);
  assert.equal(b.push.priority, 10, "entering blocked goes at priority 10");
  const c = step(b.mac, post(3, [S("a", "blocked", { alias: "Fix it" }), S("b", "blocked")]), 1020);
  assert.deepEqual(c.push.alerts, [{ name: "b", label: "b" }], "a stays blocked: no alert; b enters");
  // a flaps: working then blocked again 100 s after its alert -> suppressed.
  const d = step(c.mac, post(4, [S("a", "working"), S("b", "blocked")]), 1100);
  assert.equal(d.push.priority, 5);
  const e = step(d.mac, post(5, [S("a", "blocked"), S("b", "blocked")]), 1129);
  assert.deepEqual(e.push.alerts, [], "119 s after the last alert");
  assert.equal(e.push.priority, 10, "still an urgent card update");
  const f = step(e.mac, post(6, [S("a", "working"), S("b", "blocked")]), 1130);
  const g = step(f.mac, post(7, [S("a", "blocked"), S("b", "blocked")]), 1130);
  assert.deepEqual(g.push.alerts, [{ name: "a", label: "a" }], "120 s after the last alert");
  // A move to done sends nothing loud.
  const h = step(g.mac, post(8, [S("a", "done"), S("b", "done")]), 1200);
  assert.deepEqual(h.push.alerts, []);
  assert.equal(h.push.priority, 5);
  // A brand-new session that appears blocked counts as entering.
  const i = step(h.mac, post(9, [S("a", "done"), S("b", "done"), S("c", "blocked")]), 1300);
  assert.deepEqual(i.push.alerts, [{ name: "c", label: "c" }]);
});

test("update only when the content-state changes; heartbeat sends nothing", () => {
  const a = step(null, post(1, [S("a", "working")]), 1000);
  assert.equal(a.push.update, true, "first post");
  const same = step(a.mac, post(2, [S("a", "working")]), 1010);
  assert.equal(same.push.update, false);
  assert.equal(same.mac.last_push_at, 1000);
  const hb = step(same.mac, beat(3), 1070);
  assert.deepEqual(hb.push, { start: false, update: false, priority: 5, end: null, alerts: [] });
  assert.equal(hb.mac.last_seen, 1070);
  assert.deepEqual(hb.mac.sessions, [S("a", "working")]);
  // seventh session beyond the cap still changes counts -> update
  const six = Array.from({ length: 6 }, (_, i) => S(`s${i}`, "working"));
  const b = step(hb.mac, post(4, six), 1100);
  const c = step(b.mac, post(5, [...six, S("z", "idle")]), 1110);
  assert.equal(c.push.update, true);
});

test("offline post ends the card: online false, dismissal now+600", () => {
  const a = step(null, post(1, [S("a", "working")]), 1000);
  const off = step(a.mac, { mac_id: HEX, seq: 2, offline: true, sessions: null }, 1100);
  assert.deepEqual(off.push.end, { dismissal: 1700 });
  assert.equal(off.mac.online, false);
  assert.deepEqual(off.mac.sessions, []);
  assert.deepEqual(contentState(off.mac.sessions, off.mac.online).online, false);
});

test("idle_since: set when nothing is working/blocked, kept, cleared when busy", () => {
  const a = step(null, post(1, [S("a", "working")]), 1000);
  assert.equal(a.mac.idle_since, null);
  const b = step(a.mac, post(2, [S("a", "done")]), 1100);
  assert.equal(b.mac.idle_since, 1100);
  const c = step(b.mac, post(3, [S("a", "idle")]), 1200);
  assert.equal(c.mac.idle_since, 1100, "still idle since the first idle post");
  assert.equal(step(c.mac, beat(4), 1250).mac.idle_since, 1100);
  assert.equal(step(c.mac, post(4, [S("a", "blocked")]), 1300).mac.idle_since, null);
});

// ---- cron -------------------------------------------------------------------

const live = (over = {}) => ({ ...emptyMac(), online: true, seq: 1, last_seen: 1000, last_push_at: 1000, sessions: [S("a", "working")], ...over });

test("cron lapse at 180 s without a heartbeat", () => {
  assert.equal(cronStep(live(), true, 1179), null);
  const r = cronStep(live(), true, 1180);
  assert.equal(r.kind, "lapse");
  assert.deepEqual(r.push.end, { dismissal: 1780 });
  assert.equal(r.mac.online, false);
  assert.deepEqual(r.mac.sessions, [], "absent, never stale");
  assert.equal(cronStep(live(), false, 1180).kind, "lapse", "lapses with no card too");
  assert.equal(cronStep(live({ online: false }), true, 5000), null);
});

test("cron ends a card after 10 min with nothing working/blocked", () => {
  const idle = live({ sessions: [S("a", "idle")], idle_since: 1000, last_seen: 1590, last_push_at: 1590 });
  assert.equal(cronStep(idle, true, 1599), null);
  const r = cronStep(idle, true, 1600);
  assert.equal(r.kind, "end");
  assert.deepEqual(r.push.end, { dismissal: 1600 });
  assert.equal(cronStep(idle, false, 1600), null, "no card, nothing to end");
});

test("cron re-pushes a live card whose last push is over 10 min old", () => {
  const m = live({ last_seen: 1590, last_push_at: 1000 });
  assert.equal(cronStep(m, true, 1599), null);
  const r = cronStep(m, true, 1600);
  assert.equal(r.kind, "repush");
  assert.equal(r.push.update, true);
  assert.equal(r.push.priority, 5);
  assert.equal(r.mac.last_push_at, 1600);
  assert.equal(cronStep(m, false, 1600), null);
});

test("lapse: a session blocked throughout never alerts again on return; the start still goes", () => {
  // QA probe: blocked before the lapse, still blocked after it.
  const a = step(null, post(1, [S("s", "blocked")]), 1000);
  assert.equal(a.push.alerts.length, 1);
  const lapsed = cronStep(a.mac, true, 1200).mac;
  const b = step(lapsed, post(2, [S("s", "blocked")]), 1260);
  assert.deepEqual(b.push.alerts, [], "no second alert");
  assert.equal(b.push.start, true, "push-to-start on return stays");
  assert.equal(b.push.priority, 10, "the start of a blocked card is urgent");
  // The same through an offline post (sleep), and a heartbeat on return.
  const off = step(a.mac, { mac_id: HEX, seq: 3, offline: true, sessions: null }, 1300);
  const hb = step(off.mac, beat(4), 1400);
  assert.deepEqual(step(hb.mac, post(5, [S("s", "blocked")]), 1410).push.alerts, []);
  // Seen out of blocked (or absent) in a sessions post re-arms it.
  const c = step(b.mac, post(6, [S("s", "working")]), 1270);
  assert.deepEqual(step(c.mac, post(7, [S("s", "blocked")]), 1280).push.alerts, [{ name: "s", label: "s" }]);
  const gone = step(b.mac, post(6, []), 1270);
  assert.deepEqual(step(gone.mac, post(7, [S("s", "blocked")]), 1280).push.alerts, [{ name: "s", label: "s" }]);
  // A different session entering blocked on return still alerts.
  assert.deepEqual(step(lapsed, post(2, [S("s", "blocked"), S("t", "blocked")]), 1260).push.alerts, [{ name: "t", label: "t" }]);
});

test("offline and back: flapping is still limited to one alert per 120 s", () => {
  // A lapse always spans 180 s, so the 120 s window is checked across an offline post.
  const a = step(null, post(1, [S("s", "blocked")]), 1000); // alert at 1000
  const off = step(a.mac, { mac_id: HEX, seq: 2, offline: true, sessions: null }, 1010);
  const back = step(off.mac, post(3, [S("s", "working")]), 1020);
  const flap = step(back.mac, post(4, [S("s", "blocked")]), 1119);
  assert.deepEqual(flap.push.alerts, [], "119 s after the alert");
  const out = step(flap.mac, post(5, [S("s", "working")]), 1119);
  assert.deepEqual(step(out.mac, post(6, [S("s", "blocked")]), 1120).push.alerts, [{ name: "s", label: "s" }], "120 s");
});

test("alerts: the sessions entering blocked are in card order; 120 s and the blocked set still apply per session", () => {
  const a = step(null, post(1, [S("z", "working"), S("a", "working"), S("m", "working")]), 1000);
  const b = step(a.mac, post(2, [S("z", "blocked"), S("a", "blocked", { alias: "Fix" }), S("m", "blocked")]), 1010);
  assert.deepEqual(b.push.alerts.map((x) => x.name), ["a", "m", "z"]);
  // a flaps within 120 s and n enters: only n is alertable; m and z stay blocked.
  const c = step(b.mac, post(3, [S("z", "blocked"), S("a", "working"), S("m", "blocked")]), 1020);
  const d = step(c.mac, post(4, [S("z", "blocked"), S("a", "blocked"), S("m", "blocked"), S("n", "blocked")]), 1030);
  assert.deepEqual(d.push.alerts, [{ name: "n", label: "n" }]);
});

test("alertPayload: one session as before; two or more aggregate under the first, collapsed per Mac", async () => {
  const one = alertPayload(HEX, "Studio", [{ name: "a", label: "Fix it" }]);
  assert.deepEqual(one, {
    aps: { alert: { title: "Studio", body: "Fix it needs you" }, sound: "default", "thread-id": HEX },
    mac_id: HEX,
    session: "a",
    more: 0,
  });
  const many = alertPayload(HEX, "Studio", [{ name: "a", label: "Fix it" }, { name: "m", label: "m" }, { name: "z", label: "z" }]);
  assert.deepEqual(many, {
    aps: { alert: { title: "Studio", body: "Fix it and 2 more need you" }, sound: "default", "thread-id": HEX },
    mac_id: HEX,
    session: "a",
    more: 2,
  });
  const perMac = await collapseId(HEX);
  assert.match(perMac, /^[0-9a-f]{32}$/);
  assert.notEqual(perMac, await collapseId(HEX, "a"));
  assert.notEqual(perMac, await collapseId(HEX, ""));
  assert.notEqual(perMac, await collapseId("f".repeat(64)));
});

// ---- cron budget --------------------------------------------------------------

test("planCron: lapses first, then ends, then re-pushes, oldest due first; a step costs cards + 3 D1 queries", () => {
  const now = 10_000;
  const lapse = (id, last_seen, cards) => ({ id, cards, mac: live({ last_seen, last_push_at: last_seen }) });
  const end = (id, idle_since, cards) => ({
    id, cards, mac: live({ sessions: [S("a", "idle")], idle_since, last_seen: now - 10, last_push_at: now - 10 }),
  });
  const repush = (id, last_push_at, cards) => ({ id, cards, mac: live({ last_seen: now - 10, last_push_at }) });
  const rows = [
    repush("r-new", now - 700, 3), repush("r-old", now - 900, 3),
    end("e-new", now - 650, 4), end("e-old", now - 800, 4),
    lapse("l-new", now - 200, 5), lapse("l-old", now - 400, 5), lapse("l-free", now - 190, 0),
  ];
  // Costs: l-old 8, l-new 8, l-free 3, e-old 7, e-new 7, r-old 6, r-new 6 = 45.
  const ids = (plan) => plan.map((s) => s.row.id);
  assert.deepEqual(ids(planCron(rows, now, 100)), ["l-old", "l-new", "l-free", "e-old", "e-new", "r-old", "r-new"]);
  assert.deepEqual(ids(planCron(rows, now)), ["l-old", "l-new", "l-free", "e-old", "e-new", "r-old"], "45 is over the default 44");
  assert.deepEqual(ids(planCron(rows, now, 32)), ["l-old", "l-new", "l-free", "e-old", "r-old"], "a step that no longer fits waits");
  assert.deepEqual(ids(planCron(rows, now, 11)), ["l-old", "l-free"]);
  assert.deepEqual(ids(planCron(rows, now, 2)), [], "a lapse with no card still costs its queries");
  assert.equal(planCron(rows, now, 100)[0].kind, "lapse");
  assert.deepEqual(planCron([repush("x", now - 100, 1)], now, 40), [], "not due");
  const nine = Array.from({ length: 9 }, (_, i) => lapse(`m${i}`, now - 300 + i, 5));
  assert.equal(planCron(nine, now).length, 5, "default budget: 44 subrequests at 8 a step");
});

// ---- #546: starts without an edge -------------------------------------------

test("wantsCard: online, heartbeat under 180 s old, something working or blocked", () => {
  assert.equal(wantsCard(live(), 1179), true);
  assert.equal(wantsCard(live({ sessions: [S("a", "blocked")] }), 1000), true);
  assert.equal(wantsCard(live(), 1180), false, "lapsed, even before the cron marks it offline");
  assert.equal(wantsCard(live({ online: false }), 1000), false);
  assert.equal(wantsCard(live({ sessions: [S("a", "idle"), S("b", "done")] }), 1000), false);
});

test("restartStep: start where the Mac wants a card; wait inside START_GAP_S; drop otherwise", () => {
  const p = (over = {}) => ({ mac: live({ started_at: 900 }), start_token: HEX, has_card: 0, created_at: 1, ...over });
  assert.equal(restartStep(p(), 1000), "start");
  assert.equal(restartStep(p({ mac: live({ started_at: 950 }) }), 1009), "wait", "a start went 59 s ago");
  assert.equal(restartStep(p({ mac: live({ started_at: 950 }) }), 1010), "start");
  assert.equal(restartStep(p({ mac: live({ started_at: null }) }), 1000), "start");
  assert.equal(restartStep(p({ mac: null }), 1000), "drop", "the Mac is gone");
  assert.equal(restartStep(p({ start_token: null }), 1000), "drop", "no la_start token");
  assert.equal(restartStep(p({ has_card: 1 }), 1000), "drop", "the phone holds a newer card");
  assert.equal(restartStep(p({ mac: live({ sessions: [S("a", "idle")] }) }), 1000), "drop");
  assert.equal(restartStep(p({ mac: live({ online: false }) }), 1000), "drop");
  assert.equal(restartStep(p(), 1180), "drop", "lapsed");
});

test("planCron: restarts after lapses and ends, before re-pushes; an end, a start, one shared batch", () => {
  const now = 10_000;
  const lapse = { id: "lapse", cards: 2, mac: live({ last_seen: now - 300, last_push_at: now - 300 }) };
  const end = { id: "end", cards: 1, mac: live({ sessions: [S("a", "idle")], idle_since: now - 700, last_seen: now - 10, last_push_at: now - 10 }) };
  const repush = { id: "repush", cards: 1, mac: live({ last_seen: now - 10, last_push_at: now - 700 }) };
  const mac = live({ last_seen: now - 10 });
  const x = (id, created_at, over = {}) => ({ id, created_at, mac, start_token: HEX, has_card: 0, ...over });
  const expired = [x("x-new", 50), x("x-old", 10), x("x-drop", 30, { start_token: null }), x("x-wait", 5, { mac: live({ last_seen: now - 10, started_at: now - 30 }) })];
  const ids = (plan) => plan.map((s) => s.row.id);
  // Costs: lapse 5, end 4, restarts x-old 2 + 1 (batch), x-drop 1 (its end), x-new 2, repush 4 = 19.
  const all = planCron([repush, end, lapse], now, 100, expired);
  assert.deepEqual(ids(all), ["lapse", "end", "x-old", "x-drop", "x-new", "repush"], "x-wait waits");
  assert.deepEqual(all.filter((s) => s.kind === "restart").map((s) => s.start), [true, false, true]);
  assert.deepEqual(ids(planCron([repush, end, lapse], now, 18, expired)), ["lapse", "end", "x-old", "x-drop", "x-new"]);
  assert.deepEqual(ids(planCron([repush, end, lapse], now, 13, expired)), ["lapse", "end", "x-old", "x-drop"], "x-new's end + start no longer fit");
  assert.deepEqual(ids(planCron([repush, end, lapse], now, 11, expired)), ["lapse", "end", "x-drop"], "x-old's 3 do not fit, x-drop's end + batch do");
  assert.deepEqual(ids(planCron([lapse], now, 7, expired)), ["lapse", "x-drop"], "a drop costs its end and the batch");
  assert.deepEqual(ids(planCron([lapse], now, 6, expired)), ["lapse"]);
  assert.deepEqual(ids(planCron([], now, 6, expired)), ["x-old", "x-drop", "x-new"]);
  assert.deepEqual(ids(planCron([], now, 5, expired)), ["x-old", "x-drop"]);
  assert.deepEqual(ids(planCron([lapse], now, 5, expired)), ["lapse"], "lapses keep their priority");
  assert.deepEqual(ids(planCron([lapse], now, 44)), ["lapse"], "no expired cards: as before");
});

// ---- payloads ---------------------------------------------------------------

test("Live Activity payloads carry timestamp + stale-date; start carries attributes and a silent alert", () => {
  const cs = contentState([S("a", "working")]);
  const u = laPayload("update", cs, 1000);
  assert.deepEqual(u, { aps: { timestamp: 1000, event: "update", "content-state": cs, "stale-date": 1900 } });
  const s = startPayload(cs, 1000, HEX, "Studio");
  assert.equal(s.aps.event, "start");
  assert.equal(s.aps["attributes-type"], "ProsperSessionsAttributes");
  assert.deepEqual(s.aps.attributes, { mac_id: HEX, mac_name: "Studio" });
  assert.deepEqual(s.aps.alert, { title: "Studio", body: "Agents are working" });
  assert.equal(s.aps.sound, undefined);
  assert.equal(s.aps["stale-date"], 1900);
  const a = alertPayload(HEX, "Studio", [{ name: "a", label: "Fix it" }]);
  assert.deepEqual(a, {
    aps: { alert: { title: "Studio", body: "Fix it needs you" }, sound: "default", "thread-id": HEX },
    mac_id: HEX,
    session: "a",
    more: 0,
  });
});

test("collapseId: stable per mac+session, 32 hex", async () => {
  const a = await collapseId(HEX, "a");
  assert.match(a, /^[0-9a-f]{32}$/);
  assert.equal(a, await collapseId(HEX, "a"));
  assert.notEqual(a, await collapseId(HEX, "b"));
  assert.notEqual(await collapseId("m1", "x"), await collapseId("m", "1x"), "separator");
});

// ---- APNs -------------------------------------------------------------------

test("classifyApns: 410 and BadDeviceToken/DeviceTokenNotForTopic drop the token", () => {
  assert.equal(classifyApns(200, ""), "ok");
  assert.equal(classifyApns(410, "Unregistered"), "drop");
  assert.equal(classifyApns(410, ""), "drop");
  assert.equal(classifyApns(400, "BadDeviceToken"), "drop");
  assert.equal(classifyApns(400, "DeviceTokenNotForTopic"), "drop");
  assert.equal(classifyApns(400, "BadTopic"), "error");
  assert.equal(classifyApns(400, "PayloadTooLarge"), "error");
  assert.equal(classifyApns(403, "ExpiredProviderToken"), "auth");
  assert.equal(classifyApns(403, "InvalidProviderToken"), "auth");
  assert.equal(classifyApns(429, "TooManyRequests"), "error");
  assert.equal(classifyApns(500, "InternalServerError"), "error");
});

function fakeFetch(respond = () => ({ status: 200 })) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    const { status, reason, throws } = respond(url, init);
    if (throws) throw new Error("network");
    return new Response(status === 200 ? null : JSON.stringify({ reason }), { status });
  };
  return { fn, calls };
}

test("sendApns: host per env, topic per push type, headers, body; only via the injected fetch", async () => {
  const f = fakeFetch();
  const row = { token: HEX, env: "sandbox" };
  const auth = { jwt: "J", topic: "eu.illegible.prosperios" };
  assert.equal(await sendApns(f.fn, auth, { row, pushType: "liveactivity", priority: 5, payload: { x: 1 } }), "ok");
  assert.equal(f.calls[0].url, `https://api.sandbox.push.apple.com/3/device/${HEX}`);
  assert.equal(f.calls[0].init.method, "POST");
  assert.deepEqual(f.calls[0].init.headers, {
    authorization: "bearer J",
    "apns-topic": "eu.illegible.prosperios.push-type.liveactivity",
    "apns-push-type": "liveactivity",
    "apns-priority": "5",
    "content-type": "application/json",
  });
  assert.deepEqual(f.calls[0].body, { x: 1 });
  await sendApns(f.fn, auth, { row: { ...row, env: "production" }, pushType: "alert", priority: 10, payload: {}, collapseId: "c1" });
  assert.equal(f.calls[1].url, `https://api.push.apple.com/3/device/${HEX}`);
  assert.equal(f.calls[1].init.headers["apns-topic"], "eu.illegible.prosperios");
  assert.equal(f.calls[1].init.headers["apns-push-type"], "alert");
  assert.equal(f.calls[1].init.headers["apns-priority"], "10");
  assert.equal(f.calls[1].init.headers["apns-collapse-id"], "c1");
});

test("sendApns: classifies APNs answers, network errors are errors", async () => {
  const p = { row: { token: HEX, env: "production" }, pushType: "alert", priority: 10, payload: {} };
  const auth = { jwt: "J", topic: "t" };
  const with_ = (r) => fakeFetch(() => r).fn;
  assert.equal(await sendApns(with_({ status: 410, reason: "Unregistered" }), auth, p), "drop");
  assert.equal(await sendApns(with_({ status: 400, reason: "BadDeviceToken" }), auth, p), "drop");
  assert.equal(await sendApns(with_({ status: 400, reason: "DeviceTokenNotForTopic" }), auth, p), "drop");
  assert.equal(await sendApns(with_({ status: 400, reason: "BadPriority" }), auth, p), "error");
  assert.equal(await sendApns(with_({ status: 403, reason: "ExpiredProviderToken" }), auth, p), "auth");
  assert.equal(await sendApns(with_({ throws: true }), auth, p), "error");
});

// ---- provider JWT -----------------------------------------------------------

const b64urlDecode = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));

test("signApnsJwt: ES256 header {alg, kid}, claims {iss, iat}, verifies with the public key", async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const b64 = btoa(String.fromCharCode(...der));
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`;
  const jwt = await signApnsJwt(await importP8(pem), "KEY1234567", "TEAM123456", 1_700_000_000);
  const [h, c, s] = jwt.split(".");
  assert.deepEqual(JSON.parse(new TextDecoder().decode(b64urlDecode(h))), { alg: "ES256", kid: "KEY1234567" });
  assert.deepEqual(JSON.parse(new TextDecoder().decode(b64urlDecode(c))), { iss: "TEAM123456", iat: 1_700_000_000 });
  const sig = b64urlDecode(s);
  assert.equal(sig.length, 64, "raw r||s");
  assert.ok(
    await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, sig, new TextEncoder().encode(`${h}.${c}`)),
  );
  assert.doesNotMatch(jwt, /[+/=]/, "base64url, unpadded");
});
