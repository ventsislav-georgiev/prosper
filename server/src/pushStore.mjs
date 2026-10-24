// D1 side of live session status (#521): the bodies of POST/DELETE /push/tokens,
// POST /push/sessions and the every-minute cron, plus the push-row purges used by
// account.ts. Plain .mjs so `node --test` drives it against node:sqlite with a fake
// APNs. deps = {db: D1Database, send(push) -> "ok"|"drop"|"auth"|"error",
// now() -> unix seconds, defer(promise)}. Every query is scoped by the session email.

import {
  parseTokenBody,
  parseDeleteBody,
  parseSessionsBody,
  reduceSessions,
  cronStep,
  contentState,
  laPayload,
  startPayload,
  alertPayload,
  collapseId,
  cut,
  emptyMac,
  RATE_PER_MIN,
  LA_MAX_AGE_S,
  OFFLINE_DISMISS_S,
} from "./pushLogic.mjs";

const NO_CONTENT = { status: 204 };
const TOKEN_COLS = "email, device_id, kind, activity_id, token, env";
const MAC_COLS = "m.seq, m.last_seen, m.online, m.snapshot, m.last_push_at, m.last_alert, m.idle_since, m.started_at";

/** The Mac's display name, or null when mac_id is not an activated device of `email`. */
async function macName(db, email, macId) {
  const row = await db
    .prepare(`SELECT name FROM devices WHERE email = ?1 AND device_id = ?2`)
    .bind(email, macId)
    .first();
  return row ? cut(String(row.name || "Mac").toWellFormed(), 64) : null;
}

const fromRow = (r) => ({
  seq: r.seq,
  last_seen: r.last_seen,
  online: !!r.online,
  sessions: JSON.parse(r.snapshot),
  last_push_at: r.last_push_at,
  last_alert: JSON.parse(r.last_alert),
  idle_since: r.idle_since,
  started_at: r.started_at,
});

async function loadMac(db, email, macId) {
  const row = await db
    .prepare(`SELECT ${MAC_COLS}, m.rl_window, m.rl_count FROM push_macs m WHERE m.email = ?1 AND m.mac_id = ?2`)
    .bind(email, macId)
    .first();
  return row ? { mac: fromRow(row), rl_window: row.rl_window, rl_count: row.rl_count } : null;
}

async function tokens(db, where, ...binds) {
  const { results } = await db
    .prepare(`SELECT ${TOKEN_COLS} FROM push_tokens WHERE email = ?1 AND ${where}`)
    .bind(...binds)
    .all();
  return results;
}

/** Push-to-start targets: la_start tokens of phones holding no la_update for this Mac. */
async function startTokens(db, email, macId) {
  const { results } = await db
    .prepare(
      `SELECT ${TOKEN_COLS} FROM push_tokens s WHERE s.email = ?1 AND s.kind = 'la_start'
       AND NOT EXISTS (SELECT 1 FROM push_tokens u WHERE u.email = s.email
         AND u.device_id = s.device_id AND u.kind = 'la_update' AND u.mac_id = ?2)`,
    )
    .bind(email, macId)
    .all();
  return results;
}

async function dropTokens(db, rows) {
  if (!rows.length) return;
  await db.batch(
    rows.map((r) =>
      db
        .prepare(
          `DELETE FROM push_tokens WHERE email = ?1 AND device_id = ?2 AND kind = ?3
           AND activity_id = ?4 AND token = ?5`,
        )
        .bind(r.email, r.device_id, r.kind, r.activity_id, r.token),
    ),
  );
}

/** Send every push; tokens APNs calls dead (410, BadDeviceToken, DeviceTokenNotForTopic) are deleted. */
export async function deliver(deps, pushes) {
  const results = await Promise.all(pushes.map((p) => deps.send(p)));
  await dropTokens(
    deps.db,
    pushes.filter((_, i) => results[i] === "drop").map((p) => p.row),
  );
  return results;
}

const laPush = (row, priority, payload) => ({ row, pushType: "liveactivity", priority, payload });

/** Turn the intents of reduceSessions/cronStep into APNs pushes. */
async function dispatch(deps, email, macId, name, mac, push, now) {
  const { db } = deps;
  const cs = contentState(mac.sessions, mac.online);
  const pushes = [];
  const la = push.end || push.update ? await tokens(db, `kind = 'la_update' AND mac_id = ?2`, email, macId) : [];
  for (const row of la) {
    pushes.push(
      push.end
        ? laPush(row, 5, laPayload("end", cs, now, { "dismissal-date": push.end.dismissal }))
        : laPush(row, push.priority, laPayload("update", cs, now)),
    );
  }
  if (push.start) {
    for (const row of await startTokens(db, email, macId)) {
      pushes.push(laPush(row, push.priority, startPayload(cs, now, macId, name)));
    }
  }
  if (push.alerts.length) {
    const rows = await tokens(db, `kind = 'alert'`, email);
    for (const a of push.alerts) {
      const id = await collapseId(macId, a.name);
      for (const row of rows) {
        pushes.push({ row, pushType: "alert", priority: 10, payload: alertPayload(macId, name, a), collapseId: id });
      }
    }
  }
  await deliver(deps, pushes);
  if (push.end) await dropTokens(db, la); // an ended activity takes no more updates
}

/** POST /push/tokens */
export async function putToken(deps, email, body) {
  const p = parseTokenBody(body);
  if (p.error) return { status: 400, error: p.error };
  const v = p.value;
  const { db } = deps;
  let name = null;
  if (v.kind === "la_update") {
    name = await macName(db, email, v.mac_id);
    if (name === null) return { status: 403, error: "forbidden" };
  }
  const now = deps.now();
  const stmts = [
    db
      .prepare(
        `INSERT INTO push_tokens (email, device_id, kind, activity_id, mac_id, token, env, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
         ON CONFLICT(email, device_id, kind, activity_id) DO UPDATE SET
           mac_id = excluded.mac_id, token = excluded.token, env = excluded.env, updated_at = excluded.updated_at`,
      )
      .bind(email, v.device_id, v.kind, v.activity_id, v.mac_id, v.token, v.env, now),
  ];
  if (v.kind === "la_update") {
    // One card per phone per Mac: a newer activity replaces any older one's token.
    stmts.unshift(
      db
        .prepare(
          `DELETE FROM push_tokens WHERE email = ?1 AND device_id = ?2 AND kind = 'la_update'
           AND mac_id = ?3 AND activity_id != ?4`,
        )
        .bind(email, v.device_id, v.mac_id, v.activity_id),
    );
  }
  await db.batch(stmts);
  if (v.kind === "la_update") deps.defer(catchUp(deps, email, v, name, now));
  return NO_CONTENT;
}

/**
 * A card just registered its update token: bring it to the current state at once,
 * since the Mac may have changed since the push-to-start. A Mac that is offline (or
 * never posted) has no status to show, so the card ends instead.
 */
async function catchUp(deps, email, v, name, now) {
  const mac = (await loadMac(deps.db, email, v.mac_id))?.mac ?? emptyMac();
  const row = { email, device_id: v.device_id, kind: v.kind, activity_id: v.activity_id, token: v.token, env: v.env };
  if (mac.online) {
    await deliver(deps, [laPush(row, 5, laPayload("update", contentState(mac.sessions), now))]);
  } else {
    const cs = contentState([], false);
    await deliver(deps, [laPush(row, 5, laPayload("end", cs, now, { "dismissal-date": now + OFFLINE_DISMISS_S }))]);
    await dropTokens(deps.db, [row]);
  }
}

/** DELETE /push/tokens */
export async function deleteTokens(deps, email, body) {
  const p = parseDeleteBody(body);
  if (p.error) return { status: 400, error: p.error };
  const v = p.value;
  await deps.db
    .prepare(
      `DELETE FROM push_tokens WHERE email = ?1 AND device_id = ?2
       AND (?3 IS NULL OR kind = ?3) AND (?4 IS NULL OR activity_id = ?4)`,
    )
    .bind(email, v.device_id, v.kind, v.activity_id)
    .run();
  return NO_CONTENT;
}

/** POST /push/sessions */
export async function postSessions(deps, email, body) {
  const p = parseSessionsBody(body);
  if (p.error) return { status: 400, error: p.error };
  const v = p.value;
  const { db } = deps;
  const name = await macName(db, email, v.mac_id);
  if (name === null) return { status: 403, error: "forbidden" };

  const now = deps.now();
  const stored = await loadMac(db, email, v.mac_id);
  const win = Math.floor(now / 60);
  const count = stored && stored.rl_window === win ? stored.rl_count : 0;
  if (count >= RATE_PER_MIN) return { status: 429, error: "rate_limited" };

  const r = reduceSessions(stored?.mac ?? null, v, now);
  if (!r) {
    // Stale seq: ignored, but it still counts against the rate limit.
    await db
      .prepare(`UPDATE push_macs SET rl_window = ?3, rl_count = ?4 WHERE email = ?1 AND mac_id = ?2`)
      .bind(email, v.mac_id, win, count + 1)
      .run();
    return NO_CONTENT;
  }
  const m = r.mac;
  const res = await db
    .prepare(
      `INSERT INTO push_macs (email, mac_id, seq, last_seen, online, snapshot, last_push_at,
         last_alert, idle_since, started_at, rl_window, rl_count)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
       ON CONFLICT(email, mac_id) DO UPDATE SET
         seq = excluded.seq, last_seen = excluded.last_seen, online = excluded.online,
         snapshot = excluded.snapshot, last_push_at = excluded.last_push_at,
         last_alert = excluded.last_alert, idle_since = excluded.idle_since,
         started_at = excluded.started_at, rl_window = excluded.rl_window, rl_count = excluded.rl_count
       WHERE excluded.seq > push_macs.seq`,
    )
    .bind(
      email,
      v.mac_id,
      m.seq,
      m.last_seen,
      m.online ? 1 : 0,
      JSON.stringify(m.sessions),
      m.last_push_at,
      JSON.stringify(m.last_alert),
      m.idle_since,
      m.started_at,
      win,
      count + 1,
    )
    .run();
  if (!res.meta.changes) return NO_CONTENT; // a newer seq landed first
  deps.defer(dispatch(deps, email, v.mac_id, name, m, r.push, now));
  return NO_CONTENT;
}

/** The every-minute cron: lapse silent Macs, end idle cards, re-push old ones. */
export async function runCron(deps) {
  const { db } = deps;
  const now = deps.now();
  // iOS ends every Live Activity after 8 h; its token is dead even if never deleted,
  // and keeping it would block the next push-to-start for that Mac.
  await db
    .prepare(`DELETE FROM push_tokens WHERE kind = 'la_update' AND created_at <= ?1`)
    .bind(now - LA_MAX_AGE_S)
    .run();
  const { results } = await db
    .prepare(
      `SELECT m.email, m.mac_id, ${MAC_COLS}, d.name AS mac_name,
         EXISTS (SELECT 1 FROM push_tokens t WHERE t.email = m.email
           AND t.kind = 'la_update' AND t.mac_id = m.mac_id) AS has_card
       FROM push_macs m LEFT JOIN devices d ON d.email = m.email AND d.device_id = m.mac_id
       WHERE m.online = 1`,
    )
    .all();
  await Promise.allSettled(
    results.map(async (row) => {
      const r = cronStep(fromRow(row), !!row.has_card, now);
      if (!r) return;
      const res = await db
        .prepare(
          `UPDATE push_macs SET online = ?3, snapshot = ?4, idle_since = ?5, last_push_at = ?6
           WHERE email = ?1 AND mac_id = ?2 AND seq = ?7`,
        )
        .bind(row.email, row.mac_id, r.mac.online ? 1 : 0, JSON.stringify(r.mac.sessions), r.mac.idle_since, r.mac.last_push_at, row.seq)
        .run();
      if (!res.meta.changes) return; // the Mac posted meanwhile; its post decides
      await dispatch(deps, row.email, row.mac_id, cut(String(row.mac_name || "Mac").toWellFormed(), 64), r.mac, r.push, now);
    }),
  );
}

/** deleteDevice: the Mac's status row and every card showing it. */
export function purgeMacStatements(db, email, macId) {
  return [
    db.prepare(`DELETE FROM push_macs WHERE email = ?1 AND mac_id = ?2`).bind(email, macId),
    db.prepare(`DELETE FROM push_tokens WHERE email = ?1 AND kind = 'la_update' AND mac_id = ?2`).bind(email, macId),
  ];
}

/** deleteAccount: every push row of the account. */
export function purgeAccountStatements(db, email) {
  return [
    db.prepare(`DELETE FROM push_macs WHERE email = ?1`).bind(email),
    db.prepare(`DELETE FROM push_tokens WHERE email = ?1`).bind(email),
  ];
}
