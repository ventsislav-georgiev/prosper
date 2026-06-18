import type { Middleware } from "./types";
import { nowSec, sha256Hex } from "./util";

/**
 * Require a valid opaque session token (Bearer). Sessions are stored hashed in
 * D1; on success the verified email is attached to the context.
 */
export const requireSession: Middleware = async (c, next) => {
  const header = c.req.header("Authorization") ?? "";
  const m = header.match(/^Bearer\s+(.+)$/i);
  if (!m) return c.json({ error: "unauthorized" }, 401);

  const hash = await sha256Hex(m[1]);
  const now = nowSec();
  const row = await c.env.DB.prepare(
    `SELECT email, expires_at FROM sessions WHERE token_hash = ?1`,
  )
    .bind(hash)
    .first<{ email: string; expires_at: number | null }>();

  if (!row || (row.expires_at !== null && row.expires_at < now)) {
    return c.json({ error: "unauthorized" }, 401);
  }

  c.set("email", row.email);
  c.executionCtx.waitUntil(
    c.env.DB.prepare(`UPDATE sessions SET last_seen = ?1 WHERE token_hash = ?2`)
      .bind(now, hash)
      .run(),
  );
  await next();
};
