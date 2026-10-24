-- Live session status on the phone (#521). Rows are always scoped by the
-- session email; see src/push.ts and src/pushStore.mjs.

-- Phone push tokens. device_id is the phone's install id (not a devices row).
-- kind: alert | la_start | la_update. activity_id is '' except for la_update,
-- which also carries the mac_id its Live Activity shows. env: production | sandbox.
-- created_at survives a token rotation (same key), so an activity older than
-- iOS's 8 h limit can be recognised as dead.
CREATE TABLE IF NOT EXISTS push_tokens (
  email       TEXT NOT NULL,
  device_id   TEXT NOT NULL,
  kind        TEXT NOT NULL,
  activity_id TEXT NOT NULL DEFAULT '',
  mac_id      TEXT,
  token       TEXT NOT NULL,
  env         TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (email, device_id, kind, activity_id)
);
CREATE INDEX IF NOT EXISTS idx_push_tokens_mac ON push_tokens(email, mac_id);

-- One row per publishing Mac. seq is the Mac's epoch ms (monotonic guard).
-- snapshot: JSON sessions array. last_alert: JSON {session name: unix sec}.
-- idle_since: when the Mac last had no working/blocked session (NULL while busy).
-- started_at: last push-to-start. rl_window/rl_count: per-minute POST counter.
CREATE TABLE IF NOT EXISTS push_macs (
  email        TEXT NOT NULL,
  mac_id       TEXT NOT NULL,
  seq          INTEGER NOT NULL,
  last_seen    INTEGER NOT NULL,
  online       INTEGER NOT NULL,
  snapshot     TEXT NOT NULL DEFAULT '[]',
  last_push_at INTEGER,
  last_alert   TEXT NOT NULL DEFAULT '{}',
  idle_since   INTEGER,
  started_at   INTEGER,
  rl_window    INTEGER NOT NULL DEFAULT 0,
  rl_count     INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (email, mac_id)
);
CREATE INDEX IF NOT EXISTS idx_push_macs_online ON push_macs(online);
