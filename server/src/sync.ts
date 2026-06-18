import type { Ctx } from "./types";
import { intEnv, nowSec } from "./util";

type SettingsRow = { version: number; blob: string | null; updated_at: number };

/** Return the user's current settings blob + version (0 if none yet). */
export async function getSettings(c: Ctx) {
  const email = c.get("email");
  const row = await c.env.DB.prepare(
    `SELECT version, blob, updated_at FROM settings WHERE email = ?1`,
  )
    .bind(email)
    .first<SettingsRow>();
  if (!row) return c.json({ version: 0, blob: null, updated_at: 0 });
  return c.json(row);
}

/**
 * Optimistic-concurrency write. The client sends the version it last saw as
 * `base_version`; if it still matches, we store and bump. Otherwise we return
 * 409 with the current server state so the client can merge and retry.
 */
export async function putSettings(c: Ctx) {
  const email = c.get("email");
  const body = await c.req
    .json<{ base_version?: number; blob?: string }>()
    .catch(() => null);
  if (!body || typeof body.base_version !== "number" || typeof body.blob !== "string") {
    return c.json({ error: "invalid_body" }, 400);
  }

  const max = intEnv(c.env.SYNC_MAX_BYTES, 1_048_576);
  if (new TextEncoder().encode(body.blob).length > max) {
    return c.json({ error: "too_large", max }, 413);
  }

  const row = await c.env.DB.prepare(`SELECT version FROM settings WHERE email = ?1`)
    .bind(email)
    .first<{ version: number }>();
  const current = row?.version ?? 0;

  if (body.base_version !== current) {
    const full = await c.env.DB.prepare(
      `SELECT version, blob, updated_at FROM settings WHERE email = ?1`,
    )
      .bind(email)
      .first<SettingsRow>();
    return c.json(
      {
        error: "conflict",
        version: full?.version ?? 0,
        blob: full?.blob ?? null,
        updated_at: full?.updated_at ?? 0,
      },
      409,
    );
  }

  const next = current + 1;
  const now = nowSec();
  await c.env.DB.prepare(
    `INSERT INTO settings (email, version, blob, updated_at)
     VALUES (?1, ?2, ?3, ?4)
     ON CONFLICT(email) DO UPDATE SET version = ?2, blob = ?3, updated_at = ?4`,
  )
    .bind(email, next, body.blob, now)
    .run();

  return c.json({ version: next, updated_at: now });
}
