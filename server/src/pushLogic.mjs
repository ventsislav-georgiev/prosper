// Pure live-status rules (#521): body validation, the Live Activity content-state,
// edge detection, the cron's lapse/end/re-push decision, APNs payloads, the APNs
// response classification and the ES256 provider JWT. Plain .mjs (like wakeId.mjs)
// so `node --test` imports it raw. The D1 side lives in pushStore.mjs.

export const MAX_SESSIONS = 20; // per POST /push/sessions
export const CARD_SESSIONS = 6; // shown on the card, the rest is `more`
export const CUT = 40; // name/alias characters inside the content-state
export const ALERT_LIMIT_S = 120; // one "needs you" alert per session per 120 s
export const LAPSE_S = 180; // no heartbeat for this long = offline
export const IDLE_END_S = 600; // nothing working/blocked this long ends the card
export const REPUSH_S = 600; // re-push a live card whose last push is older
export const STALE_S = 900; // stale-date = now + 15 min
export const OFFLINE_DISMISS_S = 600; // an offline card stays 10 min, then goes
export const START_GAP_S = 60; // no second push-to-start while the first is landing
export const RATE_PER_MIN = 60; // POST /push/sessions per Mac per minute
export const LA_MAX_AGE_S = 8 * 3600; // iOS ends any Live Activity after 8 h
export const ATTRIBUTES_TYPE = "ProsperSessionsAttributes";

const RANK = { blocked: 0, working: 1, done: 2, idle: 3 }; // Agent Island urgency
const KINDS = ["alert", "la_start", "la_update"];
const ENVS = ["production", "sandbox"];
const PHONE_ID_RE = /^[A-Za-z0-9-]{8,64}$/; // phone install id (a UUID is 36)
const ID_RE = /^[A-Za-z0-9._:-]{1,128}$/; // mac_id (64 hex today), activity_id
const TOKEN_RE = /^[0-9A-Fa-f]{16,512}$/;
const CTRL_RE = /[\u0000-\u001f\u007f]/;
// Printable, well-formed text: a lone surrogate would re-escape to 6 bytes in the
// payload and break the 4 KB budget; a control character has no business in a name.
const isText = (s, max, min = 0) =>
  typeof s === "string" && s.isWellFormed() && !CTRL_RE.test(s) && [...s].length >= min && [...s].length <= max;

const absent = (v) => v === undefined || v === null;
const isId = (v, re = ID_RE) => typeof v === "string" && re.test(v);
const isObj = (v) => !!v && typeof v === "object" && !Array.isArray(v);
const bad = (error) => ({ error });

/** POST /push/tokens body -> {value} or {error}. */
export function parseTokenBody(b) {
  if (!isObj(b)) return bad("invalid_body");
  if (!isId(b.device_id, PHONE_ID_RE)) return bad("invalid_device_id");
  if (!KINDS.includes(b.kind)) return bad("invalid_kind");
  if (!isId(b.token, TOKEN_RE)) return bad("invalid_token");
  if (!ENVS.includes(b.env)) return bad("invalid_env");
  if (b.kind === "la_update") {
    if (!isId(b.activity_id)) return bad("invalid_activity_id");
    if (!isId(b.mac_id)) return bad("invalid_mac_id");
  } else if (!absent(b.activity_id) || !absent(b.mac_id)) {
    return bad("unexpected_field"); // only la_update carries an activity/mac
  }
  return {
    value: {
      device_id: b.device_id,
      kind: b.kind,
      token: b.token,
      env: b.env,
      activity_id: b.kind === "la_update" ? b.activity_id : "",
      mac_id: b.kind === "la_update" ? b.mac_id : null,
    },
  };
}

/** DELETE /push/tokens body -> {value} or {error}. */
export function parseDeleteBody(b) {
  if (!isObj(b)) return bad("invalid_body");
  if (!isId(b.device_id, PHONE_ID_RE)) return bad("invalid_device_id");
  if (!absent(b.kind) && !KINDS.includes(b.kind)) return bad("invalid_kind");
  if (!absent(b.activity_id) && !isId(b.activity_id)) return bad("invalid_activity_id");
  if (!absent(b.activity_id) && !absent(b.kind) && b.kind !== "la_update") return bad("unexpected_field");
  return { value: { device_id: b.device_id, kind: b.kind ?? null, activity_id: b.activity_id ?? null } };
}

function parseSession(s) {
  if (!isObj(s)) return null;
  const { name, alias, state, agents } = s;
  if (!isText(name, 64, 1)) return null;
  if (!absent(alias) && !isText(alias, 64)) return null;
  if (typeof state !== "string" || !Object.hasOwn(RANK, state)) return null;
  if (!absent(agents) && !(Number.isSafeInteger(agents) && agents >= 0 && agents <= 999)) return null;
  const out = { name, state };
  if (alias) out.alias = alias;
  if (!absent(agents)) out.agents = agents;
  return out;
}

/** POST /push/sessions body -> {value: {mac_id, seq, offline, sessions|null}} or {error}. */
export function parseSessionsBody(b) {
  if (!isObj(b)) return bad("invalid_body");
  if (!isId(b.mac_id)) return bad("invalid_mac_id");
  if (!Number.isSafeInteger(b.seq) || b.seq <= 0) return bad("invalid_seq");
  if (!absent(b.offline) && typeof b.offline !== "boolean") return bad("invalid_offline");
  if (!absent(b.sessions) && !Array.isArray(b.sessions)) return bad("invalid_sessions");
  if (b.offline === true && !absent(b.sessions)) return bad("offline_with_sessions");
  let sessions = null;
  if (Array.isArray(b.sessions)) {
    if (b.sessions.length > MAX_SESSIONS) return bad("too_many_sessions");
    sessions = [];
    const seen = new Set();
    for (const raw of b.sessions) {
      const s = parseSession(raw);
      if (!s) return bad("invalid_session");
      if (seen.has(s.name)) return bad("duplicate_session");
      seen.add(s.name);
      sessions.push(s);
    }
  }
  return { value: { mac_id: b.mac_id, seq: b.seq, offline: b.offline === true, sessions } };
}

/** First `n` code points (never splits a surrogate pair). */
export function cut(s, n = CUT) {
  const cps = [...s];
  return cps.length > n ? cps.slice(0, n).join("") : s;
}

export const isActive = (sessions) => sessions.some((s) => s.state === "working" || s.state === "blocked");

/** The Live Activity content-state the phone decodes (contract v1). No timestamps. */
export function contentState(sessions, online = true) {
  const counts = { blocked: 0, working: 0, idle: 0, done: 0 };
  for (const s of sessions) counts[s.state]++;
  const top = [...sessions]
    .sort((a, b) => RANK[a.state] - RANK[b.state] || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
    .slice(0, CARD_SESSIONS)
    .map((s) => {
      const o = { name: cut(s.name) };
      if (s.alias) o.alias = cut(s.alias);
      o.state = s.state;
      if (s.agents !== undefined) o.agents = s.agents;
      return o;
    });
  return { v: 1, online, counts, sessions: top, more: sessions.length - top.length };
}

export const emptyMac = () => ({
  seq: 0,
  last_seen: 0,
  online: false,
  sessions: [],
  last_push_at: null,
  last_alert: {},
  idle_since: null,
  started_at: null,
});

const noPush = () => ({ start: false, update: false, priority: 5, end: null, alerts: [] });

/**
 * Apply one validated POST /push/sessions to the stored Mac state. Returns null for
 * a stale seq (at or below the stored one), else {mac, push}: the next state and
 * what to send. push.end = {dismissal} ends every card of the Mac; push.start asks
 * for push-to-start where a phone has no card; push.alerts are "needs you" alerts.
 */
export function reduceSessions(prev, input, now) {
  if (prev && input.seq <= prev.seq) return null;
  const base = prev ?? emptyMac();
  const mac = { ...base, seq: input.seq, last_seen: now };
  const push = noPush();

  if (input.offline) {
    Object.assign(mac, { online: false, sessions: [], idle_since: null });
    push.end = { dismissal: now + OFFLINE_DISMISS_S };
    return { mac, push };
  }
  if (!input.sessions) {
    // Heartbeat: liveness only. After a lapse the snapshot is empty until the next
    // sessions post (absent, never stale).
    mac.online = true;
    if (!base.online) mac.idle_since = isActive(mac.sessions) ? null : now;
    return { mac, push };
  }

  const before = base.online ? base.sessions : [];
  const after = input.sessions;
  const prevState = new Map(before.map((s) => [s.name, s.state]));
  const entered = after.filter((s) => s.state === "blocked" && prevState.get(s.name) !== "blocked");

  const lastAlert = {};
  for (const [name, t] of Object.entries(base.last_alert)) if (now - t < ALERT_LIMIT_S) lastAlert[name] = t;
  for (const s of entered) {
    if (lastAlert[s.name] !== undefined) continue; // alerted under 120 s ago
    lastAlert[s.name] = now;
    push.alerts.push({ name: s.name, label: s.alias || s.name });
  }

  const startEdge = (isActive(after) && !isActive(before)) || entered.length > 0;
  push.start = startEdge && !(base.started_at !== null && now - base.started_at < START_GAP_S);
  push.update =
    !base.online || JSON.stringify(contentState(before)) !== JSON.stringify(contentState(after));
  push.priority = entered.length > 0 ? 10 : 5;

  mac.online = true;
  mac.sessions = after;
  mac.last_alert = lastAlert;
  mac.idle_since = isActive(after) ? null : base.online && base.idle_since !== null ? base.idle_since : now;
  if (push.start) mac.started_at = now;
  if (push.start || push.update) mac.last_push_at = now;
  return { mac, push };
}

/**
 * The every-minute cron for one online Mac. hasCard = some phone holds a la_update
 * token for it. Returns null (nothing to do) or {kind, mac, push}:
 *  lapse  - no heartbeat for 180 s: offline, cards end with online:false, dismissal +600;
 *  end    - nothing working/blocked for 10 min: cards end now;
 *  repush - last push over 10 min ago: same state again so the stale-date moves.
 */
export function cronStep(mac, hasCard, now) {
  if (!mac.online) return null;
  const push = noPush();
  if (now - mac.last_seen >= LAPSE_S) {
    push.end = { dismissal: now + OFFLINE_DISMISS_S };
    return { kind: "lapse", mac: { ...mac, online: false, sessions: [], idle_since: null }, push };
  }
  if (!hasCard) return null;
  if (mac.idle_since !== null && now - mac.idle_since >= IDLE_END_S) {
    push.end = { dismissal: now };
    return { kind: "end", mac: { ...mac, last_push_at: now }, push };
  }
  if (now - (mac.last_push_at ?? 0) >= REPUSH_S) {
    push.update = true;
    return { kind: "repush", mac: { ...mac, last_push_at: now }, push };
  }
  return null;
}

/** A Live Activity payload: every one carries aps.timestamp and stale-date. */
export function laPayload(event, cs, now, extra = {}) {
  return { aps: { timestamp: now, event, "content-state": cs, "stale-date": now + STALE_S, ...extra } };
}

export function startPayload(cs, now, macId, macName) {
  return laPayload("start", cs, now, {
    "attributes-type": ATTRIBUTES_TYPE,
    attributes: { mac_id: macId, mac_name: macName },
    alert: { title: macName, body: "Agents are working" }, // iOS requires one; no sound
  });
}

export function alertPayload(macId, macName, alert) {
  return {
    aps: { alert: { title: macName, body: `${alert.label} needs you` }, sound: "default", "thread-id": macId },
    mac_id: macId,
    session: alert.name,
  };
}

/** apns-collapse-id: a hash of mac_id + session name (32 hex, under the 64-byte cap). */
export async function collapseId(macId, name) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${macId}\n${name}`));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 32);
}

/** ok | drop (delete the token) | auth (provider JWT rejected) | error. */
export function classifyApns(status, reason) {
  if (status === 200) return "ok";
  if (status === 410) return "drop";
  if (status === 400 && (reason === "BadDeviceToken" || reason === "DeviceTokenNotForTopic")) return "drop";
  if (status === 403 && (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken")) return "auth";
  return "error";
}

export const apnsHost = (env) => (env === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com");

/**
 * Send one push through `fetchFn` (the only way out to APNs; tests inject it).
 * p = {row: {token, env}, pushType: "alert"|"liveactivity", priority, payload, collapseId?}.
 */
export async function sendApns(fetchFn, { jwt, topic }, p) {
  const headers = {
    authorization: `bearer ${jwt}`,
    "apns-topic": p.pushType === "liveactivity" ? `${topic}.push-type.liveactivity` : topic,
    "apns-push-type": p.pushType,
    "apns-priority": String(p.priority),
    "content-type": "application/json",
  };
  if (p.collapseId) headers["apns-collapse-id"] = p.collapseId;
  let res;
  try {
    res = await fetchFn(`https://${apnsHost(p.row.env)}/3/device/${p.row.token}`, {
      method: "POST",
      headers,
      body: JSON.stringify(p.payload),
    });
  } catch {
    return "error";
  }
  if (res.status === 200) return "ok";
  const reason = await res
    .json()
    .then((j) => (typeof j?.reason === "string" ? j.reason : ""))
    .catch(() => "");
  return classifyApns(res.status, reason);
}

const b64url = (bytes) => {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

/** Import the .p8 (PKCS#8 PEM, P-256) APNs auth key for signing. */
export function importP8(pem) {
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) =>
    c.charCodeAt(0),
  );
  return crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

/** APNs provider token: ES256 JWT, header {alg, kid}, claims {iss: team, iat}. */
export async function signApnsJwt(key, keyId, teamId, iat) {
  const enc = (o) => b64url(new TextEncoder().encode(JSON.stringify(o)));
  const input = `${enc({ alg: "ES256", kid: keyId })}.${enc({ iss: teamId, iat })}`;
  // WebCrypto ECDSA returns raw r||s (IEEE P1363), which is exactly the JWS form.
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  return `${input}.${b64url(new Uint8Array(sig))}`;
}
