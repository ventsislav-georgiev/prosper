import { Hono } from "hono";
import type { Ctx, Env } from "./types";
import { signDetached } from "./jwt";
import { requireSession } from "./middleware";
import { hmacSha256Hex, intEnv, normalizeEmail, nowSec } from "./util";

/**
 * Extension marketplace. Authenticated publish + public browse/download, all on
 * the existing Worker. Artifact bytes live in KV; the searchable index and
 * signed metadata live in D1 (see migrations/0004_market.sql).
 *
 * Trust is split in two:
 *  - Integrity: sha256 of the gzipped tarball, recomputed by the app on download.
 *  - Authenticity: an Ed25519 detached signature over a canonical CLAIM that
 *    binds the bytes to (id, version, publisher). Signed here with
 *    SUPPORTER_SIGNING_JWK; verified offline by the app's embedded public key.
 *    Binding sha256 <-> (id, version) stops a bytes-under-the-wrong-listing swap.
 *
 * Publish trusts the client-parsed manifest (Option B in the plan): the app
 * already parsed the TOML locally, so it sends the manifest as JSON and the
 * tarball as base64. The server treats the tarball as opaque and signs its bytes.
 */
const market = new Hono<Env>();

/** The exact message the signature covers. Reproduced byte-for-byte in the app
 *  (RemoteInstaller.marketClaimMessage). Newline-delimited to avoid any
 *  cross-language JSON canonicalization ambiguity. `publisher_email` is the
 *  masked publisherValue since #1138 (the app treats it as an opaque string);
 *  rows signed before that carry the e-mail (see download). */
function claimMessage(p: {
  id: string;
  version: string;
  sha256: string;
  publisher_email: string;
  published_at: number;
}): string {
  return [
    "prosper-market-v1",
    p.id,
    p.version,
    p.sha256,
    p.publisher_email,
    String(p.published_at),
  ].join("\n");
}

/** #1138: the publisher value the claim and the download carry instead of the
 *  e-mail. "pub_" + 16 hex of HMAC-SHA256 over the lower-cased e-mail, keyed by
 *  the signing key's private part under its own label: stable per publisher, and
 *  guessing an address does not reproduce it without the server's key. */
async function publisherValue(jwkStr: string, email: string): Promise<string> {
  const d = (JSON.parse(jwkStr) as JsonWebKey).d;
  if (!d) throw new Error("SUPPORTER_SIGNING_JWK has no private part");
  const mac = await hmacSha256Hex(`prosper-market-publisher-v1:${d}`, normalizeEmail(email));
  return `pub_${mac.slice(0, 16)}`;
}

/** Ed25519 check of a detached base64url signature with the signing key's public part. */
async function verifyClaim(jwkStr: string, message: string, sigB64url: string): Promise<boolean> {
  const { kty, crv, x } = JSON.parse(jwkStr) as JsonWebKey;
  const key = await crypto.subtle.importKey("jwk", { kty, crv, x }, { name: "Ed25519" }, false, ["verify"]);
  const sig = b64ToBytes(sigB64url.replace(/-/g, "+").replace(/_/g, "/"));
  return crypto.subtle.verify("Ed25519", key, sig, new TextEncoder().encode(message));
}

type ManifestInput = {
  id?: string;
  name?: string;
  title?: string;
  description?: string;
  version?: string;
  author?: string;
  icon?: string | null;
  license?: string | null;
  system?: boolean;
};

const ID_RE = /^[a-z0-9]+(\.[a-z0-9-]+)+$/i; // reverse-DNS-ish
const SEMVER_RE = /^\d+\.\d+\.\d+([-+].+)?$/;

/** Decode a base64 string to bytes (Workers has atob). */
function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// POST /market/publish — create a package or push a new version.
async function publish(c: Ctx) {
  const email = c.get("email");
  const body = await c.req
    .json<{ manifest?: ManifestInput; blob?: string; kind?: string; preview?: unknown }>()
    .catch(() => null);
  if (!body || !body.manifest || typeof body.blob !== "string") {
    return c.json({ error: "invalid_body" }, 400);
  }

  // Category + look-and-feel preview are client-computed (the app already parsed
  // the manifest + theme.json). The server treats both as opaque metadata.
  const kind = body.kind === "theme" ? "theme" : "extension";
  const preview = body.preview != null ? JSON.stringify(body.preview) : null;
  // Preview is shown to every browser pre-install — cap it so a publish can't
  // bloat the row / browse payload. 16 KB fits many themes' flat color maps.
  if (preview != null && preview.length > 16_384) {
    return c.json({ error: "preview_too_large", max: "16384" }, 413);
  }

  const m = body.manifest;
  const id = (m.id ?? "").trim();
  const version = (m.version ?? "").trim();
  if (!ID_RE.test(id)) return c.json({ error: "invalid_id" }, 400);
  if (!SEMVER_RE.test(version)) return c.json({ error: "invalid_version" }, 400);
  if (!m.title || !m.name || !m.author) return c.json({ error: "missing_fields" }, 400);
  // A published extension can never claim to be a bundled system one.
  if (m.system === true) return c.json({ error: "system_not_allowed" }, 400);

  const max = intEnv(c.env.MARKET_MAX_BYTES, 262_144); // 256 KB — extensions are tiny
  // Bound the encoded string before atob so an oversized blob can't force a large
  // allocation ahead of the byte-length check (base64 expands ~4/3 over raw).
  if (body.blob.length > Math.ceil(max * 4 / 3) + 16) {
    return c.json({ error: "too_large", max: String(max) }, 413);
  }
  const bytes = b64ToBytes(body.blob);
  if (bytes.length === 0) return c.json({ error: "empty_artifact" }, 400);
  // max as a string: the app decodes error bodies as [String: String] (MarketClient.errorText).
  if (bytes.length > max) return c.json({ error: "too_large", max: String(max) }, 413);
  // gzip magic — the app uploads a .tar.gz.
  if (bytes[0] !== 0x1f || bytes[1] !== 0x8b) {
    return c.json({ error: "not_gzip" }, 400);
  }
  // #1140: what a publish makes public. Older Prosper builds pack hidden members
  // (.DS_Store, AppleDouble "._x", tool state folders) and the account's user and
  // group name; refuse before any D1 or KV access. Bodies carry strings only: the
  // app decodes them as [String: String] and shows "error" as is.
  const tar = await gunzipCapped(bytes, max * UNPACK_FACTOR);
  if (tar === "too_large") {
    return c.json({ error: `The extension is too large to publish once unpacked (${Math.floor((max * UNPACK_FACTOR) / 1024)} KB max).` }, 413);
  }
  const members = tar === "bad" ? null : tarMembers(tar);
  if (!members) return c.json({ error: "not_gzip" }, 400); // the app shows "wasn't a valid .tar.gz"
  const hidden = members.names.filter(isHiddenPath);
  if (hidden.length > 0) {
    const shown = hidden.slice(0, 10).map(showName).join(", ");
    const more = hidden.length > 10 ? ` (+${hidden.length - 10} more)` : "";
    return c.json({ error: `Hidden files can't be published: ${shown}${more}. Update Prosper and publish again.` }, 400);
  }
  if (members.owner) {
    return c.json({ error: "The archive carries the account's user or group name. Update Prosper and publish again." }, 400);
  }

  // Ownership: first publisher owns the id; only they may push more versions.
  const existing = await c.env.DB.prepare(
    `SELECT owner_email FROM packages WHERE id = ?1`,
  )
    .bind(id)
    .first<{ owner_email: string }>();
  if (existing && existing.owner_email !== email) {
    return c.json({ error: "not_owner" }, 403);
  }

  // Versions are immutable once published.
  const dupe = await c.env.DB.prepare(
    `SELECT 1 FROM package_versions WHERE package_id = ?1 AND version = ?2`,
  )
    .bind(id, version)
    .first();
  if (dupe) return c.json({ error: "version_exists" }, 409);

  // Light publish rate limit: 20 publishes / hour per email.
  const rlKey = `rl:publish:${email}`;
  const count = parseInt((await c.env.KV.get(rlKey)) ?? "0", 10);
  if (count >= 20) return c.json({ error: "rate_limited" }, 429);
  await c.env.KV.put(rlKey, String(count + 1), { expirationTtl: 3600 });

  const now = nowSec();
  const sha = await sha256HexBytes(bytes);
  const publisher = await publisherValue(c.env.SUPPORTER_SIGNING_JWK, email);
  const signature = await signDetached(
    c.env.SUPPORTER_SIGNING_JWK,
    claimMessage({ id, version, sha256: sha, publisher_email: publisher, published_at: now }),
  );
  const artifactKey = `pkg:${id}:${version}`;

  await c.env.KV.put(artifactKey, bytes);
  // Both rows must land together: if the version insert committed but the
  // packages upsert didn't, the version row would block re-publish (version_exists)
  // while latest_version stayed stale — locking the owner out of that version.
  // DB.batch() runs them in one transaction (all-or-nothing). KV is put first and
  // is idempotent on retry, so an orphaned blob (no DB row) is invisible + harmless.
  await c.env.DB.batch([
    c.env.DB.prepare(
      `INSERT INTO package_versions
         (package_id, version, manifest, sha256, signature, size, artifact_key, published_at, publisher)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`,
    ).bind(id, version, JSON.stringify(m), sha, signature, bytes.length, artifactKey, now, publisher),
    c.env.DB.prepare(
      `INSERT INTO packages
         (id, owner_email, name, title, description, author, icon, license,
          latest_version, downloads, status, created_at, updated_at, kind, preview)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0, 'active', ?10, ?10, ?11, ?12)
       ON CONFLICT(id) DO UPDATE SET
         name = ?3, title = ?4, description = ?5, author = ?6, icon = ?7,
         license = ?8, latest_version = ?9, status = 'active', updated_at = ?10,
         kind = ?11, preview = ?12`,
    ).bind(
      id, email, m.name, m.title, m.description ?? "", m.author,
      m.icon ?? null, m.license ?? null, version, now, kind, preview,
    ),
  ]);

  return c.json({ ok: true, id, version, sha256: sha, kind });
}

// GET /market/index — one call the app makes to learn every package's latest
// version (drives auto-update for prosper://market/<id> extensions).
async function index(c: Ctx) {
  const rows = await c.env.DB.prepare(
    `SELECT id, latest_version FROM packages WHERE status = 'active'`,
  ).all<{ id: string; latest_version: string }>();
  return c.json({ packages: rows.results });
}

// GET /market/packages?q=&sort=&cursor=&kind= — browse/search. `kind` filters to
// 'theme' or 'extension' (omit for all).
async function listPackages(c: Ctx) {
  const q = (c.req.query("q") ?? "").trim();
  const sort = c.req.query("sort") === "downloads" ? "downloads" : "updated_at";
  const kind = c.req.query("kind");
  const limit = Math.min(intEnv(c.req.query("limit"), 50), 100);
  const offset = Math.max(intEnv(c.req.query("cursor"), 0), 0);

  const cols = `id, title, description, author, icon, license, latest_version, downloads, updated_at, kind, preview`;
  const where: string[] = ["status = 'active'"];
  const binds: unknown[] = [];
  if (q) {
    binds.push(`%${q}%`);
    where.push(`(title LIKE ?${binds.length} OR description LIKE ?${binds.length} OR author LIKE ?${binds.length} OR id LIKE ?${binds.length})`);
  }
  if (kind === "theme" || kind === "extension") {
    binds.push(kind);
    where.push(`kind = ?${binds.length}`);
  }
  binds.push(limit, offset);
  const stmt = c.env.DB.prepare(
    `SELECT ${cols} FROM packages WHERE ${where.join(" AND ")}
     ORDER BY ${sort} DESC LIMIT ?${binds.length - 1} OFFSET ?${binds.length}`,
  ).bind(...binds);

  const rows = await stmt.all();
  const results = (rows.results ?? []).map(decodePreview);
  const nextCursor = results.length === limit ? offset + limit : null;
  return c.json({ packages: results, cursor: nextCursor });
}

/** Parse the stored preview JSON string back into an object for the client. */
function decodePreview<T extends { preview?: unknown }>(row: T): T {
  if (typeof row.preview === "string") {
    try { row.preview = JSON.parse(row.preview); } catch { row.preview = null; }
  }
  return row;
}

// GET /market/packages/:id — detail + version history.
async function packageDetail(c: Ctx) {
  const id = c.req.param("id");
  // NB: owner_email is intentionally NOT selected — it's the publisher's supporter
  // email (PII). No public route returns it (#1138): download answers the masked
  // publisherValue the claim is signed over.
  const pkg = await c.env.DB.prepare(
    `SELECT id, name, title, description, author, icon, license,
            latest_version, downloads, status, created_at, updated_at, kind, preview
     FROM packages WHERE id = ?1`,
  )
    .bind(id)
    .first();
  if (!pkg) return c.json({ error: "not_found" }, 404);
  decodePreview(pkg);
  const versions = await c.env.DB.prepare(
    `SELECT version, sha256, size, published_at FROM package_versions
     WHERE package_id = ?1 ORDER BY published_at DESC`,
  )
    .bind(id)
    .all();
  return c.json({ package: pkg, versions: versions.results });
}

// GET /market/download/:id/:version — artifact bytes (base64) + signed claim.
async function download(c: Ctx) {
  const id = c.req.param("id");
  const version = c.req.param("version");

  const row = await c.env.DB.prepare(
    `SELECT v.sha256, v.signature, v.size, v.artifact_key, v.published_at, v.publisher, p.owner_email, p.status
     FROM package_versions v JOIN packages p ON p.id = v.package_id
     WHERE v.package_id = ?1 AND v.version = ?2`,
  )
    .bind(id, version)
    .first<{
      sha256: string;
      signature: string;
      size: number;
      artifact_key: string;
      published_at: number;
      publisher: string | null;
      owner_email: string;
      status: string;
    }>();
  if (!row) return c.json({ error: "not_found" }, 404);
  if (row.status !== "active") return c.json({ error: "yanked" }, 410);

  const bytes = await c.env.KV.get(row.artifact_key, "arrayBuffer");
  if (!bytes) return c.json({ error: "artifact_missing" }, 404);

  // A row from before #1138 (publisher NULL) was signed over the e-mail. Re-sign it
  // over the masked value, but only when its stored signature still verifies over
  // the e-mail claim, so a D1 edit cannot get a fresh signature. Not written back:
  // no extra query on the download path.
  let publisher = row.publisher;
  let signature = row.signature;
  if (publisher === null) {
    const jwk = c.env.SUPPORTER_SIGNING_JWK;
    // The route always binds both params; ! only narrows Hono's string | undefined.
    const claim = { id: id!, version: version!, sha256: row.sha256, published_at: row.published_at };
    if (!(await verifyClaim(jwk, claimMessage({ ...claim, publisher_email: row.owner_email }), signature))) {
      return c.json({ error: "republish_required" }, 410);
    }
    publisher = await publisherValue(jwk, row.owner_email);
    signature = await signDetached(jwk, claimMessage({ ...claim, publisher_email: publisher }));
  }

  // Best-effort download counter (don't block the response on it).
  c.executionCtx.waitUntil(
    c.env.DB.prepare(`UPDATE packages SET downloads = downloads + 1 WHERE id = ?1`)
      .bind(id)
      .run(),
  );

  return c.json({
    id,
    version,
    sha256: row.sha256,
    signature,
    publisher_email: publisher, // field name kept: every installed app reads it
    published_at: row.published_at,
    blob: bytesToB64(new Uint8Array(bytes)),
  });
}

// DELETE /market/packages/:id — owner-only yank. Keeps rows; flips status so the
// app stops offering/updating it. The signature lets a malicious artifact be
// centrally stopped from spreading.
async function yank(c: Ctx) {
  const email = c.get("email");
  const id = c.req.param("id");
  const pkg = await c.env.DB.prepare(`SELECT owner_email FROM packages WHERE id = ?1`)
    .bind(id)
    .first<{ owner_email: string }>();
  if (!pkg) return c.json({ error: "not_found" }, 404);
  if (pkg.owner_email !== email) return c.json({ error: "not_owner" }, 403);
  await c.env.DB.prepare(`UPDATE packages SET status = 'yanked', updated_at = ?2 WHERE id = ?1`)
    .bind(id, nowSec())
    .run();
  return c.json({ ok: true });
}

// --- helpers ---

/** #1140: publish inflates at most MARKET_MAX_BYTES * 8 (2 MiB at the default 256 KB);
 *  the largest bundled extension unpacks to ~115 KB. */
const UNPACK_FACTOR = 8;

/** The app's isHiddenMember rule (RemoteInstaller.swift, #1131): a path component that
 *  starts with "." other than the root "." itself (so "..", "._x" and ".a/b" count). */
const isHiddenPath = (p: string) => p.split("/").some((part) => part !== "." && part.startsWith("."));

/** A member name as the publisher may see it: no control characters, at most 100 code points
 *  (a longer one keeps its head and its tail, where the file name is; cut by code point so no
 *  surrogate pair is split and the JSON stays well formed for the app's decoder). */
function showName(n: string): string {
  const cp = [...n];
  return (cp.length > 100 ? `${cp.slice(0, 40).join("")}…${cp.slice(-59).join("")}` : n).replace(/[\u0000-\u001f\u007f]/g, "?");
}

/** Inflate a gzip body. Stops reading and refuses once the output would pass `cap`,
 *  so at most `cap` bytes are ever kept; a corrupt or truncated stream is "bad". */
async function gunzipCapped(bytes: Uint8Array, cap: number): Promise<Uint8Array | "too_large" | "bad"> {
  const reader = new Response(bytes).body!.pipeThrough(new DecompressionStream("gzip")).getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (let r = await reader.read(); !r.done; r = await reader.read()) {
      if (r.value.length > cap - total) {
        reader.cancel().catch(() => {});
        return "too_large";
      }
      chunks.push(r.value);
      total += r.value.length;
    }
  } catch {
    return "bad";
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const ch of chunks) {
    out.set(ch, at);
    at += ch.length;
  }
  return out;
}

const utf8 = new TextDecoder();
/** A NUL-terminated header field (or the whole field when it has no NUL). */
function field(b: Uint8Array, at: number, len: number): string {
  const f = b.subarray(at, at + len);
  const z = f.indexOf(0);
  return utf8.decode(z < 0 ? f : f.subarray(0, z));
}

/** An octal header number, or null when the field holds anything but spaces, octal
 *  digits and a NUL/space end (a GNU base-256 number included). At most 12 digits:
 *  below 8^12, exact in a double. */
function octal(h: Uint8Array, at: number, len: number): number | null {
  let i = at;
  while (i < at + len && h[i] === 0x20) i++;
  let n = 0;
  for (; i < at + len && h[i] !== 0 && h[i] !== 0x20; i++) {
    if (h[i] < 0x30 || h[i] > 0x37) return null;
    n = n * 8 + (h[i] - 0x30);
  }
  return n;
}

/** The records of a pax extended header ("<len> <key>=<value>\n"); null when malformed. */
function paxRecords(b: Uint8Array): Map<string, string> | null {
  const out = new Map<string, string>();
  for (let i = 0; i < b.length; ) {
    let j = i;
    let len = 0;
    while (j < b.length && j - i < 10 && b[j] >= 0x30 && b[j] <= 0x39) len = len * 10 + (b[j++] - 0x30);
    // len is checked against the bytes left before it is used as an offset.
    if (j === i || b[j] !== 0x20 || len > b.length - i || len < j - i + 3 || b[i + len - 1] !== 0x0a) return null;
    const rec = b.subarray(j + 1, i + len - 1);
    const eq = rec.indexOf(0x3d);
    if (eq < 0) return null;
    out.set(utf8.decode(rec.subarray(0, eq)), utf8.decode(rec.subarray(eq + 1)));
    i += len;
  }
  return out;
}

/** Walks the tar headers of an inflated archive: every member's name (a pax "path=" from
 *  an 'x' record or a GNU 'L' long name replaces the next header's own; a ustar prefix is
 *  joined; a global 'g' path counts as a name) and whether any header or pax record holds
 *  a user or group name. A type it does not know is a member: its name is read, its data
 *  skipped by its size. null when the bytes are not a whole tar (bad checksum, a size past
 *  the bytes, no end-of-archive block). Stops at the first zero block, as bsdtar does. */
function tarMembers(data: Uint8Array): { names: string[]; owner: boolean } | null {
  const names: string[] = [];
  let owner = false;
  let next: string | null = null;
  for (let off = 0; ; ) {
    if (data.length - off < 512) return null;
    const h = data.subarray(off, off + 512);
    if (h.every((b) => b === 0)) return { names, owner };
    let sum = 0;
    for (let i = 0; i < 512; i++) sum += i >= 148 && i < 156 ? 0x20 : h[i];
    const size = octal(h, 124, 12);
    if (size === null || octal(h, 148, 8) !== sum) return null;
    off += 512;
    const room = data.length - off;
    if (size > room) return null;
    const padded = Math.ceil(size / 512) * 512;
    if (padded > room) return null;
    const body = data.subarray(off, off + size);
    off += padded;
    if (field(h, 265, 32) || field(h, 297, 32)) owner = true;
    const type = h[156];
    if (type === 0x78 || type === 0x67) { // 'x' per-file, 'g' global pax
      const rec = paxRecords(body);
      if (!rec) return null;
      if (rec.get("uname") || rec.get("gname")) owner = true;
      const path = rec.get("path");
      if (path !== undefined && type === 0x78) next = path;
      else if (path !== undefined) names.push(path);
    } else if (type === 0x4c) { // 'L' GNU long name
      next = field(body, 0, body.length);
    } else if (type !== 0x4b) { // 'K' is a GNU long link target, not a name
      const name = field(h, 0, 100);
      const prefix = field(h, 257, 6) === "ustar" ? field(h, 345, 155) : ""; // POSIX "ustar\0" only
      names.push(next ?? (prefix ? `${prefix}/${name}` : name));
      next = null;
    }
  }
}

async function sha256HexBytes(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function bytesToB64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

// Public: browse + download. Authenticated: publish + yank.
market.get("/index", index);
market.get("/packages", listPackages);
market.get("/packages/:id", packageDetail);
market.get("/download/:id/:version", download);
market.post("/publish", requireSession, publish);
market.delete("/packages/:id", requireSession, yank);

export { market, claimMessage, publisherValue };
