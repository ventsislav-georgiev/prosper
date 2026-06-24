import { Hono } from "hono";
import type { Env } from "./types";
import { requireSession } from "./middleware";
import { WAKE_ID_RE, acctTag, ownsWakeId, clampInterval, clampPct } from "./wakeId.mjs";

// Remote-wake flag. The Mac polls GET on each scheduled dark wake; "1" -> it
// promotes to a full wake (see ProsperLidHelper). Another signed-in device sets
// the flag via POST. Outbound-only by design: no inbound, no WoL, works behind
// any NAT/CGNAT. Id format + ownership rules live in ./wakeId.mjs (unit-tested).
//
// Ownership is structural, no DB lookup: POST re-derives acctTag from the
// AUTHENTICATED session (never the URL) and requires the id to carry it — a
// session can only set wakes for its own account's devices.
//
// EDGE-TRIGGER BY TOKEN (not consume-on-read): POST stores a fresh opaque token as
// the value; GET returns it unchanged (a PURE READ — never mutates). The resident
// daemon remembers the last token it acted on and promotes only on a *new* one, so a
// request fires exactly once without the server deleting anything. This keeps GET
// unauthenticated AND safe: anyone who derives the id (the acctTag comes from a
// non-secret email) can only READ — they can't consume/suppress a pending wake, which
// a delete-on-read GET would have allowed. TTL is only a GC backstop for a token the
// device never polls; with edge-trigger dedupe a long TTL has no cost (a repeated token
// can't re-wake). It must outlast the WORST-CASE inter-poll gap, not the nominal: powerd
// coalesces/stretches dark wakes in deep standby (observed ~5× at the 5-min cadence), so
// the 1-day cadence option can slip well past 24h. 25h gave almost no margin and could
// expire a legit pending wake before the stretched poll → silent miss. 7 days is a safe
// GC horizon that no realistic standby stretch outlasts; the user can still POST "0" to
// clear early.
const SET_TTL = 604800; // 7 days — outlasts any standby-stretched poll gap (GC backstop)

export const wake = new Hono<Env>();

// Public poll, keyed by the device id. Tiny + uncached so the wake window stays
// short. Returns the current request token, or "0" when none. Pure read, no auth.
wake.get("/:id", async (c) => {
  const id = c.req.param("id");
  if (!WAKE_ID_RE.test(id)) return c.text("0", 404, { "cache-control": "no-store" });
  const tok = await c.env.KV.get(`wake:${id}`);
  return c.text(tok ?? "0", 200, { "cache-control": "no-store" });
});

// Authenticated trigger. Ownership: the id must start with this session's account
// tag (re-derived from the session, not the URL), so you can only wake your own
// devices. "1" arms a fresh token (the device wakes once per distinct token; TTL is a
// backstop). Any other body clears the flag.
wake.post("/:id", requireSession, async (c) => {
  const id = c.req.param("id");
  if (!WAKE_ID_RE.test(id)) return c.json({ error: "invalid_id" }, 400);
  if (!(await ownsWakeId(id, c.get("email")))) {
    return c.json({ error: "forbidden" }, 403);
  }
  // Rate limit per device id: a fresh token each POST forces a full wake on the
  // next dark-wake poll, so an unbounded trigger (e.g. a leaked session) is a remote
  // battery-drain. 30 / 15 min is far above any legit wake cadence. Mirrors rl:start.
  const rlKey = `rl:wake:${id}`;
  const count = parseInt((await c.env.KV.get(rlKey)) ?? "0", 10);
  if (count >= 30) return c.json({ error: "rate_limited" }, 429);
  await c.env.KV.put(rlKey, String(count + 1), { expirationTtl: 900 });
  const on = (await c.req.text()).trim() === "1";
  if (on) {
    // A fresh UUID each POST → distinct from whatever the device last acted on, so a
    // re-request after a prior wake fires again. Opaque to the device (compares !=).
    await c.env.KV.put(`wake:${id}`, crypto.randomUUID(), { expirationTtl: SET_TTL });
  } else {
    await c.env.KV.delete(`wake:${id}`);
  }
  return c.json({ ok: true, wake: on });
});

// --- Per-device wake metadata (for the triggering client's UX) ---
//
// The target Mac reports its remote-wake STATE here (whether it's armed + its poll
// cadence) so another signed-in device can tell, before triggering, whether the Mac
// can be woken at all and roughly how long it'll take. Same ownership gate as the
// trigger on BOTH read and write: unlike the poll (the session-less root daemon must
// read it publicly), meta is only ever read by the owner's other signed-in device, so
// requiring a session here costs the real flow nothing and stops a derived-id stranger
// from learning whether the feature is on and at what cadence. The client reads three
// states:
//   {known:false}              never configured / signed out — don't show a wake button
//   {enabled:false, ...}       set up but currently OFF — can't be woken right now
//   {enabled:true, intervalAC, intervalBatt, batteryFloor}  wakeable; estimate the ETA
//                              from the cadence. batteryFloor qualifies it: on battery
//                              below that %, the daemon won't promote, so the wake won't
//                              fire — the client should warn rather than promise.
// The clamps mirror RemoteWakeConfig (interval 5s..1 day, floor 0..100). Fields are kept
// even when disabled so the UX can still show "would wake in ~5 min when you turn it on".
// Written only on a toggle, and KV.get does NOT refresh the TTL — so this must outlast
// the longest an enabled device might sit untouched, or a still-armed Mac that nobody
// toggled for a while would expire to {known:false} and look un-wakeable. The daemon
// can't refresh it (the poll GET is a pure read). 1 year is a safe horizon; disable
// posts {enabled:false} and signOut deletes, so live devices are corrected promptly —
// the TTL only GCs a device retired without signing out.
const META_TTL = 31536000; // 1 year

wake.post("/:id/meta", requireSession, async (c) => {
  const id = c.req.param("id");
  if (!WAKE_ID_RE.test(id)) return c.json({ error: "invalid_id" }, 400);
  if (!(await ownsWakeId(id, c.get("email")))) return c.json({ error: "forbidden" }, 403);
  const body = (await c.req.json().catch(() => null)) as Record<string, unknown> | null;
  const intervalAC = clampInterval(body?.intervalAC);
  const intervalBatt = clampInterval(body?.intervalBatt);
  const batteryFloor = clampPct(body?.batteryFloor);
  if (intervalAC === null || intervalBatt === null || batteryFloor === null) {
    return c.json({ error: "invalid_meta" }, 400);
  }
  const enabled = body?.enabled === true;
  await c.env.KV.put(`wakemeta:${id}`, JSON.stringify({ enabled, intervalAC, intervalBatt, batteryFloor }), {
    expirationTtl: META_TTL,
  });
  return c.json({ ok: true });
});

wake.get("/:id/meta", requireSession, async (c) => {
  const id = c.req.param("id");
  if (!WAKE_ID_RE.test(id)) return c.json({ error: "invalid_id" }, 404);
  if (!(await ownsWakeId(id, c.get("email")))) return c.json({ error: "forbidden" }, 403);
  const raw = await c.env.KV.get(`wakemeta:${id}`);
  // `known` is always present so the client has one field to branch on: false = never
  // set up, true = read enabled/intervals. Parse our own validated JSON (guard a
  // corrupt row → treat as unknown rather than 500).
  if (raw) {
    try {
      const m = JSON.parse(raw);
      return c.json({ known: true, ...m }, 200, { "cache-control": "no-store" });
    } catch {
      /* fall through to known:false */
    }
  }
  return c.json({ known: false }, 200, { "cache-control": "no-store" });
});

// Removed only when the device signs out (account gone). A plain disable POSTs
// {enabled:false} instead, so the client can distinguish "off" from "never set up".
wake.delete("/:id/meta", requireSession, async (c) => {
  const id = c.req.param("id");
  if (!WAKE_ID_RE.test(id)) return c.json({ error: "invalid_id" }, 400);
  if (!(await ownsWakeId(id, c.get("email")))) return c.json({ error: "forbidden" }, 403);
  await c.env.KV.delete(`wakemeta:${id}`);
  return c.json({ ok: true });
});

export { acctTag }; // re-exported for callers/tests that need the tag directly
