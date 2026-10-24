-- Live session status hardening (#524, QA #357 on #521). 0006 is shipped: only add.

-- L1: the session that registered a token. POST /auth/logout deletes the rows of its
-- hash; the daily cleanup deletes rows whose hash is no longer in sessions. Rows
-- written before this column existed have '' and go at the first daily cleanup.
ALTER TABLE push_tokens ADD COLUMN token_hash TEXT NOT NULL DEFAULT '';
CREATE INDEX IF NOT EXISTS idx_push_tokens_session ON push_tokens(token_hash);

-- L4: JSON array of the session names that were blocked in the Mac's last sessions
-- post. Kept across a lapse or an offline, so a session blocked throughout never
-- alerts again on return.
ALTER TABLE push_macs ADD COLUMN blocked TEXT NOT NULL DEFAULT '[]';

-- L5: bumped by every writer of the row; the post upsert and the cron update are
-- conditional on the rev they loaded.
ALTER TABLE push_macs ADD COLUMN rev INTEGER NOT NULL DEFAULT 0;
