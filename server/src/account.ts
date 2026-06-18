import type { Ctx } from "./types";
import { intEnv, nowSec } from "./util";

type DeviceRow = {
  device_id: string;
  name: string | null;
  activated_at: number;
  last_seen: number;
};

/** Bind (or refresh) a device, enforcing a per-user soft cap. */
export async function activateDevice(c: Ctx) {
  const email = c.get("email");
  const body = await c.req
    .json<{ device_id?: string; name?: string }>()
    .catch(() => ({}) as { device_id?: string; name?: string });
  if (!body.device_id) return c.json({ error: "missing_device_id" }, 400);

  const now = nowSec();
  const limit = intEnv(c.env.DEVICE_LIMIT, 5);

  const existing = await c.env.DB.prepare(
    `SELECT device_id FROM devices WHERE email = ?1 AND device_id = ?2`,
  )
    .bind(email, body.device_id)
    .first();

  if (!existing) {
    const countRow = await c.env.DB.prepare(
      `SELECT COUNT(*) AS n FROM devices WHERE email = ?1`,
    )
      .bind(email)
      .first<{ n: number }>();
    if ((countRow?.n ?? 0) >= limit) {
      const devices = await c.env.DB.prepare(
        `SELECT device_id, name, activated_at, last_seen FROM devices
         WHERE email = ?1 ORDER BY last_seen DESC`,
      )
        .bind(email)
        .all<DeviceRow>();
      return c.json({ error: "device_limit", limit, devices: devices.results }, 409);
    }
  }

  await c.env.DB.prepare(
    `INSERT INTO devices (email, device_id, name, activated_at, last_seen)
     VALUES (?1, ?2, ?3, ?4, ?4)
     ON CONFLICT(email, device_id)
     DO UPDATE SET last_seen = ?4, name = COALESCE(?3, name)`,
  )
    .bind(email, body.device_id, body.name ?? null, now)
    .run();

  return c.json({ ok: true });
}

export async function listDevices(c: Ctx) {
  const email = c.get("email");
  const devices = await c.env.DB.prepare(
    `SELECT device_id, name, activated_at, last_seen FROM devices
     WHERE email = ?1 ORDER BY last_seen DESC`,
  )
    .bind(email)
    .all<DeviceRow>();
  return c.json({ devices: devices.results });
}

export async function deleteDevice(c: Ctx) {
  const email = c.get("email");
  const deviceId = c.req.param("id");
  await c.env.DB.prepare(`DELETE FROM devices WHERE email = ?1 AND device_id = ?2`)
    .bind(email, deviceId)
    .run();
  return c.json({ ok: true });
}

/**
 * GDPR account deletion: remove sessions, devices, and synced settings, and
 * tombstone the user. Supporter token rows are retained (financial records) but
 * no longer reference active sessions.
 */
export async function deleteAccount(c: Ctx) {
  const email = c.get("email");
  const now = nowSec();
  await c.env.DB.batch([
    c.env.DB.prepare(`DELETE FROM sessions WHERE email = ?1`).bind(email),
    c.env.DB.prepare(`DELETE FROM devices WHERE email = ?1`).bind(email),
    c.env.DB.prepare(`DELETE FROM settings WHERE email = ?1`).bind(email),
    c.env.DB.prepare(`UPDATE users SET deleted_at = ?2 WHERE email = ?1`).bind(email, now),
  ]);
  return c.json({ ok: true });
}
