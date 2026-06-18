import type { Ctx } from "./types";
import { hmacSha256Hex, nowSec, normalizeEmail, timingSafeEqual } from "./util";

/**
 * Lemon Squeezy webhook. Verifies the HMAC-SHA256 signature over the raw body,
 * then upserts a perpetual supporter token on purchase (idempotent by order
 * id) and marks it refunded on refund.
 *
 * Configure the webhook in Lemon Squeezy to POST here with the signing secret
 * stored as LEMONSQUEEZY_WEBHOOK_SECRET.
 */
export async function lemonSqueezyWebhook(c: Ctx) {
  const body = await c.req.text();
  const signature = c.req.header("X-Signature") ?? "";
  const expected = await hmacSha256Hex(c.env.LEMONSQUEEZY_WEBHOOK_SECRET, body);
  if (!signature || !timingSafeEqual(signature, expected)) {
    return c.json({ error: "bad_signature" }, 401);
  }

  let evt: any;
  try {
    evt = JSON.parse(body);
  } catch {
    return c.json({ error: "invalid_json" }, 400);
  }

  const eventName: string = evt?.meta?.event_name ?? "";
  const attrs = evt?.data?.attributes ?? {};
  const email = normalizeEmail(attrs.user_email ?? attrs.email ?? "");
  const orderId = String(evt?.data?.id ?? attrs.order_id ?? "");
  // Display name shown in the app's About supporters list. Fall back through the
  // fields Lemon Squeezy may populate; trimmed, never the email.
  const name = String(attrs.user_name ?? attrs.name ?? "").trim().slice(0, 60);
  const now = nowSec();

  if (!email || !orderId) return c.json({ ok: true, skipped: "missing_fields" });

  if (eventName === "order_created") {
    await c.env.DB.batch([
      c.env.DB.prepare(
        `INSERT INTO users (email, created_at) VALUES (?1, ?2)
         ON CONFLICT(email) DO NOTHING`,
      ).bind(email, now),
      c.env.DB.prepare(
        `INSERT INTO supporter_tokens (id, email, type, status, source, order_id, name, issued_at, expires_at)
         VALUES (?1, ?2, 'supporter', 'active', 'lemonsqueezy', ?3, ?4, ?5, NULL)
         ON CONFLICT(id) DO NOTHING`,
      ).bind(`ls_${orderId}`, email, orderId, name, now),
    ]);
  } else if (eventName === "order_refunded") {
    await c.env.DB.prepare(
      `UPDATE supporter_tokens SET status = 'refunded'
       WHERE order_id = ?1 AND source = 'lemonsqueezy'`,
    )
      .bind(orderId)
      .run();
  }

  return c.json({ ok: true });
}
