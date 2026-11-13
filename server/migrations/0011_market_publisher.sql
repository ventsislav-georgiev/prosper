-- #1138: the masked publisher value ("pub_" + truncated HMAC of the e-mail, market.ts
-- publisherValue) a version's claim is signed over, so no public route returns the e-mail.
-- NULL = a row signed over the e-mail before #1138: download re-signs it over the masked
-- value after checking the stored signature. packages.owner_email stays the ownership key.
-- 0001-0010 are shipped: only add.
ALTER TABLE package_versions ADD COLUMN publisher TEXT;
