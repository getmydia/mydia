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
--
-- `count` (final review fix round): advanced by ONE atomic
-- `INSERT ... ON CONFLICT DO UPDATE ... RETURNING` per request
-- (checkAndIncrementBucket), not by a separate SELECT-then-decide-then-write
-- sequence -- that two-statement shape is exactly what let 20 concurrent
-- identical-IP submissions all get admitted against this table's 5/hour cap
-- in a real reproduction (D1 only guarantees ordering within one statement
-- or a .batch(), not across two independent .prepare()/.run() calls). `count`
-- is uncapped and monotonic within the hour so the admission decision is
-- unambiguous from the RETURNED value alone (admitted iff `count <= 5`):
-- SQLite serialises writers to the same row even without an explicit
-- transaction wrapper, so the Nth request to actually commit is guaranteed a
-- unique `count = N`, with no stale read in the decision path. A cheap
-- read-only pre-check still runs first purely to avoid paying a write once a
-- bucket is already solidly saturated for the hour (same optimisation the
-- original design relied on) -- it is never the source of truth for whether
-- a request is admitted.
CREATE TABLE feedback_rate_limits (
  bucket_key TEXT PRIMARY KEY,
  hour_bucket INTEGER NOT NULL,
  count INTEGER NOT NULL
);

-- The only index this table needs beyond its primary key, and it exists for
-- the sweep rather than for any request: sweepStaleFeedbackRateLimits
-- (src/obs/sweep.ts) deletes by `hour_bucket < ?`, a column the bucket_key
-- primary key cannot serve. Without it the hourly Cron Trigger full-scans
-- feedback_rate_limits every run, and this table's live cardinality is one row
-- per distinct submitter IP per hour, which nothing in the code bounds.
-- Request-path access is always by bucket_key, so the primary key still covers
-- every read and write ingest performs.
CREATE INDEX feedback_rate_limits_hour_bucket_idx
  ON feedback_rate_limits (hour_bucket);
