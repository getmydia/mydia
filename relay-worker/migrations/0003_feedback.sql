CREATE TABLE feedback_submissions (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  message TEXT NOT NULL,
  contact TEXT,
  instance_id TEXT,
  mydia_version TEXT,
  source_ip TEXT,
  state TEXT NOT NULL DEFAULT 'unread',
  github_ref TEXT,
  inserted_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX feedback_state_inserted_idx
  ON feedback_submissions (state, inserted_at DESC);

-- Backs POST /feedback's rate limiting (src/feedback/ingest.ts's
-- checkFeedbackRateLimit), mirroring router.ex's handle_feedback/1: 5
-- requests/hour, checked independently by client IP ("ip:<ip>") and by an
-- anti-collision-namespaced instance id ("instance:supplied:<value>" or
-- "instance:fallback:<ip>"), both gating before a submission is validated
-- or stored. hour_bucket is a resettable column, not part of the key, the
-- same fixed-window trade 0002_crash_reports.sql's ingest_buckets makes: one
-- row per distinct bucket_key, not one per key per hour that has ever
-- elapsed.
CREATE TABLE feedback_rate_limits (
  bucket_key TEXT PRIMARY KEY,
  hour_bucket INTEGER NOT NULL,
  count INTEGER NOT NULL
);
