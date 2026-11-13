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

// #1140: a small tar writer (ustar headers with the checksum filled in), so publish gets a real
// archive. Entry: { name, data?, type? ("0" file, "5" dir, "x"/"g" pax, "L" GNU long name), prefix? (raw bytes
// at offset 345), uname?, gname?, magic? ("gnu": "ustar  \0", whose offset 345 is not a prefix) }.
function tar(entries) {
  const out = [];
  for (const e of entries) {
    const data = Buffer.from(e.data ?? "");
    const h = Buffer.alloc(512);
    h.write(e.name, 0, 100, "latin1");
    h.write("0000644\0", 100);
    h.write("0000000\0", 108);
    h.write("0000000\0", 116);
    h.write(`${data.length.toString(8).padStart(11, "0")}\0`, 124);
    h.write("00000000000\0", 136);
    h.write(e.type ?? "0", 156);
    h.write(e.magic === "gnu" ? "ustar  \0" : "ustar\u000000", 257);
    if (e.uname) h.write(e.uname, 265);
    if (e.gname) h.write(e.gname, 297);
    if (e.prefix) h.write(e.prefix, 345);
    h.write("        ", 148);
    let sum = 0;
    for (const b of h) sum += b;
    h.write(`${sum.toString(8).padStart(6, "0")}\0 `, 148);
    out.push(h, data, Buffer.alloc((512 - (data.length % 512)) % 512));
  }
  out.push(Buffer.alloc(1024));
  return Buffer.concat(out);
}
// pax records "<len> <key>=<value>\n", the length counting its own digits.
const pax = (records) =>
  Object.entries(records)
    .map(([k, v]) => {
      const rest = ` ${k}=${v}\n`;
      let n = Buffer.byteLength(rest) + 1;
      while (String(n).length + Buffer.byteLength(rest) !== n) n++;
      return `${n}${rest}`;
    })
    .join("");
// What the app packs from an extension folder (root "./", members under it).
const cleanTar = (id, version) =>
  tar([
    { name: "./", type: "5" },
    { name: "./extension.toml", data: `id = "${id}"\nversion = "${version}"\n` },
    { name: "./init.lua", data: "return {}\n" },
  ]);

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
  const publish = (email, id, version = "1.0.0", blob = gzipSync(cleanTar(id, version))) =>
    req("/publish", {
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN[email]}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        manifest: { id, version, name: id, title: `T ${id}`, author: "Example Author", description: "d" },
        blob: Buffer.from(blob).toString("base64"),
      }),
    });
  return { raw, env, kv, log, req, publish };
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

// #1140: publish refuses an archive whose members are hidden, before any D1 or KV access.
const LONG = `./lib/${"a".repeat(120)}`;
// requireSession's two statements (SELECT, UPDATE sessions) run before publish; nothing after them.
const marketSql = (t) => t.log.filter((s) => !/\bsessions\b/.test(s));
const refused = async (t, blob) => {
  const r = await t.publish(PUB, "com.example.one", "1.0.0", gzipSync(blob));
  assert.deepEqual(marketSql(t), [], "no D1 statement");
  assert.equal(t.kv.size, 0, "no KV write (rate limit or artifact)");
  assert.ok(Object.values(r.json).every((v) => typeof v === "string"), "the app decodes the body as [String: String]");
  return r;
};

test("a clean archive publishes: root ./, a pax record without a path, a GNU long name, a prefix, a dotted file name", async () => {
  const t = setup();
  const blob = tar([
    { name: "./", type: "5" },
    { name: "./extension.toml", data: "id = 1\n" },
    { name: "./PaxHeader/init.lua", type: "x", data: pax({ mtime: "1.5" }) },
    { name: "./init.lua", data: "return {}\n" },
    { name: "././@LongLink", type: "L", data: `${LONG}/util.lua\0` },
    { name: LONG.slice(0, 100), data: "x" },
    { name: "util.v2.lua", prefix: "lib/sub", data: "x" },
  ]);
  const r = await t.publish(PUB, "com.example.one", "1.0.0", gzipSync(blob));
  assert.equal(r.status, 200, r.text);
  assert.ok(t.kv.has("pkg:com.example.one:1.0.0"));
});

test("hidden members are refused with the name in the error, and nothing is written", async () => {
  const rows = [
    ["top level", [{ name: "./.DS_Store", data: "x" }], "./.DS_Store"],
    ["at depth", [{ name: "./lib/" }, { name: "./lib/.state/notes.txt", data: "x" }], "./lib/.state/notes.txt"],
    ["AppleDouble", [{ name: "./._init.lua", data: "x" }], "./._init.lua"],
    ["hidden folder entry", [{ name: "./.state/", type: "5" }], "./.state/"],
    ["dot-dot", [{ name: "./lib/../x.lua", data: "x" }], "./lib/../x.lua"],
    [
      "pax long name",
      [{ name: "./PaxHeader/n", type: "x", data: pax({ path: `${LONG}/.state/notes.txt` }) }, { name: LONG.slice(0, 100), data: "x" }],
      "aaaa/.state/notes.txt", // a name past 100 chars is shown by its head and tail
    ],
    ["pax global path", [{ name: "GlobalHead", type: "g", data: pax({ path: "./.state" }) }], "./.state"],
    ["GNU long name", [{ name: "././@LongLink", type: "L", data: `${LONG}/._util.lua\0` }, { name: LONG.slice(0, 100), data: "x" }], "aaaa/._util.lua"],
    ["ustar prefix", [{ name: "notes.txt", prefix: "lib/.state", data: "x" }], "lib/.state/notes.txt"],
    ["bare name, no slash", [{ name: ".DS_Store", data: "x" }], ".DS_Store"],
    ["bare AppleDouble, no slash", [{ name: "._init.lua", data: "x" }], "._init.lua"],
    ["at depth, no leading ./", [{ name: "lib/.state/notes.txt", data: "x" }], "lib/.state/notes.txt"],
  ];
  // The ustar name under a pax path or a GNU long name (LONG cut at 100) is not hidden itself.
  for (const [what, members, name] of rows) {
    const t = setup();
    const r = await refused(t, tar([{ name: "./", type: "5" }, { name: "./init.lua", data: "x" }, ...members]));
    assert.equal(r.status, 400, `${what}: ${r.text}`);
    assert.ok(r.json.error.includes(name), `${what}: ${r.json.error}`);
    assert.ok(!r.json.error.includes("./init.lua"), `${what}: a clean member was named`);
  }
});

test("more than ten hidden members: ten names, the rest counted; control characters are not echoed", async () => {
  const t = setup();
  const many = Array.from({ length: 12 }, (_, i) => ({ name: `./.h${String(i).padStart(2, "0")}\n`, data: "x" }));
  const r = await refused(t, tar(many));
  assert.equal(r.status, 400);
  assert.ok(r.json.error.includes("./.h09?") && !r.json.error.includes("./.h10"), r.json.error);
  assert.ok(r.json.error.includes("(+2 more)"), r.json.error);
  assert.ok(!/[\u0000-\u001f]/.test(r.json.error));
});

test("a user or group name in a header or a pax record is refused (each of the four places alone)", async () => {
  for (const members of [
    [{ name: "./init.lua", uname: "example", data: "x" }],
    [{ name: "./init.lua", gname: "staff", data: "x" }],
    [{ name: "./PaxHeader/init.lua", type: "x", data: pax({ uname: "example" }) }, { name: "./init.lua", data: "x" }],
    [{ name: "./PaxHeader/init.lua", type: "x", data: pax({ gname: "staff" }) }, { name: "./init.lua", data: "x" }],
  ]) {
    const t = setup();
    const r = await refused(t, tar(members));
    assert.equal(r.status, 400, r.text);
    assert.match(r.json.error, /user or group name/);
    assert.ok(!r.json.error.includes("example") && !r.json.error.includes("staff"), "the name is not echoed");
  }
});

test("a gzip stream past the unpacked cap is refused without inflating it all", async () => {
  const t = setup();
  const BIG = 64 << 20; // 64 MiB of one member, ~64 KB gzipped: under the 256 KB packed limit
  const gz = gzipSync(tar([{ name: "./big.lua", data: Buffer.alloc(BIG) }]), { level: 9 });
  assert.ok(gz.length < 262_144);
  const Real = globalThis.DecompressionStream;
  let seen = 0;
  globalThis.DecompressionStream = class {
    constructor(format) {
      const ds = new Real(format);
      this.writable = ds.writable;
      this.readable = ds.readable.pipeThrough(new TransformStream({ transform: (ch, ctl) => (seen += ch.length, ctl.enqueue(ch)) }));
    }
  };
  try {
    const r = await t.publish(PUB, "com.example.one", "1.0.0", gz);
    assert.equal(r.status, 413, r.text);
    assert.match(r.json.error, /once unpacked \(2048 KB max\)/);
  } finally {
    globalThis.DecompressionStream = Real;
  }
  assert.ok(seen > 0 && seen < (2 << 20) + (1 << 20), `inflated ${seen} bytes`);
  assert.deepEqual(marketSql(t), []);
  assert.equal(t.kv.size, 0);
});

test("a truncated, corrupt or non-tar gzip body is refused as not_gzip, never a 500", async () => {
  const good = cleanTar("com.example.one", "1.0.0");
  const badSum = Buffer.from(good);
  badSum[0] ^= 1;
  const pastEnd = tar([{ name: "./init.lua", data: "x".repeat(600) }]).subarray(0, 512 + 600);
  // A member of 512 bytes whose size is written base-256 (GNU) and whose data is itself a header
  // block: a reader taking the field as 0 would walk that block as the next member.
  const base256 = tar([{ name: "./a.bin", data: tar([{ name: "./x.lua" }]).subarray(0, 512) }]);
  const h2 = base256.subarray(0, 512);
  h2.fill(0, 124, 136);
  h2[124] = 0x80;
  h2[134] = 0x02; // 0x0200 = 512
  h2.write("        ", 148);
  h2.write(`${h2.reduce((a, x) => a + x, 0).toString(8).padStart(6, "0")}\0 `, 148);
  const badPax = tar([{ name: "./PaxHeader/x", type: "x", data: "99 path=./x\n" }, { name: "./x", data: "x" }]);
  const gz = gzipSync(good);
  for (const [what, blob] of [
    ["non-tar text", gzipSync(Buffer.from("com.example.one@1.0.0"))],
    ["non-tar block", gzipSync(Buffer.alloc(2048, 0x41))],
    ["no end-of-archive block", gzipSync(good.subarray(0, good.length - 1024))],
    ["bad checksum", gzipSync(badSum)],
    ["size past the bytes", gzipSync(pastEnd)],
    ["base-256 size", gzipSync(base256)],
    ["pax record length past its data", gzipSync(badPax)],
    ["truncated gzip stream", gz.subarray(0, gz.length - 12)],
    ["corrupt deflate data", Buffer.concat([gz.subarray(0, 10), Buffer.alloc(40, 0xff)])],
  ]) {
    const t = setup();
    const r = await t.publish(PUB, "com.example.one", "1.0.0", blob);
    assert.equal(r.status, 400, `${what}: ${r.text}`);
    assert.equal(r.json.error, "not_gzip", what);
    assert.deepEqual(marketSql(t), [], what);
    assert.equal(t.kv.size, 0, what);
  }
});

test("publish spends the D1 statements it did before: the session pair, owner SELECT, dupe SELECT, one batch", async () => {
  const t = setup();
  assert.equal((await t.publish(PUB, "com.example.one")).status, 200);
  assert.deepEqual(t.log.map((s) => s.trim().split(/\s+/).slice(0, 2).join(" ")), [
    "SELECT email,",
    "UPDATE sessions",
    "SELECT owner_email",
    "SELECT 1",
    "BATCH",
  ]);
});

test("a long name names one member only: a hidden member after a long-named clean one is refused", async () => {
  const longPax = { name: "./PaxHeader/n", type: "x", data: pax({ path: `${LONG}/clean.lua` }) };
  const longGnu = { name: "././@LongLink", type: "L", data: `${LONG}/clean.lua\0` };
  for (const [lead, hidden] of [[longPax, "./.DS_Store"], [longGnu, "./._init.lua"]]) {
    const t = setup();
    const r = await refused(t, tar([lead, { name: LONG.slice(0, 100), data: "x" }, { name: hidden, data: "x" }]));
    assert.equal(r.status, 400, `${lead.type}: ${r.text}`);
    assert.equal(r.json.error, `Hidden files can't be published: ${hidden}. Update Prosper and publish again.`);
  }
  const t = setup();
  const ok = tar([longPax, { name: LONG.slice(0, 100), data: "x" }, { name: "./a.lua", data: "x" }, { name: "./b.lua", data: "x" }]);
  assert.equal((await t.publish(PUB, "com.example.one", "1.0.0", gzipSync(ok))).status, 200);
});

test("under the GNU magic the bytes at offset 345 are not a prefix", async () => {
  const t = setup();
  const clean = tar([{ name: "./init.lua", magic: "gnu", prefix: ".x", data: "x" }]);
  assert.equal((await t.publish(PUB, "com.example.one", "1.0.0", gzipSync(clean))).status, 200, "a dot at 345 under GNU magic");
  const t2 = setup();
  const r = await refused(t2, tar([{ name: "./.DS_Store", magic: "gnu", prefix: "lib", data: "x" }]));
  assert.equal(r.status, 400);
  assert.equal(r.json.error, "Hidden files can't be published: ./.DS_Store. Update Prosper and publish again.");
});

test("a long hidden name is cut by code point: the error is well formed and keeps the file name", async () => {
  // UTF-16 cuts at 40 and at -59 would both fall inside a surrogate pair here.
  const name = `./li/${"\u{1F600}".repeat(100)}/.state/note.txt`;
  assert.ok(!name.slice(0, 40).isWellFormed() && !name.slice(-59).isWellFormed(), "the fixture splits pairs at UTF-16 cuts");
  const t = setup();
  const r = await refused(t, tar([{ name: "./PaxHeader/n", type: "x", data: pax({ path: name }) }, { name: "./n", data: "x" }]));
  assert.equal(r.status, 400);
  assert.ok(r.json.error.isWellFormed(), "no lone surrogate");
  assert.ok(r.json.error.endsWith("\u{1F600}/.state/note.txt. Update Prosper and publish again."), r.json.error);
});

// The app (MarketClient.swift errorText + errorDescription): decode the body as [String: String]; a known
// "error" code maps to its friendly text, else "Marketplace error (<code>): <error>", and a failed decode
// leaves only "Marketplace error (<code>)."
const APP_FRIENDLY = {
  too_large: "The extension is too large to publish (256 KB max).",
  preview_too_large: "The theme preview is too large to publish.",
};
const appText = (code, body) => {
  const msg = Object.values(body).every((v) => typeof v === "string") ? body.error : undefined;
  return msg === undefined ? `Marketplace error (${code}).` : APP_FRIENDLY[msg] ?? `Marketplace error (${code}): ${msg}`;
};

test("the 413 bodies are string-only, so the app shows its friendly text", async () => {
  const send = (t, blob, preview) =>
    t.req("/publish", {
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN[PUB]}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        manifest: { id: "com.example.one", version: "1.0.0", name: "n", title: "T", author: "A" },
        blob: Buffer.from(blob).toString("base64"),
        preview,
      }),
    });
  const gzipish = (n) => Buffer.concat([Buffer.from([0x1f, 0x8b]), Buffer.alloc(n - 2)]);
  for (const [what, blob, preview, text] of [
    ["encoded length", gzipish(262_144 + 300), undefined, APP_FRIENDLY.too_large],
    ["decoded size", gzipish(262_145), undefined, APP_FRIENDLY.too_large],
    ["preview", gzipSync(cleanTar("com.example.one", "1.0.0")), { c: "x".repeat(16_400) }, APP_FRIENDLY.preview_too_large],
  ]) {
    const t = setup();
    const r = await send(t, blob, preview);
    assert.equal(r.status, 413, `${what}: ${r.text}`);
    assert.ok(Object.values(r.json).every((v) => typeof v === "string"), `${what}: ${r.text}`);
    assert.equal(appText(r.status, r.json), text, what);
    assert.equal(t.kv.size, 0, what);
  }
});
