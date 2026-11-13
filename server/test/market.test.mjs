// #1138: no public Marketplace route returns the publisher e-mail; the signed claim carries
// the masked publisher value. Drives the real market.ts (node 24 strips its types) over
// node:sqlite with every migration applied, an in-memory KV, and an Ed25519 key pair made
// here. Nothing leaves the process.
import { registerHooks } from "node:module";
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";

// The Worker's sources import siblings without an extension (the bundler resolves them).
registerHooks({
  resolve(spec, ctx, next) {
    if (spec.startsWith("./") && !/\.\w+$/.test(spec)) return next(`${spec}.ts`, ctx);
    return next(spec, ctx);
  },
});
const { market, claimMessage, publisherValue } = await import("../src/market.ts");

const PUB = "publisher@example.com";
const OTHER = PUB.replace("publisher@", "publisher2@"); // a second account, same reserved domain
const TOKEN = { [PUB]: "t-pub", [OTHER]: "t-other" };
const MIGRATIONS = new URL("../migrations/", import.meta.url);

const genJwk = async () => {
  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  return { priv: JSON.stringify(await crypto.subtle.exportKey("jwk", kp.privateKey)), pub: kp.publicKey };
};
// One key per process: jwt.ts caches the imported signing key.
const KEY = await genJwk();

// The app's check (RemoteInstaller.fetchFromMarket): rebuild the claim from the answer, verify.
const verifies = (dl, publisher = dl.publisher_email) =>
  crypto.subtle.verify(
    "Ed25519",
    KEY.pub,
    Buffer.from(dl.signature, "base64url"),
    new TextEncoder().encode(
      claimMessage({ id: dl.id, version: dl.version, sha256: dl.sha256, publisher_email: publisher, published_at: dl.published_at }),
    ),
  );

// A D1 stand-in over node:sqlite (as pushStore.test.mjs), counting the statements it ran.
function d1(db, log) {
  const make = (sql, args = []) => ({
    sql,
    bind: (...a) => make(sql, a),
    first: async () => (log.push(sql), db.prepare(sql).get(...args) ?? null),
    all: async () => (log.push(sql), { results: db.prepare(sql).all(...args).map((r) => ({ ...r })) }),
    run: async () => (log.push(sql), { meta: { changes: Number(db.prepare(sql).run(...args).changes) } }),
    runSync: () => db.prepare(sql).run(...args),
  });
  return {
    prepare: (sql) => make(sql),
    batch: async (stmts) => {
      log.push("BATCH");
      db.exec("BEGIN");
      try {
        const out = stmts.map((s) => s.runSync());
        db.exec("COMMIT");
        return out;
      } catch (e) {
        db.exec("ROLLBACK");
        throw e;
      }
    },
  };
}

function setup() {
  const raw = new DatabaseSync(":memory:");
  for (const f of readdirSync(MIGRATIONS).filter((n) => n.endsWith(".sql")).sort()) {
    raw.exec(readFileSync(new URL(f, MIGRATIONS), "utf8"));
  }
  for (const [email, token] of Object.entries(TOKEN)) {
    raw.prepare(`INSERT INTO sessions VALUES (?, ?, 0, 0, NULL)`).run(createHash("sha256").update(token).digest("hex"), email);
  }
  const kv = new Map();
  const log = [];
  const env = {
    DB: d1(raw, log),
    KV: {
      get: async (k, type) => {
        const v = kv.get(k);
        if (v === undefined) return null;
        return type === "arrayBuffer" ? new Uint8Array(v).buffer : String(v);
      },
      put: async (k, v) => void kv.set(k, v),
    },
    SUPPORTER_SIGNING_JWK: KEY.priv,
  };
  const pending = [];
  const ctx = { waitUntil: (p) => pending.push(p), passThroughOnException() {}, props: {} };
  const req = async (path, init = {}) => {
    const r = await market.request(path, init, env, ctx);
    await Promise.all(pending.splice(0));
    const text = await r.text();
    return { status: r.status, text, json: JSON.parse(text) };
  };
  const publish = (email, id, version = "1.0.0") =>
    req("/publish", {
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN[email]}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        manifest: { id, version, name: id, title: `T ${id}`, author: "Example Author", description: "d" },
        blob: gzipSync(Buffer.from(`${id}@${version}`)).toString("base64"),
      }),
    });
  return { raw, env, log, req, publish };
}

test("publish then download: the masked value, a signature that verifies over the claim with it", async () => {
  const t = setup();
  assert.equal((await t.publish(PUB, "com.example.one")).status, 200);
  const dl = await t.req("/download/com.example.one/1.0.0");
  assert.equal(dl.status, 200);
  const v = await publisherValue(KEY.priv, PUB);
  assert.match(v, /^pub_[0-9a-f]{16}$/);
  assert.equal(dl.json.publisher_email, v);
  assert.equal(await verifies(dl.json), true, "the app's check passes");
  assert.equal(await verifies(dl.json, PUB), false, "the claim is not signed over the e-mail");
  const row = t.raw.prepare(`SELECT publisher FROM package_versions WHERE package_id = ?`).get("com.example.one");
  assert.equal(row.publisher, v, "the signed value is stored");
  const owner = t.raw.prepare(`SELECT owner_email FROM packages WHERE id = ?`).get("com.example.one");
  assert.equal(owner.owner_email, PUB, "the real e-mail stays stored for ownership");
});

test("no public route body contains the publisher e-mail", async () => {
  const t = setup();
  await t.publish(PUB, "com.example.one");
  await t.publish(PUB, "com.example.one", "1.1.0");
  await t.publish(PUB, "com.example.two");
  const paths = [
    "/index",
    "/packages",
    "/packages?sort=downloads",
    "/packages?q=example",
    "/packages?q=publisher",
    "/packages?kind=extension",
    "/packages/com.example.one",
    "/packages/com.example.two",
    "/download/com.example.one/1.0.0",
    "/download/com.example.one/1.1.0",
    "/download/com.example.two/1.0.0",
    "/download/com.example.one/9.9.9",
    "/packages/com.example.none",
  ];
  for (const p of paths) {
    const r = await t.req(p);
    assert.ok(r.status === 200 || r.status === 404, `${p}: ${r.status}`);
    assert.ok(!r.text.toLowerCase().includes(PUB), `${p} returned the e-mail`);
  }
  // A yanked package's download answers 410 without it too.
  await t.req("/packages/com.example.two", { method: "DELETE", headers: { Authorization: `Bearer ${TOKEN[PUB]}` } });
  const y = await t.req("/download/com.example.two/1.0.0");
  assert.equal(y.status, 410);
  assert.ok(!y.text.includes(PUB));
});

test("two packages of one publisher carry the same value, two publishers different ones", async () => {
  const t = setup();
  await t.publish(PUB, "com.example.one");
  await t.publish(PUB, "com.example.two");
  await t.publish(OTHER, "com.example.three");
  const a = (await t.req("/download/com.example.one/1.0.0")).json.publisher_email;
  const b = (await t.req("/download/com.example.two/1.0.0")).json.publisher_email;
  const c = (await t.req("/download/com.example.three/1.0.0")).json.publisher_email;
  assert.equal(a, b);
  assert.notEqual(a, c);
  assert.equal(await publisherValue(KEY.priv, PUB.toUpperCase()), a, "the address's case does not matter");
});

test("the value is keyed: not a plain hash of the address, and another server key gives another", async () => {
  const v = await publisherValue(KEY.priv, PUB);
  for (const plain of [createHash("sha256").update(PUB).digest("hex"), createHash("sha1").update(PUB).digest("hex")]) {
    assert.ok(!v.includes(plain.slice(0, 16)), "a guessed address hashed without the key reproduces it");
  }
  const other = await genJwk();
  assert.notEqual(await publisherValue(other.priv, PUB), v);
  await assert.rejects(publisherValue(JSON.stringify({ kty: "OKP", crv: "Ed25519", x: "AA" }), PUB));
});

test("ownership still refuses another account (publish and yank)", async () => {
  const t = setup();
  await t.publish(PUB, "com.example.one");
  const p = await t.publish(OTHER, "com.example.one", "2.0.0");
  assert.equal(p.status, 403);
  assert.equal(p.json.error, "not_owner");
  const y = await t.req("/packages/com.example.one", { method: "DELETE", headers: { Authorization: `Bearer ${TOKEN[OTHER]}` } });
  assert.equal(y.status, 403);
  assert.ok(!p.text.includes(PUB) && !y.text.includes(PUB));
  assert.equal((await t.publish(PUB, "com.example.one", "2.0.0")).status, 200, "the owner still publishes");
});

// A row the Worker before #1138 wrote: its INSERT (base market.ts) has no publisher column, so on
// the new schema the column is NULL and the signature covers the e-mail.
async function legacyRow(t, id, sha = createHash("sha256").update("legacy").digest("hex")) {
  const now = 1_800_000_000;
  const sig = Buffer.from(
    await crypto.subtle.sign(
      { name: "Ed25519" },
      await crypto.subtle.importKey("jwk", JSON.parse(KEY.priv), { name: "Ed25519" }, false, ["sign"]),
      new TextEncoder().encode(claimMessage({ id, version: "1.0.0", sha256: sha, publisher_email: PUB, published_at: now })),
    ),
  ).toString("base64url");
  t.raw
    .prepare(`INSERT INTO package_versions
         (package_id, version, manifest, sha256, signature, size, artifact_key, published_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`)
    .run(id, "1.0.0", "{}", sha, sig, 6, `pkg:${id}:1.0.0`, now);
  t.raw
    .prepare(`INSERT INTO packages (id, owner_email, name, title, description, author, latest_version, created_at, updated_at, kind)
       VALUES (?, ?, ?, ?, '', 'a', '1.0.0', ?, ?, 'theme')`)
    .run(id, PUB, id, id, now, now);
  await t.env.KV.put(`pkg:${id}:1.0.0`, new TextEncoder().encode("legacy"));
}

test("a legacy row (signed over the e-mail) is re-signed over the masked value on download", async () => {
  const t = setup();
  await legacyRow(t, "com.example.legacy");
  const dl = await t.req("/download/com.example.legacy/1.0.0");
  assert.equal(dl.status, 200);
  assert.equal(dl.json.publisher_email, await publisherValue(KEY.priv, PUB));
  assert.ok(!dl.text.includes(PUB));
  assert.equal(await verifies(dl.json), true);
  const row = t.raw.prepare(`SELECT publisher FROM package_versions WHERE package_id = ?`).get("com.example.legacy");
  assert.equal(row.publisher, null, "not written back");
});

test("a legacy row whose stored signature does not verify is refused, not re-signed", async () => {
  const t = setup();
  await legacyRow(t, "com.example.legacy");
  t.raw.prepare(`UPDATE package_versions SET sha256 = ? WHERE package_id = ?`).run("ab".repeat(32), "com.example.legacy");
  const dl = await t.req("/download/com.example.legacy/1.0.0");
  assert.equal(dl.status, 410);
  assert.equal(dl.json.error, "republish_required");
  assert.ok(!dl.text.includes(PUB));
});

test("download spends the D1 queries it did before: the row SELECT and the counter UPDATE", async () => {
  const t = setup();
  await t.publish(PUB, "com.example.one");
  await legacyRow(t, "com.example.legacy");
  for (const p of ["/download/com.example.one/1.0.0", "/download/com.example.legacy/1.0.0"]) {
    t.log.length = 0;
    assert.equal((await t.req(p)).status, 200);
    assert.equal(t.log.length, 2, `${p}: ${t.log.join(" | ")}`);
  }
});
