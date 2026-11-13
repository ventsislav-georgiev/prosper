-- #1014 / QA #764 INFO-1: the minute cron finds the cards of expired sign-ins through the sessions
-- that have expired (pushStore.mjs runCron), so it reads those instead of every la_update row and
-- one sessions row per card each minute. The daily cleanup's expires_at < ? uses it too.
-- 0001-0009 are shipped: only add.
CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
