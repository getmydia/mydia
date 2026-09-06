-- The key carries its own version prefix ("pairing:" or "pairing:v2:"), which
-- is what keeps the two keyspaces from colliding, exactly as the Redis keys did.
CREATE TABLE pairing_claims (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX pairing_claims_expires_idx ON pairing_claims (expires_at);
