CREATE TABLE errors (
  fingerprint TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  message TEXT NOT NULL,
  source_file TEXT,
  source_line INTEGER,
  status TEXT NOT NULL DEFAULT 'unresolved',
  first_seen_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  occurrence_count INTEGER NOT NULL DEFAULT 0,
  -- Set to 1 (via `MAX(errors.count_is_floor, excluded.count_is_floor)` in
  -- src/crashes/ingest.ts's upsert) the moment ANY of this fingerprint's
  -- ingest_buckets rows ever reaches MAX_OCCURRENCE_ROWS_PER_BUCKET, and
  -- NEVER reset back to 0 afterwards. See ingest_buckets.saturated below for
  -- why this can't live on that table instead -- this column is the durable
  -- half of that story. A dashboard must read THIS column, not
  -- ingest_buckets.saturated, to decide whether occurrence_count is exact.
  count_is_floor INTEGER NOT NULL DEFAULT 0
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

-- One row per (fingerprint, instance) -- NOT per hour. `hour_bucket` is a
-- plain column here, not part of the key: ingest reads this row first, and
-- when its stored hour_bucket differs from the current one it resets
-- `written`/`saturated` back to a fresh count instead of inserting a new
-- row. Keying on (fingerprint, instance, hour) instead would grow this table
-- by one row per fingerprint/instance for every hour that has ever elapsed,
-- forever, with nothing to evict it.
--
-- `written` is a write BUDGET, not a crash count: ingest checks this row
-- BEFORE touching `errors` or `occurrences`, and once `written` reaches
-- MAX_OCCURRENCE_ROWS_PER_BUCKET (3, in src/crashes/ingest.ts) for the
-- current hour, it performs NO writes at all for the rest of that hour --
-- not to `errors`, not to this table, not to `occurrences`. This is what
-- actually bounds D1 writes: an `INSERT ... ON CONFLICT DO UPDATE` reports a
-- write on every call whether it inserts or updates, so unconditionally
-- upserting `errors` on every request (as an earlier version of this
-- migration's comment implied was already the design) would have cost
-- roughly 2 writes per request regardless of the cap -- a storm of N
-- requests would still perform ~2N writes, only the `occurrences` insert
-- among them was ever actually capped.
--
-- One consequence: once a bucket saturates, `errors.occurrence_count` stops
-- advancing too (its upsert is part of what gets skipped), so it becomes a
-- floor, not an exact count, for the rest of that hour. `saturated` records
-- that this happened -- but ONLY for as long as this exact row's current
-- hour window lasts. It resets to 0 the moment a fresh hour's write lands
-- for the same (fingerprint, instance_key) pair (a fresh hour gets a fresh
-- budget), and that reset is in-place: nothing preserves what `saturated`
-- was a moment before.
--
-- That reset is exactly right for what THIS table is for -- deciding
-- whether to admit the CURRENT hour's writes -- and exactly wrong for
-- answering "is errors.occurrence_count exact?" for a fingerprint whose
-- misbehaving install keeps crashing past the hour boundary: saturate hour
-- H, then send one single further crash in hour H+1, and this row flips
-- back to `saturated = 0` even though every crash dropped during H's
-- throttling is gone forever and will never be counted -- the total is
-- STILL a floor, permanently, regardless of what any later hour's traffic
-- looks like. A dashboard reading `saturated` directly would show a
-- precise-looking number at exactly the moment (some time after a storm)
-- an operator is most likely to look. `errors.count_is_floor` is the fix:
-- a separate, sticky, never-reset flag set the instant any bucket for that
-- fingerprint ever saturates. Keep using `saturated` for what it's
-- correctly used for (the live per-hour admission decision in
-- src/crashes/ingest.ts); read `count_is_floor` for "is the total exact?".
-- `hits` (final review fix round): an UNCAPPED count of requests admitted
-- past the burst-guard rate limiter for this (fingerprint, instance_key) in
-- the current hour_bucket, advanced by ONE atomic
-- `INSERT ... ON CONFLICT DO UPDATE ... RETURNING` statement
-- (src/crashes/ingest.ts) rather than by a separate SELECT-then-decide-then-
-- write sequence. That collapse is what actually closes the concurrency
-- race the original two-statement design had: D1 only guarantees ordering
-- within a single statement (or a .batch()), not across two independent
-- .prepare()/.run() calls, so a SELECT followed later by a separate INSERT
-- left a window where N concurrent requests could all read the
-- pre-increment state and all decide to write, defeating the cap entirely
-- (measured: 20 concurrent identical crash reports produced 142 writes
-- against a cap the sequential-only test suite asserted was always 23).
-- `hits` being uncapped and monotonic within the hour is what makes the
-- admission decision unambiguous from the RETURNED value alone: the Nth
-- concurrent request to actually commit is guaranteed a unique hits = N
-- (SQLite serialises writers to the same row even without an explicit
-- transaction wrapper), so "admitted" is simply `hits <= cap`, no stale
-- read involved.
CREATE TABLE ingest_buckets (
  fingerprint TEXT NOT NULL,
  instance_key TEXT NOT NULL,
  hour_bucket INTEGER NOT NULL,
  hits INTEGER NOT NULL DEFAULT 0,
  written INTEGER NOT NULL DEFAULT 0,
  saturated INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (fingerprint, instance_key)
);
