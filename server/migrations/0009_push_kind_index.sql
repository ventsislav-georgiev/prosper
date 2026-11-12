-- QA #357 (#1001): the every-minute cron's 8 h purge (kind = 'la_update' AND created_at <= ?)
-- and its read of the rotated cards (kind = 'la_expired') had no index starting with kind, so
-- each run read all of push_tokens (D1 bills rows read). One index serves both. Not partial: a
-- WHERE kind IN ('la_update', 'la_expired') index is not used by either (EXPLAIN QUERY PLAN).
-- 0001-0008 are shipped: only add.
CREATE INDEX IF NOT EXISTS idx_push_tokens_kind ON push_tokens(kind, created_at);
