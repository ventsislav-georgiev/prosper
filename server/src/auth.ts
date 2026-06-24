import { Hono } from "hono";
import type { Env } from "./types";
import { mintSupporterToken } from "./supporter";
import { sendMagicLinkEmail } from "./email";
import {
  intEnv,
  isValidEmail,
  normalizeEmail,
  nowSec,
  randomToken,
  sha256Hex,
} from "./util";

const auth = new Hono<Env>();

function page(title: string, body: string): string {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${title}</title></head>
  <body style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;background:#f5f5f7;margin:0">
    <div style="max-width:420px;margin:18vh auto;background:#fff;border-radius:16px;padding:32px;text-align:center;box-shadow:0 8px 30px rgba(0,0,0,.06)">
      <h1 style="margin:0 0 10px;font-size:22px">${title}</h1>
      <p style="margin:0;color:#6e6e73;line-height:1.5">${body}</p>
    </div>
  </body></html>`;
}

// Step 1: app submits an email; we email a one-time link and return a pickup id.
auth.post("/start", async (c) => {
  const body = await c.req.json<{ email?: string }>().catch(() => ({}) as { email?: string });
  const email = normalizeEmail(body.email ?? "");
  if (!isValidEmail(email)) return c.json({ error: "invalid_email" }, 400);

  // Light rate limit: 5 requests / 15 min per email.
  const rlKey = `rl:start:${email}`;
  const count = parseInt((await c.env.KV.get(rlKey)) ?? "0", 10);
  if (count >= 5) return c.json({ error: "rate_limited" }, 429);
  await c.env.KV.put(rlKey, String(count + 1), { expirationTtl: 900 });

  const ttl = intEnv(c.env.MAGIC_LINK_TTL_SECONDS, 900);
  const token = randomToken(32);
  const pickup = randomToken(16);

  await c.env.KV.put(
    `magic:${await sha256Hex(token)}`,
    JSON.stringify({ email, pickup }),
    { expirationTtl: ttl },
  );
  await c.env.KV.put(`pickup:${pickup}`, JSON.stringify({ status: "pending" }), {
    expirationTtl: ttl,
  });

  const verifyUrl = `${c.env.APP_BASE_URL}/auth/verify?token=${token}`;
  try {
    await sendMagicLinkEmail(c.env, email, verifyUrl);
  } catch (e) {
    return c.json({ error: "email_send_failed" }, 502);
  }
  return c.json({ pickup, expires_in: ttl });
});

// Step 2: user clicks the emailed link in a browser. We verify, create the
// session + supporter token, and stash them for the waiting app to pick up.
auth.get("/verify", async (c) => {
  const token = c.req.query("token");
  if (!token) return c.html(page("Invalid link", "This sign-in link is missing its token."), 400);

  const kvKey = `magic:${await sha256Hex(token)}`;
  const rec = await c.env.KV.get(kvKey);
  if (!rec) {
    return c.html(
      page("Link expired", "This link has expired or was already used. Request a new one from Prosper."),
      410,
    );
  }
  await c.env.KV.delete(kvKey); // one-time use

  const { email, pickup } = JSON.parse(rec) as { email: string; pickup: string };
  const now = nowSec();

  await c.env.DB.prepare(
    `INSERT INTO users (email, created_at) VALUES (?1, ?2)
     ON CONFLICT(email) DO UPDATE SET deleted_at = NULL`,
  )
    .bind(email, now)
    .run();

  const session = randomToken(32);
  const sessExp = now + intEnv(c.env.SESSION_TTL_DAYS, 365) * 86400;
  await c.env.DB.prepare(
    `INSERT INTO sessions (token_hash, email, created_at, last_seen, expires_at)
     VALUES (?1, ?2, ?3, ?3, ?4)`,
  )
    .bind(await sha256Hex(session), email, now, sessExp)
    .run();

  const supporter = await mintSupporterToken(c.env, email);
  await c.env.KV.put(
    `pickup:${pickup}`,
    JSON.stringify({ status: "ready", session, token: supporter.token, email }),
    { expirationTtl: 300 },
  );

  return c.html(page("You're signed in ✓", "Return to Prosper — it will pick up your session automatically."));
});

// Step 3: the app polls until the pickup is ready, then receives its credentials.
auth.post("/poll", async (c) => {
  const body = await c.req.json<{ pickup?: string }>().catch(() => ({}) as { pickup?: string });
  if (!body.pickup) return c.json({ error: "missing_pickup" }, 400);

  const rec = await c.env.KV.get(`pickup:${body.pickup}`);
  if (!rec) return c.json({ status: "expired" }, 410);

  const data = JSON.parse(rec) as {
    status: string;
    session?: string;
    token?: string;
    email?: string;
  };
  if (data.status !== "ready") return c.json({ status: "pending" });

  await c.env.KV.delete(`pickup:${body.pickup}`);
  return c.json({
    status: "ready",
    session: data.session,
    token: data.token,
    email: data.email,
  });
});

// Server-side logout: revoke this one session so a leaked Bearer token can't
// outlive the device's sign-out (sessions otherwise live up to SESSION_TTL_DAYS).
// Deletes by token_hash, not email, so other devices' sessions survive. Idempotent
// — an already-gone session still returns ok.
auth.post("/logout", async (c) => {
  const m = (c.req.header("Authorization") ?? "").match(/^Bearer\s+(.+)$/i);
  if (!m) return c.json({ error: "unauthorized" }, 401);
  await c.env.DB.prepare(`DELETE FROM sessions WHERE token_hash = ?1`)
    .bind(await sha256Hex(m[1]))
    .run();
  return c.json({ ok: true });
});

export default auth;
