-- Marketplace categories + theme previews.
-- kind: 'extension' (default) | 'theme' — a package that contributes [[themes]].
-- preview: optional JSON ({themes:[{title,appearance,colors{token:hex}}]}) the
-- browse UI renders as a look-and-feel strip. Client-computed at publish.
ALTER TABLE packages ADD COLUMN kind TEXT NOT NULL DEFAULT 'extension';
ALTER TABLE packages ADD COLUMN preview TEXT;
CREATE INDEX IF NOT EXISTS idx_packages_kind ON packages(kind, updated_at);
