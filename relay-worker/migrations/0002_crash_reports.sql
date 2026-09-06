CREATE TABLE errors (
  fingerprint TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  message TEXT NOT NULL,
  source_file TEXT,
  source_line INTEGER,
  status TEXT NOT NULL DEFAULT 'unresolved',
  first_seen_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  occurrence_count INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX errors_last_seen_idx ON errors (last_seen_at DESC);
CREATE INDEX errors_status_last_seen_idx ON errors (status, last_seen_at DESC);

CREATE TABLE occurrences (
  id TEXT PRIMARY KEY,
  fingerprint TEXT NOT NULL REFERENCES errors (fingerprint) ON DELETE CASCADE,
  occurred_at INTEGER NOT NULL,
  version TEXT,
  environment TEXT,
  instance_key TEXT,
  context TEXT NOT NULL DEFAULT '{}',
  stacktrace TEXT NOT NULL DEFAULT '[]'
);

CREATE INDEX occurrences_fingerprint_time_idx
  ON occurrences (fingerprint, occurred_at DESC);

-- One row per fingerprint per instance per hour bucket. Its presence is what
-- tells ingest to count an occurrence without writing a new occurrence row,
-- which is what stops a single crash-looping install exhausting D1's daily
-- write budget for everyone.
CREATE TABLE ingest_buckets (
  fingerprint TEXT NOT NULL,
  instance_key TEXT NOT NULL,
  hour_bucket INTEGER NOT NULL,
  written INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (fingerprint, instance_key, hour_bucket)
);
