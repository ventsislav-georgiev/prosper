import { test } from "node:test";
import assert from "node:assert/strict";
import { WAKE_ID_RE, acctTag, ownsWakeId, clampInterval, clampPct, MIN_INTERVAL, MAX_INTERVAL } from "../src/wakeId.mjs";

test("WAKE_ID_RE accepts real device handles", () => {
  for (const ok of [
    "deadbeefdeadbeef-192.168.1.5", // LAN IPv4
    "deadbeefdeadbeef-100.92.1.4", // Tailscale
    "deadbeefdeadbeef-my-mac.local", // MagicDNS / hostname
    "deadbeefdeadbeef-fe80:0:0:0:1", // IPv6-ish (colons)
    "a_b-c.d", // word/underscore/dash/dot mix
  ]) assert.ok(WAKE_ID_RE.test(ok), ok);
});

test("WAKE_ID_RE rejects junk + overlong", () => {
  for (const bad of ["", "has space", "a/b", "a%2f", "x".repeat(81)])
    assert.ok(!WAKE_ID_RE.test(bad), JSON.stringify(bad));
});

test("acctTag is 16 lowercase-hex, deterministic, per-email", async () => {
  const a = await acctTag("alice@example.com");
  assert.match(a, /^[0-9a-f]{16}$/);
  assert.equal(a, await acctTag("alice@example.com")); // stable
  assert.notEqual(a, await acctTag("bob@example.com")); // distinct accounts
});

test("acctTag normalizes (trim + lowercase) — symmetric with app wakeAcctTag", async () => {
  const golden = await acctTag("alice@example.com");
  assert.equal(await acctTag("  Alice@Example.COM "), golden); // casing + whitespace
  assert.equal(await acctTag("ALICE@EXAMPLE.COM"), golden);
});

test("acctTag matches SHA-256(email)[:16]", async () => {
  // Independent recompute to pin the exact derivation the daemon mirrors.
  const buf = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode("alice@example.com"),
  );
  const hex = [...new Uint8Array(buf)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  assert.equal(await acctTag("alice@example.com"), hex.slice(0, 16));
});

test("ownsWakeId: only the owning account, with a hard '-' boundary", async () => {
  const email = "alice@example.com";
  const tag = await acctTag(email);

  assert.ok(await ownsWakeId(`${tag}-mymac`, email)); // own device → yes
  assert.ok(!(await ownsWakeId(`${tag}-mymac`, "bob@example.com"))); // other account → no
  assert.ok(!(await ownsWakeId(tag, email))); // no dash boundary → no
  assert.ok(!(await ownsWakeId(`${tag}x-mymac`, email))); // tag is a prefix but not the tag → no
  assert.ok(!(await ownsWakeId(`${tag.slice(0, 15)}-mymac`, email))); // truncated tag → no
});

test("clampInterval: finite, rounded, clamped to RemoteWakeConfig bounds (5..86400)", () => {
  // Bounds MUST equal the Swift RemoteWakeConfig min/maxInterval, or the reported
  // wake-ETA would diverge from the daemon's real cadence.
  assert.equal(MIN_INTERVAL, 5);
  assert.equal(MAX_INTERVAL, 86400);
  assert.equal(clampInterval(300), 300); // in range, untouched
  assert.equal(clampInterval(1), 5); // below floor → MIN
  assert.equal(clampInterval(999999), 86400); // above ceil → MAX
  assert.equal(clampInterval(7.6), 8); // rounded
  for (const bad of [undefined, null, "300", NaN, Infinity, {}])
    assert.equal(clampInterval(bad), null, String(bad)); // non-finite → reject (→ 400)
});

test("clampPct: finite, rounded, clamped to RemoteWakeConfig battery floor (0..100)", () => {
  assert.equal(clampPct(20), 20); // in range
  assert.equal(clampPct(-5), 0); // below → 0
  assert.equal(clampPct(150), 100); // above → 100
  assert.equal(clampPct(19.6), 20); // rounded
  for (const bad of [undefined, null, "20", NaN, Infinity])
    assert.equal(clampPct(bad), null, String(bad)); // non-finite → reject (→ 400)
});
