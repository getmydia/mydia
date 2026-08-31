# Test suite: traps and conventions

Things about this suite that have cost real time. Most of them share a shape:
the test passes, and passing is the bug.

## Running the suite

Every `./dev` invocation pays roughly 2 minutes of devenv shell startup before
any work begins, regardless of workload. Measured 2026-07-30:
`./dev mix test test/mydia/settings_test.exs` took 2m8s wall clock for 1.5s of
actual test time. The cost is per invocation, so batch test paths into one call
(`./dev mix test a.exs b.exs c.exs`) rather than three calls. `run_precommit()`
in `./dev` exists to amortize this, running all its steps inside a single
`devenv shell --`.

Run these in the foreground with a long timeout. A full
`devenv shell -- mix precommit` takes roughly 9 minutes, past the usual 600s
tooling ceiling, but backgrounding it and polling is how work gets lost: an agent
that does so tends to stop with "still in progress" having made its edits, run no
tests, and committed nothing. Two minutes of silence is normal here, not a hang.

`./dev mix precommit` calls `run_precommit()` in the `./dev` script, which is a
reimplementation of the `precommit` alias in `mix.exs` rather than a wrapper
around it. The script says so itself. It currently runs seven steps (dependencies,
compile with `--warnings-as-errors`, unused deps, format, `credo --strict`,
database, tests), but the sync is manual and one-directional: a step added to the
`mix.exs` alias is silently absent from `./dev mix precommit` until someone edits
`run_precommit()` by hand. Add it to both in the same commit, or CI will catch
what local runs miss.

`mix test` silently drops a nonexistent path argument as long as at least one
other argument resolves, erroring only when all of them fail
(`Mix.Tasks.Test.extract_files/2`). A typo'd path therefore produces a
confidently green run over a smaller suite. During PR #266 an implementer
reported three green runs of "99 tests, 0 failures" across three named suites,
but two of its paths were directories that do not exist
(`test/mydia_web/live/add_media_live/` and
`test/mydia_web/live/admin_quality_profiles_live/` are flat sibling files), so
all three runs executed only `test/mydia_web/live/media_live/`. `ls` every path
before passing it, and sanity-check the reported count.

Do not run two `./dev mix test` or `./dev mix precommit` invocations concurrently
in the same worktree. They share one SQLite test database and produce
`(Exqlite.Error) Database busy` failures in files unrelated to the change under
test. Seen 2026-08-23, where a full precommit alongside a subagent's test run
produced a single failure in `Mydia.Settings.CustomFormatsTest` while the change
was entirely in the subtitles domain. Separate worktrees each get their own
database and can run concurrently.

### Against PostgreSQL

This exact shape is required, and the obvious
`devenv shell -- bash -c 'export DATABASE_TYPE=postgres && mix test'` silently
does not work:

```bash
./dev down
DATABASE_TYPE=postgres ./dev up -d
DATABASE_TYPE=postgres devenv shell -- bash -c \
  'export MIX_ENV=test && mix compile --force && mix ecto.create && mix ecto.migrate && mix test <paths>'
./dev down
./dev up -d   # return the stack to SQLite
```

`devenv.nix` decides whether the Postgres service exists at all by reading
`DATABASE_TYPE` at Nix evaluation time, so exporting it inside the `bash -c`
payload is too late. The Ecto adapter is chosen via `Application.compile_env` at
compile time, so switching adapters without `mix compile --force` raises a
compile-env mismatch. And a bare `devenv shell` starts Postgres only transiently
to satisfy the `mydia:ecto` first-run task, then tears it down before the payload
runs, so the persistent process-compose supervisor must be up first.

Three things that will waste a cycle. `./dev up -d` sometimes reports a
`postgres failed` status from a process-compose health-check race while the
service is actually ready, so check `./dev ps` first. `./dev down` exits 1 when
nothing is running, so `./dev down && ...` short-circuits and the stack never
comes up; keep them as separate commands. And a full `/run/user/1000` tmpfs
blocks the Postgres start while presenting as a Postgres or devenv fault, so
check `df -h /run/user/1000` before debugging the database.

### Feature tests are excluded from every normal run

`test/test_helper.exs` runs
`ExUnit.start(exclude: [:external, :feature, :requires_relay])`, so `./dev test`
on either adapter never executes a single `:feature` test. The
`Test / E2E Browser` CI job is the only thing that runs them. "Full suite green
on SQLite and PostgreSQL" reads like total coverage and is not.

That bit PR #611 on 2026-08-29: the relay guard was verified with two full-suite
runs, both exiting 0 with no escape report, and `Test / E2E Browser` then went
red because `DashboardLive.Index` fires trending lookups on connected mount
(`dashboard_live/index.ex:222` and `:244`), those escaped, and the guard's
`System.at_exit` forced exit 1. The blind spot was exactly the width of the
`:feature` tag. Fixed by warming both trending caches in
`test/support/feature_case.ex`'s setup.

Two traps sit between a fresh worktree and a working Wallaby run, and both exit 0
while doing nothing useful.

A path argument drops the tag filter. `scripts/run-feature-tests.sh` around lines
257-261 runs `mix test "${test_args[@]}"` with no `--only feature` when arguments
are present, so `./dev feature-test <path>` runs with `:feature` still excluded:
0 tests, exit 0, printed as `All tests have been excluded.` Pass the tag
yourself:

```bash
./dev feature-test test/mydia_web/features/foo_test.exs --only feature
```

Verify every run by looking for `Including tags: [:feature]` and a non-zero test
count.

A fresh worktree also has no `priv/static/assets`, since `deps/`, `_build/` and
the asset build are all per-worktree. Without it there is no `app.js`, the
LiveView socket never connects, and every feature test dies at
`wait_for_liveview/1` with
`Expected to find 1 visible element that matched the css '[data-phx-main].phx-connected'`.
There is also no `app.css`, so any geometry assertion is measuring an unstyled
page. Fix once per worktree with
`devenv shell -- bash -c 'mix assets.setup && mix assets.build'`, and rebuild
after changing any class string, since Tailwind only emits classes it finds in
source.

Before trusting any feature-test result in a new worktree, run

```bash
./dev feature-test test/mydia_web/features/smoke_test.exs --only feature
```

and confirm 1 test, 0 failures. That single run proves the tag filter, chromedriver and the asset build
at once.

### After a rebase, a clean compile proves nothing

Rebasing onto a master that has moved a long way can produce a semantic merge
conflict that git reports as clean and `mix compile --warnings-as-errors` does
not catch, because `mix compile` compiles `lib/` and not `test/`, so stale callers
living in test files are invisible to it.

Observed 2026-08-25 on PR #565, rebasing 19 commits onto a master 61 commits
ahead. Git found exactly one textual conflict, a duplicate `alias` line, and the
tree compiled clean while being broken in 20 places on both adapters. The branch
had changed `MediaRequests.create_request/2` and
`MediaRequestHelpers.handle_request_media/3` to take a leading
`%Mydia.Accounts.Scope{}`, while master independently added a `poster_path`
feature whose new test files called those functions with the old signatures.

Run the full suite before pushing after any non-trivial rebase. When it goes red,
fix the callers, never the signature: adding a lower-arity compatibility clause
turns CI green while undoing the refactor's whole point, and for a required-scope
argument it reinstates the authorization hole the branch existed to close. Then
run the full suite again, since the files CI names may not be the whole set. On
PR #565 a fifth file, `media_request_backfill_test.exs`, had the same stale call
in a
shared fixture with six more tests behind it. Grepping the tree for every call
site of the changed functions is the cheap version of this check.

## Connected LiveView tests must be async: false

`test/support/data_case.ex` sets
`Sandbox.start_owner!(repo, shared: not tags[:async])`. SQLite forces
`async: false`, so everything runs in shared mode and every process sees the
data. PostgreSQL honours `async: true` and gives you a non-shared sandbox.

A connected LiveView runs in a separate process from the test, and under a
non-shared sandbox it cannot see rows the test inserted in its own transaction.
The list renders empty and anything gated on rows existing never appears. This
passes on SQLite and fails only on the `Test / PostgreSQL` job, where it looks
flaky but is fully deterministic.

Use `use MydiaWeb.ConnCase, async: false` for any LiveView test that mounts and
asserts on inserted data. Tests that only build a mock
`%Phoenix.LiveView.Socket{}` and call functions directly, such as
`authorization_test.exs`, never spawn a mount process and can stay async. Every
other LiveView test in the repo is already non-async for this reason.

First hit was PR #172, the downloads sort feature, with 5 failures on
`#downloads-sort` not rendering.

## Tests must not mutate global env

Never `System.put_env("METADATA_RELAY_URL", ...)`, or write any other global env
or Application config that production code reads, inside an async test. SQLite CI
runs `max_cases: 1` and hides the race. The PostgreSQL job runs
`max_cases = schedulers_online()`, so any concurrent test calling
`Mydia.Metadata.default_relay_config/0` during the mutating test's window gets
redirected to its Bypass and fails non-deterministically.

A green SQLite `Test` job alongside a red `Test / PostgreSQL` on the same commit
is the signature of a global-state leak. Seen on PR #183, where a
`refresh_metadata` test set `METADATA_RELAY_URL` globally.

Inject config explicitly instead. `Media.refresh_metadata/2`, `ProviderSwitch.*`
and `Metadata.fetch_by_id*` all accept a relay config map
(`%{type: :metadata_relay, base_url: "http://localhost:#{bypass.port}", options: %{}}`),
so pass the Bypass config straight in. If a function lacks one, add an optional
`config \\ nil` argument defaulting to `default_relay_config/0`.

## The suite refuses outbound HTTP

`Mydia.RelayGuard` (`test/support/relay_guard.ex`) is a Req adapter installed
globally from `test/test_helper.exs` with
`Req.default_options(adapter: Mydia.RelayGuard)`. It reaches every `Req.new/1`
call site with no `lib/` changes, because `Req.new/2` merges `default_options()`
before splitting `:adapter` into the request struct. Shipped in PR #611, closing
issue #530.

What gets through: loopback (`localhost`, `127.0.0.1`, `::1`), RFC 2606 reserved
TLDs (`.invalid`, `.test`, `.example`), and RFC 5737 documentation ranges
(192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24). Everything else is recorded in
`Mydia.RelayGuard.Escapes` and refused. `example.com`, `.net` and `.org` are
deliberately not allowed; they are reserved names that resolve to real servers.

A test that reaches the network now fails the whole run rather than flaking. An
end-of-suite report names each escaped URL, an app-only stacktrace, and the
`Mydia.MetadataCacheHelpers` call that would have prevented it. Fix by warming
the cache, pointing at Bypass, or using a reserved host as a placeholder. Do not
widen the allowlist to make a test pass, since a container hostname like
`flaresolverr:8191` can resolve to a real service.

Two things that are easy to get wrong:

- The refusal is a plain exception and deliberately not a `Req.TransportError`.
  `Metadata.Provider.HTTP.new_request/1` sets `retry: :transient, max_retries: 3`
  and Req retries transport errors, which would burn about 6.8s of backoff and
  blow the 5s `render_async` budget.
- `Req.default_options/1` replaces the global option list rather than merging
  it, so a second call anywhere in test support would silently disarm the guard
  for the rest of the run with no error. Nothing does this today.

`--include external` or `--include requires_relay` disarms the guard for the
whole run by design, and prints a line saying so.

A test can also pass because of network latency. `RailPickerHostTest` asserted a
transient "Adding..." spinner right after a click, and it was reliable only
because the add made a real relay round trip. Stubbing that with Bypass made it
race and fail in CI.

## Movie detail pages escape to the live relay

A movie `MediaItem` whose `metadata` carries no `collection_id` sends
`Franchises.resolve_collection_id/2` (`lib/mydia/media/franchises.ex`) into
`Metadata.fetch_by_id_cached/3`. That key is
`fetch_by_id:<provider>:<id>:<media_type>:<lang>:<append>:<season_order>` and is
separate from the `recommendations:...` and `collection:...` keys, so warming
recommendations does not prevent the movie-details lookup.

Compounding it, `System.unique_integer([:positive])` hands out small positive
integers that collide with real TMDB movie ids and with the roughly 168
hardcoded `tmdb_id` literals elsewhere in the suite (101, 123, 603 and so on),
which all share one ETS-backed metadata cache. The symptom is a
`franchise-section` appearing on a movie whose fixture defined no collection, so
the page order changes. The test passes in isolation and fails in the full file.

Discovered on PR #518 while adding `section_order_test.exs`. A pre-existing test
had the same exposure and was passing by luck.

In any test that renders a movie detail page, warm
`fetch_by_id_cached(config, id, media_type: :movie)` through Bypass with a
`"belongs_to_collection" => nil` payload, and offset generated provider ids past
a nine-digit floor (`900_000_000 + System.unique_integer([:positive])`) so cache
keys belong to that file alone. Real TMDB ids are seven digits. Do not use
negative ids, since `Relay.fetch_by_id/3` runs them through
`ProviderIDRegistry.validate_id_type/3`. The worked pattern is
`warm_movie_details_cache/1` in
`test/mydia_web/live/media_live/show/section_order_test.exs`.

Since PR #611 this can no longer happen silently, because RelayGuard fails the
run with a report naming the URL and the helper to call. The warming advice is
still exactly how you fix it. Shared helpers live in
`test/support/metadata_cache_helpers.ex` and now cover trending, genre and movie
search too.

## Subtitle default_config bypasses DB-inserted stubs

`Mydia.Subtitles.Downloader.default_config/1` resolves from
`ProviderRegistry.default_configs/0`, a static compile-time list, and never from
the database. When `download_from_result/2` falls back to
`[provider_type: :relay]` because the result's `provider_id` does not resolve,
the adapter chosen is the real `Mydia.Subtitles.Provider.Relay`, and the test
makes a live HTTP call to relay.mydia.dev.

`SubtitleProviderFixtures.stub_registry_adapter/2` cannot prevent this. It
inserts a database row, which outranks the registry entry for search via
`ServiceConfigs.list_subtitle_provider_configs/1`, but `default_config/1` never
consults that function. This cost real time on PR #532, where a planned test for
the provider-type fallback looked correctly stubbed and escaped to the network.

To test any path reaching `default_config/1`, stub the HTTP boundary with Bypass
following `test/mydia/subtitles/provider/relay_test.exs`. That means setting
`:subtitle_relay_url`, which is global application state, so the file must be
`async: false` with a comment saying why. Every other file that mutates that key
already is. A DB-backed stub adapter only works when the code path resolves
through `list_subtitle_provider_configs/1`, meaning when `provider_id` resolves.

## Log metadata never executes under mix test

`config/test.exs:60` sets `config :logger, level: :warning`. `Logger.info/2` and
`Logger.debug/2` are macros that do not evaluate their arguments at all when the
configured level is above theirs, so any expression living inside log metadata
never runs under `mix test`.

A crash inside `Logger.info` metadata is therefore invisible to the entire test
suite while crashing every production install, since production runs at `:info`.
That is how the `KeyError key :changes` regression at
`lib/mydia/jobs/library_scanner.ex:181` reached 0.13.1 users. The buggy
expression was `length(result.changes.new_files)` inside a `Logger.info` call,
and a correct end-to-end regression test still passed against the broken code.

To test code that lives in log metadata, raise the level for the block. The file
must be `async: false`, since ExUnit runs sync modules serially after all async
ones, so the global mutation cannot disturb another module.

```elixir
setup do
  original_level = Logger.level()
  Logger.configure(level: :info)
  on_exit(fn -> Logger.configure(level: original_level) end)
  :ok
end
```

`Logger.level/0` and `Logger.configure/1` are plain functions, so no
`require Logger` is needed. There is no `compile_time_purge_matching` in
`config/`, so a runtime level change is enough.
`ExUnit.CaptureLog.capture_log/2`'s `:level` option does not substitute: it
filters what a handler captures, while the macro's skip decision happens earlier
against the primary level.

Treat non-trivial expressions inside log metadata as untested by default. Prefer
computing a value into a variable before logging it.

## Oban is disabled in test

`config/test.exs` sets `testing: :manual, engine: false, queues: false,
plugins: false` on Oban, to keep Oban's pool off the SQL Sandbox, and
`lib/mydia/application.ex` skips starting Oban's supervisor in test.

Two consequences worth knowing before you spend a cycle on them:

1. No test can read the production crontab, because
   `Application.get_env(:mydia, Oban)[:plugins]` is `false`. A guard test of the
   form "every cron worker is enqueued with its declared args" is not
   achievable. Test the lookup as a pure function over an explicit crontab
   fixture and say so in a comment, rather than mirroring `config/config.exs`
   entries that silently drift.
2. `testing: :manual` and `:inline` force `plugins: []` inside Oban's own config
   (`deps/oban/lib/oban/config.ex`), so starting Oban with `:manual` gives you no
   Cron plugin. To exercise a crontab, start it with `testing: :disabled` plus
   `queues: []` and a fixture crontab whose expressions cannot fire, such as
   `"0 0 1 1 *"`.

`worker.new(args)` is pure and needs no running Oban, so args-threading can be
asserted on the returned `Ecto.Changeset`. Only `Oban.insert/1` needs a live
instance.

## Oban.insert_all bypasses worker uniqueness

`Oban.insert_all/1` does not honour a worker's `unique: [period: N, fields: [...]]`
here. Verified against vendored Oban 2.20.1:
`Oban.Engines.Basic.insert_all_jobs/3` is a bare
`Repo.insert_all(..., on_conflict: :nothing)` and never calls `fetch_unique` or
`insert_unique`, and `Oban.Engines.Lite` delegates `insert_all_jobs` straight to
Basic while implementing its own singular `insert_job` with `fetch_unique`. Bulk
unique jobs are an Oban Pro feature, and `config/config.exs` configures Basic on
PostgreSQL and Lite on SQLite.

The natural one-round-trip optimisation silently drops idempotency with nothing
failing loudly. It cost a review round on PR #244 before being caught.

When jobs must be deduped, insert one at a time with `Oban.insert/1` and accept N
round trips. A deduped insert returns `{:ok, %Oban.Job{conflict?: true}}`, so
check that flag if you report a count to the user. Because `config/test.exs` sets
`engine: false`, `Oban.insert/1` raises in tests and every call site needs the
repo's `rescue RuntimeError -> Repo.insert(changeset)` fallback, as in
`Mydia.Downloads.Queue.insert_job/1`. No test can exercise real Oban uniqueness,
so verify it from Oban's source and do not write a dedup test that would only
exercise the fallback.

## Bypass JSON stubs need an explicit content-type

A Bypass stub returning JSON with a bare `Plug.Conn.resp(conn, 200, ~s({...}))`
sets no content-type, so Req's `decode_body` step does not fire and the handler
receives a raw binary. Production code doing `body["Items"]` then dies with
`FunctionClauseError` on `Access.get/3`, which reads like a bug in the code under
test.

```elixir
conn
|> Plug.Conn.put_resp_content_type("application/json")
|> Plug.Conn.resp(200, Jason.encode!(payload))
```

Req decodes from a resolved content-type header or a URL extension, and a Bypass
stub has neither by default. Real services send the header. Precedent lives in
`test/mydia/watch_sync/providers/plex_position_test.exs` and
`test/mydia/media_server/plex/home_test.exs`. This bit two separate tasks on the
Jellyfin watched-sync branch on 2026-08-12, each time looking like a production
defect first.

## A TVDB season stub needs episode translations too

A `/tvdb/seasons/{id}/extended` Bypass stub returning a non-empty `"episodes"`
list makes `Relay.enrich_tvdb_episodes_with_translations/2` fetch
`/tvdb/episodes/{episode_id}/extended?meta=translations` once per episode,
because the season payload carries no per-episode translations. Unstubbed, each
call 500s, Req retries three times with backoff, and Bypass then fails unrelated
tests in the same file with "Bypass got an HTTP request but wasn't expecting
one".

```elixir
Bypass.stub(bypass, "GET", "/tvdb/episodes/:episode_id/extended", fn conn ->
  json(conn, %{"data" => %{"translations" => %{}}})
end)
```

A stub with `"episodes" => []` needs none of this, so an existing harness looks
fine until someone adds an episode. That happened to
`test/mydia/media/refresh_season_order_test.exs`, where adding one episode to the
shared `ordering_stubs/1` broke 7 of 34 tests across three files.

TVDB episode keys that actually get read: `"id"`, `"seasonNumber"`, `"number"`,
`"name"`, `"aired"`, `"absoluteNumber"` (see `EpisodeData.from_tvdb_response/2`).

## IndexerMock drops :info_url and randomises :magnet_url

`Mydia.IndexerMock.movie_result/1` and `tv_episode_result/1` build a fixed map in
`test/support/indexer_mock.ex` and forward only a small allowlist of attrs
(`:title`, `:year`, `:quality`, `:seeders`, `:tmdb_id`, `:imdb_id`, `:guid`).

`:info_url` is a no-op, and `build_search_result/1` then applies its default of
`"https://example.com"`, so tests asserting a specific info URL fail confusingly
and tests asserting "no info URL" pass against a real one. `:magnet_url` is
regenerated randomly per call, so any test needing a predictable `download_url`
(triggering `show_detail` on the search page, whose handler looks the result up
by `download_url` in `search_results_map`) never matches.

Set both on the returned map, which is what `build_search_result/1` reads:

```elixir
IndexerMock.movie_result(%{title: "The Matrix", year: 1999})
|> Map.put(:info_url, "https://tracker.example/details/42")
|> Map.put(:magnet_url, "magnet:?xt=urn:btih:" <> String.duplicate("a", 40))
```

Worked example: `test/mydia_web/live/search_live/info_link_test.exs`. The failure
mode is a passing but meaningless test; nothing warns that the attr was dropped.

## LazyHTML.filter/2 matches root nodes only

In `render_component/2` tests, `LazyHTML.filter(doc, selector)` filters only the
fragment's root nodes, so a selector for a descendant returns `[]` no matter what
the markup contains. `LazyHTML.query/2` searches descendants. Confirmed against
`deps/lazy_html/lib/lazy_html.ex:301-303`, whose own doc says it "Filters
`lazy_html` root nodes", with a doctest showing a nested `<span>` excluded.

This bites hardest in component tests, where the rendered fragment usually has a
single wrapper as its only root. Asserting on `trending_card/1`'s poster via
`filter(doc, "figure")` returns `[]` regardless of implementation state, which
either raises `MatchError` on a `[class] =` destructure or makes an `Enum.all?`
assertion vacuously true. Use `filter/2` for the wrapper you rendered and
`query/2` for anything inside it.

Neither returns a list. Both are `@spec (t(), String.t()) :: t()`, so they hand
back a `%LazyHTML{}`, and `[el] = LazyHTML.query(doc, sel)` is a `MatchError` no
matter how many nodes matched. `length/1` raises. The codebase idiom is plain
assignment plus `Enum.count/1`, `Enum.empty?/1` or `Enum.to_list/1`; see
`indexer_components_test.exs` and `media_rail_component_test.exs`.
`LazyHTML.attribute/2` is the exception, genuinely returning
`list(String.t())`, so `[class] = LazyHTML.attribute(el, "class")` is valid and
doubles as a cardinality guard.

Boolean HEEx attributes render bare: `open={true}` emits `<dialog open>`, which
parses to `[""]` rather than `["open"]`. Asserting `== []` on a boolean attribute
is vacuously true when the selector matched nothing, so pair it with a count
assertion. Confirmed a second time on 2026-08-22 against lazy_html 0.1.12.

## plex.tv has no LiveView test seam

`Mydia.MediaServer.Plex.Home` and `PlexOAuth` take the plex.tv base as a
`:plex_tv_base` option and deliberately not from application env. The comment in
`PlexLinkSeed` says env "would leak across concurrent tests".  `PlexLinkSeed`
threads it through job args. A LiveView has no equivalent channel, so any
LiveView event calling plex.tv cannot be stubbed and would make a real network
request.

For `AdminMediaServersLive`, never `render_click` a button whose handler reaches
plex.tv (`open_plex_profiles`, `start_plex_oauth`, `save_plex_profiles`). The
existing "Plex wizard auto-connect" block only asserts on modal structure.

Cover those paths in two pieces. UI states go through `render_component/2` in
`test/mydia_web/live/admin_media_servers_live/components_test.exs`, passing
loading, `{:error, msg}` and ready states as assigns. Behaviour goes through
Bypass against the context function directly, for example
`Home.apply_mapping(config, mapping, plex_tv_base: base)` in
`test/mydia/media_server/plex/home_test.exs`. LiveView tests can still assert a
button exists with the right `phx-click` and `phx-value-id`, which pins the
wiring without firing it.

## The parser gates cannot test target-bound behaviour

Neither `test/mydia/library/release_parser/parity_test.exs` (245 tests, the hard
gate) nor `corpus_test.exs` (2,305 cases, about 76.4% against a 70% floor) passes
a `%TargetContext{}` to `ReleaseParser.parse/2`. Both call the unbound form.

Any parser behaviour gated on the target, whether category, known seasons or
absolute range, is structurally invisible to both suites. They stay green through
a completely broken feature and their numbers do not move in either direction.

Verified 2026-08-17 while building anime absolute-episode matching. Six fix
rounds each held parity at 245/0 and the corpus bit-identical at 1761/2305, while
every round shipped a defect a reviewer then found by hand-constructing filenames
and running the parser directly. The feature was ultimately reverted.

When adding target-gated parser behaviour, a hand-written case file is the entire
safety net. Treat it as the specification and grow it adversarially, probing the
space the change newly admits. Never read a green parity run or an unchanged
corpus rate as evidence that such a feature works.

## The promotion concurrency tests flake under load

Two tests use real, unsandboxed database connections
(`Ecto.Adapters.SQL.Sandbox.unboxed_run`) plus a hard `Task.await(task, 2_000)`
to prove that competing promotions serialize:

- `Mydia.Library.CandidatePromotionTest`, "separate database connections
  serialize competing promotions at ownership"
- `Mydia.Library.FileIngestTest`, "a losing promotion failure cannot resurrect
  the winner's deleted candidate" (`file_ingest_test.exs` around line 245)

The 2000ms is a timeout, not a sleep. Unloaded, both files together run 21 tests
in 0.4s. Under contention they blow the deadline and fail as `** (EXIT) time out`
on `Task.await/2`, which reads like a serialization regression.

**That is not the only signature.** The same test also fails as

```text
Assertion failed, no matching message after 1000ms
code: assert_receive {:ownership_attempt, ^first_pid}
mailbox:
pattern: {:ownership_attempt, ^first_pid}
value:   {:ownership_attempt, #PID<0.44749.0>}
```

where the mailbox shows the *other* process reached ownership first. The test
pins `first_pid` and expects it to win, which is a scheduling assumption rather
than something the locking guarantees. Match on the test name, not on the
exception type: an `assert_receive` failure here is the same flake as the
`Task.await` timeout, not a distinct defect. Observed on CI 2026-08-31, twice in
a row on one commit, then green on the third re-run with no code change.

Observed 2026-08-31: `./dev mix precommit` failed with exactly these two while
the PostgreSQL devenv stack was still up and a PostgreSQL suite overlapped the
run. Re-running both files on a quiet machine gave 21 tests / 0 failures, and a
subsequent full precommit with the stack down was clean.

These are the only tests combining real connections, cross-process task
coordination and a fixed wall-clock deadline, so they break first when something
competes for CPU or the SQLite writer lock. Before treating a failure as a real
defect, check what else was running (`pgrep -f 'mix test'`, `./dev ps`, `uptime`)
and re-run the two files alone. Do not run a PostgreSQL suite and a SQLite
precommit concurrently; bring the stack down first with
`DATABASE_TYPE=postgres ./dev down`. Note that a waiter written as
`until ! pgrep -f 'mix test'; do ...` matches its own command string and never
exits.

## media_test.exs scopes its fixture import to one describe block

`test/mydia/media_test.exs` does `import Mydia.MediaFixtures` inside its
`describe "media_items" do` block rather than at module scope. Elixir scopes an
`import` inside a `describe` to that block, so a new sibling top-level `describe`
does not inherit it and bare `media_item_fixture(...)` calls fail to compile.

Caught during self-review of the player detail-page redesign backend plan on
2026-08-05, where a first draft of new `describe "library_status_for_tmdb_ids/2"`
and `describe "list_media_items/1 :ids filter"` blocks would not have compiled.

Add an `import Mydia.MediaFixtures` line as the first line of each new block,
matching the file's existing per-block convention.
