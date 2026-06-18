-- Supporter model: features are no longer gated; a paid order just records a
-- supporter and the display name shown in the app's About list.

-- Display name captured from the payment provider (Lemon Squeezy user_name).
ALTER TABLE licenses ADD COLUMN name TEXT;

-- Speeds up the public /supporters query (most-recent distinct names).
CREATE INDEX IF NOT EXISTS idx_licenses_supporter
  ON licenses(type, status, issued_at);
