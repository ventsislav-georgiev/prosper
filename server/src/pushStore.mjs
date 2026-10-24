// D1 side of live session status (#521): the bodies of POST/DELETE /push/tokens,
// POST /push/sessions and the every-minute cron, plus the push-row purges used by
// account.ts, auth.ts (logout) and the daily cleanup. Plain .mjs so `node --test`
// drives it against node:sqlite with a fake APNs. deps = {db: D1Database,
// send(push) -> "ok"|"drop"|"auth"|"error", now() -> unix seconds, defer(promise),
// budget?: subrequests per cron run, APNs + D1}. Every query is scoped by the session email.
//
// Free plan: 50 subrequests per invocation, D1 queries (a batch is one) and APNs
// fetches alike. A post spends at most 2 (requireSession) + 9 D1 (device, 2 x load and
// upsert, card/start/alert SELECTs, one drop batch) + 20 sends (per phone: one card
// update or start, one alert); a cron run, 2 + its budget.

import {
  parseTokenBody,
  parseDeleteBody,
  parseSessionsBody,
  reduceSessions,
  contentState,
  laPayload,
  startPayload,
  alertPayload,
  collapseId,
  cleanMacName,
  emptyMac,
  planCron,
  RATE_PER_MIN,
  LA_MAX_AGE_S,
  OFFLINE_DISMISS_S,
  MAX_PHONES,
  CRON_BUDGET,
} from "./pushLogic.mjs";

const NO_CONTENT = { status: 204 };
const TOKEN_COLS = "email, device_id, kind, activity_id, token, env";
const MAC_COLS =
  "m.seq, m.last_seen, m.online, m.snapshot, m.last_push_at, m.last_alert, m.idle_since, m.started_at, m.blocked, m.rev";

/** The Mac's display name, or null when mac_id is not an activated device of `email`. */
async function macName(db, email, macId) {
  const row = await db
    .prepare(`SELECT name FROM devices WHERE email = ?1 AND device_id = ?2`)
    .bind(email, macId)
    .first();
  return row ? cleanMacName(row.name) : null;
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
  blocked: JSON.parse(r.blocked),
});

async function loadMac(db, email, macId) {
  const row = await db
    .prepare(`SELECT ${MAC_COLS}, m.rl_window, m.rl_count FROM push_macs m WHERE m.email = ?1 AND m.mac_id = ?2`)
    .bind(email, macId)
    .first();
  return row ? { mac: fromRow(row), rev: row.rev, rl_window: row.rl_window, rl_count: row.rl_count } : null;
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

/**
 * Send every push; tokens APNs calls dead (410, BadDeviceToken, DeviceTokenNotForTopic)
 * are deleted, together with `alsoDrop`, in one batch (one subrequest).
 */
export async function deliver(deps, pushes, alsoDrop = []) {
  const results = await Promise.all(pushes.map((p) => deps.send(p)));
  const dead = pushes.filter((_, i) => results[i] === "drop").map((p) => p.row);
  await dropTokens(deps.db, [...alsoDrop, ...dead]); // a row twice is deleted once
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
    // One alert per phone per post, whatever the number of sessions entering blocked.
    const payload = alertPayload(macId, name, push.alerts);
    const id = await collapseId(macId, push.alerts.length > 1 ? undefined : push.alerts[0].name);
    for (const row of await tokens(db, `kind = 'alert'`, email)) {
      pushes.push({ row, pushType: "alert", priority: 10, payload, collapseId: id });
    }
  }
  await deliver(deps, pushes, push.end ? la : []); // an ended activity takes no more updates
}

/** POST /push/tokens. tokenHash = the session's token_hash: logout and expiry take the row. */
export async function putToken(deps, email, body, tokenHash) {
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
        `INSERT INTO push_tokens (email, device_id, kind, activity_id, mac_id, token, env, created_at, updated_at, token_hash)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, ?9)
         ON CONFLICT(email, device_id, kind, activity_id) DO UPDATE SET
           mac_id = excluded.mac_id, token = excluded.token, env = excluded.env,
           updated_at = excluded.updated_at, token_hash = excluded.token_hash`,
      )
      .bind(email, v.device_id, v.kind, v.activity_id, v.mac_id, v.token, v.env, now, tokenHash),
    // At most MAX_PHONES install ids per account: past that, the least recently
    // updated phones go with all their rows, so a reinstalled phone always gets in.
    // max(0, ...): a negative LIMIT is no limit in SQLite.
    db
      .prepare(
        `DELETE FROM push_tokens WHERE email = ?1 AND device_id IN (
           SELECT device_id FROM push_tokens WHERE email = ?1 AND device_id != ?2
           GROUP BY device_id ORDER BY MAX(updated_at), device_id
           LIMIT max(0, (SELECT COUNT(DISTINCT device_id) FROM push_tokens WHERE email = ?1) - ?3))`,
      )
      .bind(email, v.device_id, MAX_PHONES),
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
    await deliver(deps, [laPush(row, 5, laPayload("end", cs, now, { "dismissal-date": now + OFFLINE_DISMISS_S }))], [row]);
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

/**
 * POST /push/sessions. The upsert is conditional on the rev it loaded: when the cron
 * (a lapse) or another post wrote the row in between, this post reloads and reduces
 * once more, so it never overwrites a write it did not see.
 */
export async function postSessions(deps, email, body) {
  const now = deps.now();
  const p = parseSessionsBody(body, now);
  if (p.error) return { status: 400, error: p.error };
  const v = p.value;
  const { db } = deps;
  const name = await macName(db, email, v.mac_id);
  if (name === null) return { status: 403, error: "forbidden" };

  const win = Math.floor(now / 60);
  for (let attempt = 0; attempt < 2; attempt++) {
    const stored = await loadMac(db, email, v.mac_id);
    const count = stored && stored.rl_window === win ? stored.rl_count : 0;
    if (count >= RATE_PER_MIN) return { status: 429, error: "rate_limited" };

    const r = reduceSessions(stored?.mac ?? null, v, now);
    if (!r) {
      // Stale seq: ignored, but it still counts against the rate limit. The counter
      // alone is not rev-guarded: a lost increment is harmless, and bumping rev here
      // would let a stream of stale posts starve the cron's lapse of this Mac.
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
           last_alert, idle_since, started_at, rl_window, rl_count, blocked, rev)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, 1)
         ON CONFLICT(email, mac_id) DO UPDATE SET
           seq = excluded.seq, last_seen = excluded.last_seen, online = excluded.online,
           snapshot = excluded.snapshot, last_push_at = excluded.last_push_at,
           last_alert = excluded.last_alert, idle_since = excluded.idle_since,
           started_at = excluded.started_at, rl_window = excluded.rl_window, rl_count = excluded.rl_count,
           blocked = excluded.blocked, rev = push_macs.rev + 1
         WHERE push_macs.rev = ?14`,
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
        JSON.stringify(m.blocked),
        stored ? stored.rev : -1, // no row loaded: a row inserted meanwhile never matches
      )
      .run();
    if (res.meta.changes) {
      deps.defer(dispatch(deps, email, v.mac_id, name, m, r.push, now));
      return NO_CONTENT;
    }
  }
  return NO_CONTENT; // lost twice: the Mac's next post (60 s at most) carries the state
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
         (SELECT COUNT(*) FROM push_tokens t WHERE t.email = m.email
           AND t.kind = 'la_update' AND t.mac_id = m.mac_id) AS cards
       FROM push_macs m LEFT JOIN devices d ON d.email = m.email AND d.device_id = m.mac_id
       WHERE m.online = 1`,
    )
    .all();
  // One invocation serves every account, so its subrequests are budgeted (a run past
  // the cap would fail everyone's pushes); what does not fit runs next minute.
  const plan = planCron(
    results.map((row) => ({ ...row, mac: fromRow(row) })),
    now,
    deps.budget ?? CRON_BUDGET,
  );
  await Promise.allSettled(
    plan.map(async ({ row, mac, push }) => {
      const res = await db
        .prepare(
          `UPDATE push_macs SET online = ?3, snapshot = ?4, idle_since = ?5, last_push_at = ?6, rev = rev + 1
           WHERE email = ?1 AND mac_id = ?2 AND rev = ?7`,
        )
        .bind(row.email, row.mac_id, mac.online ? 1 : 0, JSON.stringify(mac.sessions), mac.idle_since, mac.last_push_at, row.rev)
        .run();
      if (!res.meta.changes) return; // the Mac posted meanwhile; its post decides
      await dispatch(deps, row.email, row.mac_id, cleanMacName(row.mac_name), mac, push, now);
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

/** POST /auth/logout: the session and every push token it registered. */
export function logoutStatements(db, tokenHash) {
  return [
    db.prepare(`DELETE FROM sessions WHERE token_hash = ?1`).bind(tokenHash),
    db.prepare(`DELETE FROM push_tokens WHERE token_hash = ?1`).bind(tokenHash),
  ];
}

/** The daily cleanup: expired sessions, then push tokens whose session is gone. */
export function sessionCleanupStatements(db, now) {
  return [
    db.prepare(`DELETE FROM sessions WHERE expires_at IS NOT NULL AND expires_at < ?1`).bind(now),
    db.prepare(
      `DELETE FROM push_tokens WHERE NOT EXISTS (SELECT 1 FROM sessions s WHERE s.token_hash = push_tokens.token_hash)`,
    ),
  ];
}
