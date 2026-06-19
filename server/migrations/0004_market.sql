-- Extension marketplace: a registry of user-published extensions.
-- Artifact bytes (gzipped tarballs) live in KV under "pkg:<id>:<version>";
-- these tables hold only the searchable index, ownership, and signed metadata.

-- One published package. The reverse-DNS id is the primary key and the
-- ownership anchor: the first publisher of an id owns it, and only they may
-- push new versions.
CREATE TABLE IF NOT EXISTS packages (
  id             TEXT PRIMARY KEY,        -- "com.author.thing"
  owner_email    TEXT NOT NULL,
  name           TEXT NOT NULL,
  title          TEXT NOT NULL,
  description    TEXT NOT NULL,
  author         TEXT NOT NULL,
  icon           TEXT,
  license        TEXT,
  latest_version TEXT NOT NULL,
  downloads      INTEGER NOT NULL DEFAULT 0,
  status         TEXT NOT NULL DEFAULT 'active',  -- active | yanked
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_packages_owner ON packages(owner_email);
CREATE INDEX IF NOT EXISTS idx_packages_updated ON packages(updated_at);

-- One immutable row per published version. `signature` is an Ed25519 detached
-- signature (base64url) over the canonical claim string (see market.ts
-- `claimMessage`), signed with SUPPORTER_SIGNING_JWK and verified offline by the
-- app's embedded public key.
CREATE TABLE IF NOT EXISTS package_versions (
  package_id   TEXT NOT NULL,
  version      TEXT NOT NULL,           -- semver, immutable once published
  manifest     TEXT NOT NULL,           -- full manifest JSON (for the detail view)
  sha256       TEXT NOT NULL,           -- hex sha256 of the gzipped tarball
  signature    TEXT NOT NULL,           -- Ed25519(claimMessage) base64url
  size         INTEGER NOT NULL,
  artifact_key TEXT NOT NULL,           -- KV key: "pkg:<id>:<version>"
  published_at INTEGER NOT NULL,
  PRIMARY KEY (package_id, version)
);
CREATE INDEX IF NOT EXISTS idx_versions_pkg ON package_versions(package_id);
