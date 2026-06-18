-- Prosper backend schema (Cloudflare D1 / SQLite)

-- Verified user identities (email is the primary key).
CREATE TABLE IF NOT EXISTS users (
  email      TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL,
  deleted_at INTEGER
);

-- Supporter records. type: supporter. status: active | refunded | revoked.
-- expires_at NULL = perpetual (supporter status does not expire).
CREATE TABLE IF NOT EXISTS licenses (
  id         TEXT PRIMARY KEY,           -- e.g. "ls_<order_id>" for idempotency
  email      TEXT NOT NULL,
  type       TEXT NOT NULL,
  status     TEXT NOT NULL DEFAULT 'active',
  source     TEXT,                        -- lemonsqueezy | manual | ...
  order_id   TEXT,
  issued_at  INTEGER NOT NULL,
  expires_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_licenses_email ON licenses(email);
CREATE INDEX IF NOT EXISTS idx_licenses_order ON licenses(order_id);

-- Activated devices per user (soft cap enforced in the app layer).
CREATE TABLE IF NOT EXISTS devices (
  email        TEXT NOT NULL,
  device_id    TEXT NOT NULL,
  name         TEXT,
  activated_at INTEGER NOT NULL,
  last_seen    INTEGER NOT NULL,
  PRIMARY KEY (email, device_id)
);

-- Manual supporter grants — emails here get supporter status without paying.
CREATE TABLE IF NOT EXISTS whitelist (
  email      TEXT PRIMARY KEY,
  status     TEXT NOT NULL,               -- supporter | ...
  note       TEXT,
  created_at INTEGER NOT NULL
);

-- Long-lived opaque session credentials (stored hashed). Bearer for the API.
CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  email      TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  last_seen  INTEGER NOT NULL,
  expires_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_sessions_email ON sessions(email);

-- Settings sync: one opaque blob per user with an optimistic-concurrency version.
-- The app is expected to encrypt sensitive fields client-side; the server treats
-- the blob as opaque text.
CREATE TABLE IF NOT EXISTS settings (
  email      TEXT PRIMARY KEY,
  version    INTEGER NOT NULL DEFAULT 0,
  blob       TEXT,
  updated_at INTEGER NOT NULL
);
