-- Battery saver mode per phone token (#770). 0006/0007 are shipped: only add, so the
-- Worker before #770 keeps working against the migrated DB (its INSERTs take the defaults).

-- The phone's update mode, sent on every POST /push/tokens: 'live' (the default, the #766
-- timing) or 'saver' (paced card updates, at most one per 120 s; blocked edges at once).
ALTER TABLE push_tokens ADD COLUMN mode TEXT NOT NULL DEFAULT 'live';

-- A card's (la_update) send state; the Mac's push_macs.last_push_at stays the Mac's own.
-- pushed_at: the last update APNs took for this card (a saver card's 120 s count from it).
-- due_at: an update is owed from then on (a saver deferral, or a failed send's retry); the
-- minute cron flushes it. fails: APNs failures in a row, so a retry is bounded (QA #600 INFO-2).
ALTER TABLE push_tokens ADD COLUMN pushed_at INTEGER;
ALTER TABLE push_tokens ADD COLUMN due_at INTEGER;
ALTER TABLE push_tokens ADD COLUMN fails INTEGER NOT NULL DEFAULT 0;
