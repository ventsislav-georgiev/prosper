// Pure, dependency-free wake-id rules — shared by the Worker (wake.ts) and unit
// tests. Plain .mjs (not .ts) so `node --test` runs it directly without a
// bundler/transpiler. The id is `<acctTag>-<devTag>`:
//   acctTag = sha256(account-email)[:16]  — OWNERSHIP. Re-derived server-side from
//             the authenticated session; POST is rejected unless the id carries it.
//   devTag  = a user-chosen handle (LAN/Tailscale IP, MagicDNS, hostname) — may hold
//             dots/colons, hence the widened charset below.

export const WAKE_ID_RE = /^[\w.\-:]{1,80}$/;

const toHex = (buf) =>
  [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

// Must match util.sha256Hex (SHA-256 → lowercase hex), sliced to 64 bits.
// Normalizes (trim + lowercase) FIRST — mirrors util.normalizeEmail and the app's
// LiveExtensionHostServices.wakeAcctTag. Today the stored session email is already
// normalized (auth.ts), so this is defense-in-depth: it keeps the acctTag contract
// self-contained on both ends, so a future auth path that stores a raw email can't
// silently 403 every wake POST against the device's normalized URL.
export async function acctTag(email) {
  const data = new TextEncoder().encode(email.trim().toLowerCase());
  return toHex(await crypto.subtle.digest("SHA-256", data)).slice(0, 16);
}

// True iff `id` belongs to `email`'s account namespace. The "-" anchor stops a
// short tag from prefix-matching a longer one (acctTag is fixed 16 hex chars).
export async function ownsWakeId(id, email) {
  return id.startsWith((await acctTag(email)) + "-");
}

// Wake cadence bounds, in seconds. MUST stay equal to RemoteWakeConfig's
// min/maxInterval (Swift) — the device reports its real cadence here for the wake-ETA
// UX, so a server clamp that diverges from the daemon's would show a wrong estimate.
export const MIN_INTERVAL = 5;
export const MAX_INTERVAL = 86400; // 1 day

// Validate a reported interval: a finite number, rounded + clamped in range, else null.
export function clampInterval(v) {
  const n = typeof v === "number" ? v : NaN;
  return Number.isFinite(n) ? Math.min(MAX_INTERVAL, Math.max(MIN_INTERVAL, Math.round(n))) : null;
}

// Validate a battery-floor percentage. MUST mirror RemoteWakeConfig's 0..100 clamp —
// it's reported so the client can warn the wake won't fire below it on battery.
export function clampPct(v) {
  const n = typeof v === "number" ? v : NaN;
  return Number.isFinite(n) ? Math.min(100, Math.max(0, Math.round(n))) : null;
}
