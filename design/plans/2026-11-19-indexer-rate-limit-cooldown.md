# Indexer Rate-Limit Cooldown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Mydia from repeating requests to an indexer that answered HTTP 429, count every search attempt, keep the Cardigann health sweep out of the search burst, and label every rate-limit error with who imposed it.

**Architecture:** Cooldown and success state live in `Mydia.Indexers.RateLimiter`'s ETS table. `Mydia.Indexers.search/3` is the single gate in front of every direct adapter (Prowlarr excluded). The Cardigann health sweep and the movie/TV jobs read that state; nothing is persisted.

**Tech Stack:** Elixir, ETS, Oban cron, Req, Bypass for HTTP tests.

**Spec:** `design/specs/2026-11-19-indexer-rate-limit-cooldown-design.md`

## Global Constraints

- Cooldown ladder: 1m, 5m, 15m, 30m, 1h, 3h, 6h, then 6h forever. In ms: `[60_000, 300_000, 900_000, 1_800_000, 3_600_000, 10_800_000, 21_600_000]`.
- Wait = `max(ladder step, Retry-After)`; Retry-After capped at 24h (`86_400_000` ms).
- A 429 recorded while a cooldown is active does not step the ladder; the cooldown keeps the later end.
- `record_success/1` clears the cooldown and resets the ladder.
- Prowlarr (`type: :prowlarr`) is never gated or cooled down.
- `Error.details.source` on every `:rate_limited` error is one of `:tracker`, `:cooldown`, `:local_limit`, `:daily_cap`.
- Cardigann health cron: `"45 * * * *"`. Search crons unchanged.
- No migrations. Nothing persisted.
- Commits: stage every path first, then `direnv exec . git commit -F <msgfile>` (one commit per step), then `git show --stat HEAD`. Never `--no-verify`. No em dashes in docs, logs or commit messages.
- Run tests with `./dev mix test <path>`.

## Review Focus

1. **A 429 with `Retry-After: 0`.** Expected: the ladder step still applies, never an immediate retry. Test in Task 1.
2. **A `Retry-After` in HTTP-date form or garbage.** Expected: a date in the past or unparsable falls back to the ladder step; it must not crash or yield a negative wait. Test in Task 2.
3. **Two indexers with the same display name, or a Cardigann definition and an `IndexerConfig` with colliding ids.** Cooldown is keyed by id, never name. Test in Task 3 (two ids, one cools, the other still searches).
4. **Manual search during a cooldown.** Expected: indexer row shows "cooling down after HTTP 429 until HH:MM" and Bypass sees no request. Test in Task 3 via `search_all/2` with `on_indexer_result`.
5. **Mixed outcomes in a background search** (one indexer 429, another returns zero rows). Expected: the item still gets its `no_results` backoff. Test in Task 5.

---

### Task 1: Cooldown, success and atomic search slots in `RateLimiter`

**Files:**
- Modify: `lib/mydia/indexers/rate_limiter.ex`
- Create: `test/mydia/indexers/rate_limiter_cooldown_test.exs`
- Modify: `test/mydia/indexers/rate_limiter_throttle_test.exs:38-42` (drops the removed `check_rate_limit/2`)

**Interfaces:**
- Produces:
  - `RateLimiter.take_search_slot(id :: String.t(), limit :: integer() | nil) :: :ok | {:error, :limited, non_neg_integer()}`. `nil` or `<= 0` is `:ok`. Implemented as `reserve_window({:search, id}, limit, :timer.minutes(1))`.
  - `RateLimiter.cooldown_until(id) :: DateTime.t() | nil`
  - `RateLimiter.record_rate_limited(id, retry_after_ms :: non_neg_integer() | nil) :: DateTime.t()` (the cooldown end)
  - `RateLimiter.record_success(id) :: :ok`
  - `RateLimiter.last_success_at(id) :: DateTime.t() | nil`
  - `RateLimiter.note_retry_after(id, ms :: non_neg_integer()) :: :ok`, a hint `record_rate_limited/2` consumes (and deletes) when its own `retry_after_ms` is nil. Task 2's WASM path writes it.
  - `get_stats/1` keeps its keys; `requests_last_minute` now counts `{:search, id}` window slots via `check_window/3`.
  - Removed: `check_rate_limit/2`, `record_request/1`.

- [ ] **Step 1: Write the failing tests** in `rate_limiter_cooldown_test.exs` (`async: true`, `unique_id/0` as in the throttle test):

```elixir
test "a first 429 cools down for one ladder step" do
  id = unique_id()
  until = RateLimiter.record_rate_limited(id, nil)
  assert_in_delta DateTime.diff(until, DateTime.utc_now(), :millisecond), 60_000, 1_000
  assert RateLimiter.cooldown_until(id) == until
end
```

  Plus these (`RateLimiter.expire_cooldown/1`, defined in Step 3, is the only test hook):
  - `"Retry-After of 0 still waits one ladder step"`: `record_rate_limited(id, 0)` ends about 60s out.
  - `"a 429 during an active cooldown does not step"`: two `record_rate_limited(id, nil)` calls return ends within 1s of each other (both about 60s out).
  - `"a 429 after expiry steps to 5 minutes"`: `record_rate_limited(id, nil)`, `RateLimiter.expire_cooldown(id)`, `record_rate_limited(id, nil)` ends about 300_000 ms out.
  - `"the ladder stops at 6 hours"`: eight record/expire cycles; the last end is about 21_600_000 ms out.
  - `"Retry-After longer than the step wins"`: `record_rate_limited(id, 120_000)` ends about 120s out.
  - `"Retry-After is capped at 24 hours"`: `record_rate_limited(id, 200_000_000)` ends about 86_400_000 ms out.
  - `"a noted hint is used when the error has none, once"`: `note_retry_after(id, 600_000)`; `record_rate_limited(id, nil)` ends about 600s out; after `expire_cooldown(id)` a second `record_rate_limited(id, nil)` ends about 300s out (hint consumed).
  - `"success clears the cooldown and resets the ladder"`: record, `record_success(id)`, `cooldown_until(id) == nil`, `last_success_at(id)` within 1s of now; then `record_rate_limited(id, nil)` is about 60s out.
  - `"take_search_slot allows the limit then refuses"`: with limit 2, two `:ok` then `{:error, :limited, 2}`; `get_stats(id).requests_last_minute == 2`.
  - `"take_search_slot under concurrency never exceeds the limit"`: 20 tasks, limit 3, exactly 3 `:ok`.
  - `"clear_indexer drops cooldown, success and slots"`.

- [ ] **Step 2: Run and confirm failure**

Run: `./dev mix test test/mydia/indexers/rate_limiter_cooldown_test.exs`
Expected: FAIL, `UndefinedFunctionError` for `record_rate_limited/2`.

- [ ] **Step 3: Implement** in `rate_limiter.ex`.
  - Keep ETS objects 2-tuples so the existing cleanup and `clear_indexer` match specs cannot misread them: `{{:cooldown, id}, {until_mono, level, until_utc}}`, `{{:success, id}, utc}`, `{{:retry_hint, id}, ms}`. Erlang term order puts binaries after numbers, so the existing `{{:_, :"$1"}, :_}` cleanup guard never deletes these keys; keep it that way and say so in a comment.
  - `level` is the index of the step used (0-based). On record: if an unexpired cooldown exists, keep `level`, set end to the later of the existing end and `now + wait(level)`; else `level = min(previous_level + 1, 6)` when a previous (expired) entry exists, `0` otherwise. Race: use `:ets.insert_new` for the first entry and `select_replace` on the observed object for updates, retrying on loss, as `claim_slot/5` does.
  - `expire_cooldown(id)` is `@doc false`, sets `until_mono` to now; tests only.
  - `clear_indexer/1` also deletes `{:cooldown, id}`, `{:success, id}`, `{:retry_hint, id}` and `{:window, {:search, id}, _, _}` slots.
  - Cleanup also deletes cooldown entries whose end is more than 24h past (ladder idle).
  - Update the moduledoc usage example to `take_search_slot/2`.

- [ ] **Step 4: Keep the app compiling.** Fix `rate_limiter_throttle_test.exs:40` to assert `RateLimiter.get_stats(id).requests_last_minute == 0` only. In `lib/mydia/indexers.ex:90-132` replace each `check_rate_limit`/`record_request` pair with a `take_search_slot/2` call before the adapter, keeping today's error text on `{:error, :limited, _}`. Nothing else in `indexers.ex` changes here; Task 3 rebuilds these clauses.

- [ ] **Step 5: Run**

Run: `./dev mix test test/mydia/indexers/rate_limiter_cooldown_test.exs test/mydia/indexers/rate_limiter_throttle_test.exs test/mydia/indexers_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit** `feat(indexers): track 429 cooldowns and take search slots atomically`

---

### Task 2: Read `Retry-After` on every 429 path

**Files:**
- Modify: `lib/mydia/indexers/adapter/error.ex:314-378`
- Modify: `lib/mydia/indexers/cardigann_search_engine.ex:654-675` (`validate_response/1`)
- Modify: `lib/mydia/indexers/cardigann/wasm/host_http.ex:174-185` (`exchange/2`)
- Test: `test/mydia/indexers/adapter/error_test.exs` (create if absent), `test/mydia/indexers/cardigann_search_engine_test.exs`, `test/mydia/indexers/cardigann/wasm/host_http_test.exs` (create if absent)

**Interfaces:**
- Consumes: `RateLimiter.note_retry_after/2` (Task 1).
- Produces: `Error.retry_after_ms(headers :: [{String.t(), String.t()}] | map()) :: non_neg_integer() | nil`. Accepts delta-seconds or an IMF-fixdate HTTP date; past dates, negatives and garbage return nil. `from_req_error/1` and `validate_response/1` both put `retry_after` (ms) in `details`; `from_req_error/1` changes from seconds to ms (only Task 3 reads it).

- [ ] **Step 1: Failing tests**
  - `Error.retry_after_ms([{"Retry-After", "120"}]) == 120_000`; header name case-insensitive; an HTTP date 90s ahead gives 85_000..90_000; `"Wed, 21 Oct 2015 07:28:00 GMT"` gives nil; `"soon"` gives nil; `[]` gives nil; Req's map-of-lists headers (`%{"retry-after" => ["30"]}`) gives 30_000.
  - `CardigannSearchEngine.validate_response(%{status: 429, body: "", headers: [{"retry-after", "30"}]})` returns `{:error, %Error{type: :rate_limited, details: %{retry_after: 30_000}}}`; without the header, `details.retry_after` is nil.
  - Host HTTP: a Bypass 429 with `Retry-After: 45` through `HostHttp.exchange/2` leaves `RateLimiter.record_rate_limited(ctx.definition_id, nil)` ending about 45s out. Build `ctx` the way existing host_http tests do; if none exist, copy the ctx construction from `Cardigann.Wasm.Adapter` near line 583.

- [ ] **Step 2: Run, expect FAIL** (`retry_after_ms/1` undefined).

Run: `./dev mix test test/mydia/indexers/adapter/error_test.exs test/mydia/indexers/cardigann_search_engine_test.exs`

- [ ] **Step 3: Implement.** HTTP date via `:httpd_util.convert_request_date/1` (returns `:bad_date` on failure). In `exchange/2`, after `do_exchange`, on `{:ok, %{status: 429, headers: h}}` call `note_retry_after/2` when `retry_after_ms(h)` is an integer. The WASM `request_limit` error then reaches Task 3's gate with no `retry_after`, and `record_rate_limited/2` consumes the hint.

- [ ] **Step 4: Run, expect PASS** (same command plus the host_http test).

- [ ] **Step 5: Commit** `feat(indexers): carry Retry-After on Cardigann and WASM 429s`

---

### Task 3: The gate in `Indexers.search/3`, rate-limit sources, and `search_all` error types

**Files:**
- Modify: `lib/mydia/indexers.ex:84-139` (both id-carrying `search/3` clauses), `:200-330` (`search_all/2`), `:649-745` (`search_with_metrics/3`, error helpers)
- Modify: `lib/mydia/indexers/tracker_limits.ex:56-66` (`guarded_search/4`)
- Modify: `lib/mydia/indexers/README.md` (new section "Rate limits and cooldown" before "Tracker limits")
- Test: `test/mydia/indexers_test.exs` (new `describe "rate-limit gate"`), `test/mydia/indexers/tracker_limits_test.exs`

**Interfaces:**
- Consumes: Task 1 API; Task 2's `details.retry_after`.
- Produces:
  - Every `:rate_limited` error from `search/3` has `details.source` and, for `:tracker` and `:cooldown`, `details.until :: DateTime.t()`.
  - `search_all/2` result map gains `indexers_searched :: non_neg_integer()`; each `indexer_errors` entry gains `error_type :: atom()` (the `Adapter.Error` type; `:deadline` / `:crashed` for exits).
  - `Indexers.deferred_by_rate_limits?(search_all_result :: map()) :: boolean()`: true when `results == []`, `indexers_searched > 0`, `length(indexer_errors) == indexers_searched`, and every entry has `error_type: :rate_limited`.

- [ ] **Step 1: Failing tests.** Register a stub adapter type in `setup` with `Adapter.Registry.register(:gate_stub, StubAdapter)` where `StubAdapter.search/3` sends `{:searched, config.id}` to the test pid and returns what `config.reply` says. Use `%{type: :gate_stub, id: unique, name: "Stub", rate_limit: nil, reply: ...}` configs.
  - `"a 429 cools the indexer and the next call sends nothing"`: reply `{:error, Error.rate_limited("x", %{retry_after: 120_000})}`; first call returns `details.source == :tracker` and `until` about 120s out; second call returns `source: :cooldown`, and `refute_received {:searched, _}` after the first message is consumed.
  - `"success clears a cooldown"`: `RateLimiter.record_rate_limited(id, nil)`, `RateLimiter.expire_cooldown(id)`, ok reply, `cooldown_until(id) == nil`.
  - `"a failed search still takes a slot"`: `rate_limit: 1`, reply `{:error, Error.search_failed("x")}`; second call returns `source: :local_limit` and only one `{:searched, _}` arrives.
  - `"cooldown is per id"`: id A cooled, id B with the same `name` still searches.
  - `"prowlarr is never gated"`: `RateLimiter.record_rate_limited(id, nil)` for a `%Settings.IndexerConfig{type: :prowlarr}` id, then `search/3` reaches the adapter (use Bypass for Prowlarr as `indexers_test.exs` already does, or assert the result is not `source: :cooldown`).
  - `"manual search reports the cooldown on the indexer row"`: through `search_all/2` with `on_indexer_result` capturing progress; the cooled indexer's `error` matches `~r/cooling down after HTTP 429 until \d\d:\d\d/`.
  - `"deferred_by_rate_limits?/1"`: true for all-rate-limited; false when one indexer succeeded with `[]`; false for a `:search_failed` error; false for `indexers_searched: 0`.
  - In `tracker_limits_test.exs`: the existing daily-cap test also asserts `details.source == :daily_cap`.

- [ ] **Step 2: Run, expect FAIL.**

Run: `./dev mix test test/mydia/indexers_test.exs test/mydia/indexers/tracker_limits_test.exs`

- [ ] **Step 3: Implement** one private `gated_search(id, name, rate_limit, fun)` used by both clauses (the `%IndexerConfig{}` clause keeps converting to an adapter config first; a `:prowlarr` type skips the gate and calls straight through). Order: cooldown check, `take_search_slot/2`, call, then `record_success/1` on `{:ok, _}` or `record_rate_limited(id, details.retry_after)` on an adapter `:rate_limited` error not already carrying a `source`.

  Messages and logs (exact copy; `HH:MM` is `Calendar.strftime(until, "%H:%M")` in UTC, matching other indexer logs):
  - tracker error message: `"Tracker answered HTTP 429; paused until HH:MM"`; `Logger.warning("#{name} answered HTTP 429; pausing it until HH:MM", retry_after_ms: ..., level: ...)`
  - cooldown: message `"Cooling down after HTTP 429 until HH:MM"`; `Logger.info("Skipping #{name}: cooling down after HTTP 429 until HH:MM")`
  - local limit: message `"Mydia's limit of #{limit} searches/minute reached"`; `Logger.info("Skipping #{name}: Mydia's limit of #{limit} searches/minute reached")`
  - `TrackerLimits` keeps its text and adds `%{source: :daily_cap}` to `Error.rate_limited/2`.

  The manual-search test regex is case-insensitive on "cooling".

- [ ] **Step 4: Run, expect PASS** (same command), then `./dev mix test test/mydia/indexers` to catch callers of the changed `search_all` shape.

- [ ] **Step 5: README.** Section "Rate limits and cooldown": gate order, the ladder and Retry-After rules (Global Constraints values), the four sources, Prowlarr exclusion, manual search honouring cooldowns, state is ETS and a restart forgets it, WASM 429s get Retry-After through the host-HTTP hint.

- [ ] **Step 6: Commit** `feat(indexers): hold off an indexer after HTTP 429 and label rate-limit sources`

---

### Task 4: Cardigann health sweep

**Files:**
- Modify: `config/config.exs:328-329` (cron `"45 * * * *"`)
- Modify: `lib/mydia/indexers/cardigann_health_check.ex` (`check_all_enabled/0` :158-180, `probe_search/3` :217-250, `prowlarr_probe/2` :377-399, `prowlarr_result/3`, `search_leg/6` :516-594, `update_health_status/2` :699-725)
- Modify: `lib/mydia/indexers/README.md` (one paragraph in the new section)
- Test: `test/mydia/indexers/cardigann_health_check_test.exs`, `test/mydia/jobs/cardigann_health_check_test.exs` (cron assertion; create if absent, model it on `test/mydia/jobs/file_analysis_test.exs:258`)

**Interfaces:**
- Consumes: `cooldown_until/1`, `last_success_at/1`, `take_search_slot/2`, `record_rate_limited/2`, `record_success/1` (Task 1); `details.retry_after` (Task 2).
- Produces: `probe_search/3` may return `{:rate_limited, Error.t()}` (new `probe_outcome` case). Result maps may carry `rate_limited: true`.

- [ ] **Step 1: Failing tests** (Bypass, existing fixtures in `cardigann_health_check_test.exs`):
  - `"sweep skips a definition that is cooling down"`: `record_rate_limited(definition.id, nil)`; `check_all_enabled/0`; Bypass expects zero requests (`Bypass.stub` that flunks); stored `health_status` and `consecutive_failures` unchanged.
  - `"sweep trusts a recent successful search"`: `record_success(definition.id)`; no requests; row `health_status == "healthy"` and `last_health_check_at` refreshed.
  - `"a probe 429 cools the definition without counting a failure"`: Bypass search path answers 429 with `Retry-After: 60`; after the sweep `consecutive_failures` is unchanged, `health_status == "degraded"`, `cooldown_until(definition.id)` about 60s out.
  - `"the Test button probes during a cooldown and a success clears it"`: `record_rate_limited(definition.id, nil)`; `test_connection(definition.id)` with a 200 Bypass response; `cooldown_until == nil`.
  - `"a probe takes a search slot"`: after a sweep that probed, `RateLimiter.get_stats(definition.id).requests_last_minute == 1`.
  - Cron: the crontab entry for `Mydia.Jobs.CardigannHealthCheck` is `"45 * * * *"`.

- [ ] **Step 2: Run, expect FAIL.**

Run: `./dev mix test test/mydia/indexers/cardigann_health_check_test.exs test/mydia/jobs/cardigann_health_check_test.exs`

- [ ] **Step 3: Implement.**
  - `check_all_enabled/0` filters each definition through `sweep_action(definition) :: :probe | {:skip_cooling, DateTime.t()} | :trust_recent_success` before `execute_health_check/2`. "Recent" is `last_success_at` within 3_600 s. `:trust_recent_success` writes `health_status: "healthy"`, `last_health_check_at: now` through the existing conditional update and returns a result map with `message: "Healthy: a search succeeded at HH:MM"`. `:skip_cooling` writes nothing and logs `"[CardigannHealthCheck] #{name} skipped: cooling down until HH:MM"`. A `:probe` takes `take_search_slot(definition.id, Indexers.cardigann_config(definition).rate_limit)`; when refused, skip like cooling with message "skipped: Mydia's per-minute limit reached".
  - `test_connection/2` does not go through `sweep_action/1`.
  - `probe_search/3`'s `else` matches `{:error, %Error{type: :rate_limited} = e}` before the generic clause and returns `{:rate_limited, e}`. `search_leg/6` and `prowlarr_probe/2` handle it: `record_rate_limited(definition.id, e.details[:retry_after])`, result `%{success: false, rate_limited: true, status: "degraded", message: "Tracker answered HTTP 429; paused until HH:MM", response_time_ms: elapsed, error: e.message}`. Any successful probe calls `record_success(definition.id)`.
  - `update_health_status/2` gains a first clause for `%{rate_limited: true}` writing only `health_status` and `last_health_check_at`.

- [ ] **Step 4: Run, expect PASS** (same command), then `./dev mix test test/mydia/indexers/cardigann_health_check_prowlarr_test.exs test/mydia/indexers/cardigann_health_test.exs`.

- [ ] **Step 5: README paragraph** on the sweep rules (minute 45, skip when cooling or a search succeeded in the last hour, a 429 does not count as a failure, Test always probes).

- [ ] **Step 6: Commit** `fix(indexers): keep the Cardigann health sweep out of rate-limited trackers`

---

### Task 5: No search backoff when every indexer was rate-limited

**Files:**
- Modify: `lib/mydia/jobs/movie_search.ex:592-615` (`search_movie/3`)
- Modify: `lib/mydia/jobs/tv_show_search.ex:1002-1020` (season-pack search, returns the tuple used at :918 and :1843), `:1391-1405` (episode search), callers at `:918-925` and `:1843-1844`
- Modify: `design/specs/2026-11-19-indexer-rate-limit-cooldown-design.md` section 6 (see Step 3 note)
- Test: `test/mydia/jobs/movie_search_test.exs`, `test/mydia/jobs/tv_show_search_test.exs`

**Interfaces:**
- Consumes: `Indexers.deferred_by_rate_limits?/1` (Task 3).
- Produces: the season-pack helper returns `{:rate_limited, query}` alongside its existing `{:no_results, query}`; job return values are otherwise unchanged (`:no_results` for movies).

- [ ] **Step 1: Failing tests.** Each test seeds indexers through the fixtures these test files already use and makes them rate-limited by calling `RateLimiter.record_rate_limited/2` on every enabled indexer id before the job runs (no HTTP needed: the gate refuses).
  - Movie: `"all indexers cooling down records no backoff"`: run `MovieSearch` `specific` mode; no `SearchBackoff` row for the movie.
  - Movie: `"one indexer cooling and one empty still backs off"`: second indexer answers zero rows (Bypass Torznab with an empty feed); a `no_results` backoff row exists.
  - TV: `"all indexers cooling down records no episode or season backoff"` for a season search that falls back to episodes.

- [ ] **Step 2: Run, expect FAIL.**

Run: `./dev mix test test/mydia/jobs/movie_search_test.exs test/mydia/jobs/tv_show_search_test.exs`

- [ ] **Step 3: Implement.** In each `{:ok, %{results: []} = res}` branch, check `Indexers.deferred_by_rate_limits?(res)` first: log `Logger.info("Search deferred: every indexer is rate-limited", media_item_id: ..., query: ...)` and skip the `record_*_backoff` call. For the season pack, return `{:rate_limited, query}`; its callers fall back to episodes exactly as for `:no_results` but without `record_season_backoff`.

  Spec correction: section 6 says to log a `search.deferred` event. That event renders as "Grab delayed" in the activity feed (`MydiaWeb.ActivityLive.EventText`), which would mislabel this case, so the plan uses a log line only. Edit spec section 6 to say "Log `Search deferred: every indexer is rate-limited`; no event is recorded, since `search.deferred` means a grab delay" in the same commit.

- [ ] **Step 4: Run, expect PASS** (same command).

- [ ] **Step 5: Full check.** `./dev mix precommit` (in five foreground chunks per test/README.md if it outruns the shell timeout). Expected: clean.

- [ ] **Step 6: Commit** `fix(search): skip search backoff when every indexer is rate-limited`

---

### Task 6: Request-rate visibility (spec section 8)

Added after the plan was approved, at the maintainer's request.

**Files:**
- Modify: `lib/mydia/indexers/search_stats/network.ex` (request counter beside the time total)
- Modify: outbound paths: `lib/mydia/indexers/cardigann_search_engine.ex` (`safe_request/3`), `lib/mydia/indexers/cardigann/login/http.ex:87`, `lib/mydia/indexers/flaresolverr.ex:378`, `lib/mydia/indexers/cardigann/wasm/host_http.ex` (`exchange/2`), `lib/mydia/indexers/adapter/newznab.ex:103`, `lib/mydia/indexers/adapter/jackett.ex:91`, `lib/mydia/indexers/cardigann_health_check.ex:638`
- Create: `priv/repo/migrations/<real timestamp>_add_http_requests_to_indexer_search_events.exs`
- Modify: `lib/mydia/indexers/search_stats/{event,telemetry,summary}.ex`, `lib/mydia/indexers/search_stats.ex`, `lib/mydia/indexers.ex` (`search_with_metrics/3`, `error_outcome/1`)
- Modify: `lib/mydia_web/live/admin_indexers_live/search_stats_components.ex`, `lib/mydia_web/live/admin_indexers_live/components.ex` (rows at :240 and :373), `lib/mydia_web/live/admin_indexers_live/index.ex` (assign cooldowns)
- Test: `test/mydia/indexers/search_stats_test.exs` (or the existing summary test file), `test/mydia/indexers_test.exs`, `test/mydia_web/live/admin_indexers_live/*_test.exs`

**Interfaces:**
- Consumes: Task 3's `details.source`; Task 1's `RateLimiter.cooldown_until/1`.
- Produces:
  - `SearchStats.Network.add_request() :: :ok`, `SearchStats.Network.take_requests() :: non_neg_integer() | nil`; `reset/0` clears both.
  - `Summary` fields `requests :: non_neg_integer()`, `peak_per_minute :: non_neg_integer()`, `rate_limited :: non_neg_integer()` (outcome `"rate_limited"`), `skipped :: non_neg_integer()` (outcomes starting `"skipped_"`). `attempts` and `successes` exclude skipped rows.
  - Outcomes for gate refusals: `:skipped_cooldown`, `:skipped_local_limit`, `:skipped_daily_cap`.

- [ ] **Step 1: Failing tests**
  - Counting: a Cardigann search through `search_all/2` against a Bypass definition with two search paths records `http_requests == 2` on its event; a Newznab search records 1; a search refused by a cooldown records outcome `"skipped_cooldown"` and `http_requests` nil or 0.
  - Login in another process: if `Cardigann.SessionManager` runs the login in a GenServer, a search that logs in first records login requests plus search requests (assert the sum against Bypass hit counts).
  - `Summary.build/3`: rows with outcomes ok, rate_limited, skipped_cooldown and `http_requests` 3, 1, nil give `attempts == 2`, `requests == 4`, `rate_limited == 1`, `skipped == 1`; `peak_per_minute` is the largest per-minute sum of `http_requests` by `inserted_at` minute.
  - LiveView: the stats strip renders `#<stats_id>-requests`, `-rate-limited` (class `text-warning` when above 0) and `-skipped`; an indexer with `RateLimiter.record_rate_limited/2` set renders `#indexer-cooldown-<id>` with "Cooling down until".
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
  - Count at each outbound path after the request is sent (success or HTTP error; not for a refused or replayed request: skip when `Seam.replaying?()`).
  - Network counts are process-local. Verify each path runs in the search task's process; where one does not (a SessionManager GenServer, a spawned task), return the count to the caller and add it there. Do not switch to a global counter.
  - Migration: `add :http_requests, :integer` (nullable), portable on both adapters. Use a real timestamp and run the duplicate-version check from AGENTS.md, "Migration filenames", before committing.
  - `error_outcome/1`: `:rate_limited` with source `:cooldown`/`:local_limit`/`:daily_cap` maps to the matching `skipped_*` atom; everything else unchanged.
  - Telemetry carries `http_requests` as a measurement; `Event` stores it; `SearchStats.summary/2` selects `inserted_at` and `http_requests` too.
  - `search_with_metrics/3` completion log (`Logger.debug` today) gains `http_requests: n` metadata and stays at `debug` (the UI is the primary surface; 429s and skips already log at warning and info).
  - UI: three `stat` cells after Timeouts, copy via gettext: "Requests" (value `requests`, suffix "peak %{n}/min"), "429s", "Skipped". Cooldown badge: `<span class="badge badge-warning badge-sm">` with `hero-clock` icon, "Cooling down until %{time}" in UTC `%H:%M`, beside the existing health badge on both row variants. `index.ex` assigns `cooldowns: %{id => DateTime}` built from `RateLimiter.cooldown_until/1` for the listed indexers on mount and on the existing stats refresh.
  - Run `./dev mix gettext.extract --merge` if the gettext README requires it for new strings.
- [ ] **Step 4: Run, expect PASS**, then `./dev mix test test/mydia/indexers test/mydia_web/live/admin_indexers_live`.
- [ ] **Step 5: README:** add a paragraph to "Rate limits and cooldown" on what `http_requests` counts and that skips are not requests.
- [ ] **Step 6: Commit** `feat(indexers): show HTTP requests, 429s and skips per indexer`
