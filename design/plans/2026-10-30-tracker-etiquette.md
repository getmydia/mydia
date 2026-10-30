# Tracker etiquette Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tracker credentials embedded in download URLs never reach the
browser, the page or the logs, and an operator can cap grabs and queries per
tracker per rolling 24 hours.

**Architecture:** Search rows carry an opaque result reference
(`MydiaWeb.Live.SearchResultRef`) that the LiveView resolves against the
results it already holds. The one rendered URL goes through
`Client.Helpers.redact_url/1`. Grab events carry the download id, and the
manual search dialog maps ids back to rows from its own assigns. A static test
walks `lib/` and fails on a `Logger` call or HEEx interpolation of
`download_url` that skips `redact_url/1`. `tracker_rules` gains `grab_limit` and
`query_limit`; `Mydia.Indexers.TrackerLimits` counts grabs from `downloads` and
queries in `Indexers.RateLimiter` (a new rolling-window API), skips capped
indexers in `search_all/2`, drops capped trackers' results for background
searches, and gives the manual search dialog a per-row reason.

**Tech Stack:** Elixir, Ecto (SQLite and PostgreSQL), ETS, Phoenix LiveView,
daisyUI.

Spec: `design/specs/2026-10-30-private-trackers-roadmap-design.md`, "Spec 4".
Builds on Spec 0 (`design/plans/2026-10-30-tracker-terms.md`).

## Global Constraints

- `indexers.ex`, `search_live/index.ex`, `media_live/show/modals.ex`,
  `admin_indexers_live/index.ex`, `config/schema.ex`, `config/loader.ex` and
  the search jobs are at or over the 800-line ratchet cap: they may only
  shrink. New logic goes in new modules; edits there are line-neutral.
- Migration columns are `:text`/numeric, never `:string`; real timestamp.
- Every user-visible string goes through gettext; no em dashes; fictional
  tracker names only.
- Limits are optional (nil means no cap) and must be non-negative integers.
- Spec 1 edits `modals.ex` and Spec 2 adds badges to
  `manual_search_components.ex`; keep edits there small and localized.

## Decisions and deviations found while planning

- No GraphQL type exposes a download URL (`downloadUrl` in `player/` is the
  offline-download feature, unrelated). History, the blocklist page and the
  activity feed render no download URL either: events store the download id,
  and the blocklist already redacts its `guid`. The only rendered URL is the
  download details modal. The static test keeps it that way.
- The query cap counts searches Mydia sends to an indexer whose name matches a
  rule's tracker: built-in Cardigann definitions and per-tracker Jackett or
  Torznab feeds. A Prowlarr or Jackett aggregate connection fans one query out
  to many trackers Mydia cannot see, so trackers behind it rely on Prowlarr's
  own query limits (the spec already calls the caps optional for that reason).
- The query count lives in ETS, like the per-minute limiter, so it resets on
  restart. The grab count reads `downloads` and survives restarts.
- At a grab cap, manual search shows the reason on the row and still lets the
  user grab: a person choosing one release is not the runaway loop the cap
  protects against. Background searches drop the tracker's results.
- Grabbing from the media page manual search now resolves the full
  `SearchResult` server-side instead of rebuilding one from `phx-value-*`
  fields, so manual grabs also keep the result's protocol, guid and tracker
  terms (frozen by Spec 0).

## File structure

| File | Responsibility |
| --- | --- |
| `test/mydia/no_raw_download_url_test.exs` (new) | Static guard over `lib/` |
| `lib/mydia_web/live/search_result_ref.ex` (new) | `ref/1`, `find/2` |
| `lib/mydia_web/live/media_live/show/manual_search_components.ex` | Rows send `phx-value-ref`; limit reason badge |
| `lib/mydia_web/live/media_live/show/search_events.ex` | Resolve ref; map download ids to rows |
| `lib/mydia_web/live/search_live/index.ex`, `index.html.heex` | Ref instead of URL |
| `lib/mydia_web/live/media_live/show/modals.ex` | Redact the source URL |
| `lib/mydia/downloads/grabber.ex` | Events carry `download_id` only |
| `lib/mydia/config/schema/tracker_rule.ex`, `settings/tracker_rule_config.ex`, `settings/runtime_config.ex`, `config/env/tracker_rules_env.ex`, migration | `grab_limit`, `query_limit` |
| `lib/mydia_web/live/admin_indexers_live/tracker_terms_components.ex` | Two modal inputs, summary |
| `lib/mydia/indexers/rate_limiter.ex` | `check_window/3`, `record_window/2` (rolling window, own cleanup) |
| `lib/mydia/indexers/tracker_limits.ex` (new) | Caps: guard query, grab counts, reasons, drop capped results |
| `lib/mydia/indexers.ex` | Two hook lines, net zero |
| `lib/mydia/indexers/search_result.ex` | `limit_reason` display field |
| docs: `lib/mydia/indexers/README.md`, `docs/using/reference/environment-variables.md`, `config/config.example.yml` | Document |

### Task 1: Static guard, redaction, id-only events

**Files:** `test/mydia/no_raw_download_url_test.exs`, `modals.ex`,
`grabber.ex`, `search_events.ex`, `test/mydia/downloads/grabber_test.exs`,
`test/mydia_web/live/media_live/manual_search_streaming_test.exs`.

**Produces:** grab events `{:grab_completed, %{download_id: id}}`,
`{:grab_failed, %{download_id: id, reason: msg}}`,
`{:grab_duplicate, %{download_id: id, reason: atom}}`; SearchEvents assign
`:grab_rows` (download id to the row's `download_url`, server-side only).

- [ ] Write the static test: parse every `lib/**/*.ex` with
  `Code.string_to_quoted/2`; walk `Logger.<level>(...)` calls and flag any
  `download_url` variable, field access or keyword/map value not inside a
  `redact_url(...)` call. For `~H` sigils and `.heex` files, take each `{...}`
  and `<%= ... %>` expression (skipping `if`/`for`/`case`/`cond`/`unless` block
  heads) and flag one that mentions `download_url` without `redact_url(`.
  Include self-checks that the scanner flags a planted bad snippet and passes
  a redacted one. Expect it to fail on `modals.ex` and the `phx-value-*`
  attributes (the latter are fixed in Task 2; Task 1 lands with them
  temporarily listed in a `@pending_task_2` allowlist that Task 2 deletes).
- [ ] Fix `modals.ex` to render `redact_url(@download_details.download_url)`.
- [ ] Grabber broadcasts by id. Update the grabber test to assert payloads
  have no `download_url` key.
- [ ] SearchEvents: `download_from_search` records `download.id => url` in
  `:grab_rows`; the three handlers look the row up by id (unknown id: no-op).
  Update the streaming tests to send id payloads.
- [ ] Commit `fix(downloads): keep download URLs out of events and the page`.

### Task 2: Result references in search rows

**Files:** `search_result_ref.ex`, `manual_search_components.ex`,
`search_events.ex`, `search_live/index.ex`, `search_live/index.html.heex`;
tests `test/mydia_web/live/search_result_ref_test.exs`, existing manual search
and SearchLive tests.

**Produces:**
- `SearchResultRef.ref(%{download_url: _, indexer: _}) :: String.t()` (16
  url-safe base64 chars of a SHA-256 over url and indexer)
- `SearchResultRef.find(map | list, ref) :: result | nil`

- [ ] Test `ref/1` is stable, differs per indexer, does not contain the URL;
  `find/2` over a list and a map's values.
- [ ] LiveView tests: a manual search and a SearchLive search whose results
  carry `?passkey=` and `torrent_pass=` render HTML containing neither; a grab
  via the ref creates a `Download` with the full URL and the result's guid.
- [ ] Media page rows send `phx-value-ref`; `download_from_search` resolves the
  result from `:indexer_raw_results` (unknown ref: flash an error) and applies
  the season-pack context onto the result's metadata.
- [ ] SearchLive rows send `phx-value-ref`; `show_detail` and
  `show_download_modal` resolve via `find/2` over `:search_results_map`.
  Line-neutral in `index.ex`.
- [ ] Delete the static test's allowlist.
- [ ] Commit `fix(search): search rows reference results instead of carrying URLs`.

### Task 3: grab_limit and query_limit on tracker rules

**Files:** `tracker_rule.ex`, `tracker_rule_config.ex`, `runtime_config.ex`,
`tracker_rules_env.ex`, new migration
`<ts>_add_limits_to_tracker_rule_configs.exs`, `tracker_terms_components.ex`;
tests `test/mydia/config/tracker_rules_config_test.exs`,
`test/mydia_web/live/admin_indexers_live/tracker_terms_test.exs`.

- [ ] Tests: env `TRACKER_RULE_1_GRAB_LIMIT=5`, `_QUERY_LIMIT=50` load; a
  negative limit is a config error; DB row round-trips both; the modal saves
  them and the row summary shows "5 grabs/day · 50 queries/day".
- [ ] Implement (`validate_number(..., greater_than_or_equal_to: 0)`; 0 means
  no grabs/queries at all, nil no cap).
- [ ] Commit `feat(indexers): daily grab and query limits on tracker rules`.

### Task 4: Enforce the caps

**Files:** `rate_limiter.ex`, `tracker_limits.ex`, `indexers.ex`,
`search_result.ex`, `search_helpers.ex`, `search_events.ex`,
`manual_search_components.ex`; tests
`test/mydia/indexers/tracker_limits_test.exs`,
`test/mydia/indexers/rate_limiter_window_test.exs`, a manual search test.

**Produces:**
- `RateLimiter.check_window(key, limit, window_ms) :: {:ok, count} | {:error, :limited, count}`,
  `RateLimiter.record_window(key, window_ms) :: :ok`
- `TrackerLimits.guard_query(config, (-> result)) :: result | {:error, Adapter.Error.t()}`
- `TrackerLimits.grab_counts(rules) :: %{tracker_key => count}`
- `TrackerLimits.capped_reasons(rules \\ TrackerRules.list_rules()) :: %{tracker_key => String.t()}`
- `TrackerLimits.drop_capped(results, opts) :: results` (only with
  `skip_capped_trackers: true`, set by `Indexers.background_search_opts/0`)
- `SearchResult.limit_reason :: String.t() | nil`

- [ ] Tests: window counting and expiry; `guard_query` runs the search under
  the cap, records it on success, and at the cap returns a rate-limited error
  "daily query limit reached (2/2)" without running it; grab counts by
  case-insensitive tracker over the last 24h only; `search_all` with
  `background_search_opts` drops a capped tracker's results while a manual
  `search_all` keeps them; manual search row shows
  "daily grab limit reached (1/1)".
- [ ] Implement; hook `search_with_metrics` and `search_all` in `indexers.ex`
  line-neutrally.
- [ ] Commit `feat(indexers): enforce daily tracker grab and query limits`.

### Task 5: Docs

- [ ] `lib/mydia/indexers/README.md` "Tracker limits" and "Download URLs"
  notes; env var reference; `config.example.yml`; roadmap spec "As built".
- [ ] `mix gettext.extract --check-up-to-date`, ratchet, credo, commit
  `docs(indexers): tracker limits and download URL handling`.
