-- Backs GET /admin, the maintainer overview. Its windowed aggregates filter
-- on occurred_at alone, and the only pre-existing index on this table is
-- (fingerprint, occurred_at DESC), whose leading column those queries never
-- constrain. Without this index every window query full-scans occurrences and
-- reads every column of every row, which is the unit D1 actually bills.
--
-- instance_key and version trail the sort column so the three heaviest
-- queries (crash count, distinct sources, version breakdown) are satisfied
-- from the index alone and never touch the table. test/stats/schema.test.ts
-- pins that with EXPLAIN QUERY PLAN rather than trusting it: drop either
-- trailing column and those assertions fail.
--
-- The top-errors query joins on fingerprint and is still served by the
-- existing occurrences_fingerprint_time_idx, so it needs nothing here.
CREATE INDEX occurrences_occurred_at_idx
  ON occurrences (occurred_at DESC, instance_key, version);

-- One row per scheduled sweep (src/obs/sweep.ts, wrangler.jsonc's hourly Cron
-- Trigger). Before this, a sweep left no trace anywhere durable, so "is the
-- cron actually running" had no answer short of reading Workers Logs.
--
-- `id` is a plain rowid alias rather than `ran_at` as the primary key on
-- purpose: a manually triggered sweep landing in the same second as the cron
-- would collide on a ran_at key and lose one of the two runs.
--
-- THIS TABLE EVICTS ITSELF. Three tables in this Worker shipped with no
-- eviction path and had to be retrofitted (feedback_rate_limits,
-- ingest_buckets, pairing_claims); a fourth will not repeat it. The same
-- sweep that inserts a row deletes rows older than
-- SWEEP_RUN_RETENTION_SECONDS in the same .batch(), holding this at roughly
-- 168 rows.
CREATE TABLE sweep_runs (
  id INTEGER PRIMARY KEY,
  ran_at INTEGER NOT NULL,
  feedback_rate_limits_deleted INTEGER NOT NULL,
  ingest_buckets_deleted INTEGER NOT NULL,
  pairing_claims_deleted INTEGER NOT NULL,
  duration_ms INTEGER NOT NULL
);

-- Serves both readers: the overview's "latest run" (ORDER BY ran_at DESC
-- LIMIT 1) and the sweep's own retention delete (WHERE ran_at < ?).
CREATE INDEX sweep_runs_ran_at_idx ON sweep_runs (ran_at DESC);
