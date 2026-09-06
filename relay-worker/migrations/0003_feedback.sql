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
-- anti-collision-namespaced instance id ("instance:supplied:<sha256 of
-- value>" or "instance:fallback:<sha256 of ip>"), both gating before a
-- submission is validated or stored.
--
-- Row SIZE is bounded by hashing the instance-derived key component
-- (feedbackInstanceRateLimitKey): `instance_id` is an arbitrary
-- client-supplied string with no length cap anywhere, and this check runs
-- BEFORE validation, so an unhashed key would let a row's size be
-- attacker-chosen. hour_bucket being a resettable column rather than part
-- of the key does NOT by itself bound row COUNT the way
-- 0002_crash_reports.sql's ingest_buckets is bounded -- that table's
-- cardinality is capped by real crash/install diversity, but a caller can
-- mint a fresh instance_id on every request at zero cost, so distinct
-- bucket_key values are unbounded here even after hashing. Row count is
-- instead bounded by src/obs/sweep.ts's sweepStaleFeedbackRateLimits,
-- wired to an hourly Cron Trigger (wrangler.jsonc), which deletes any row
-- whose hour_bucket has fallen behind the current one -- the D1 equivalent
-- of the periodic cleaner Elixir's ETS-backed RateLimiter already has built
-- in.
CREATE TABLE feedback_rate_limits (
  bucket_key TEXT PRIMARY KEY,
  hour_bucket INTEGER NOT NULL,
  count INTEGER NOT NULL
);
