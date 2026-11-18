-- #1283 (QA r1176 R1073-q1): the minute cron reads an offline Mac only while its end may still be
-- retried, push_macs.last_seen >= now - 1 h (pushStore.mjs runCron), so one offline Mac costs no
-- reads after that hour instead of ~1,440-2,880 a day. This index lets the planner take that range
-- on (online, last_seen) without reading the rest. 0001-0011 are shipped: only add.
CREATE INDEX IF NOT EXISTS idx_push_macs_online_seen ON push_macs(online, last_seen);
