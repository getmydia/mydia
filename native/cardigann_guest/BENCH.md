# Cardigann wasm engine: gating benchmark

Prowlarr's Cardigann engine compiled to wasm (the "wasm" engine) against Mydia's
Elixir engine, judged against a real Prowlarr v2.6.5.5623 in Docker, over every
public definition at Prowlarr/Indexers `d34bddc56cfd6a55f75a9f69dcc2df9eb591662c`
(81 definitions, 162 queries; 498 definitions left out because they need
credentials). Single-session run, `--concurrency 1`, fresh Prowlarr data directory.

## Gate result: FAIL

| Gate item | Required | Measured | Pass |
|---|---|---|---|
| M1 fidelity | wasm > elixir | wasm 44/44 (100.0%), elixir 29/44 (65.9%) | PASS |
| M2 coverage | wasm >= elixir | wasm 54/81, elixir 55/81 | **FAIL** (one definition short; see below) |
| M3 regressions | 0 unexplained | 0 | PASS |
| M4 p95 overhead | <= max(2x elixir, 50 ms) | wasm 243.9 ms vs elixir 126.0 ms (limit 252.0 ms), paired n=66 | marginal PASS, within run-to-run noise (one run; an earlier run of the same code would have failed; fails if Elixir p95 is 121 ms or less) |
| M5 RSS | <= 200 MB | +955 MB (median of 3; a lower bound for a loaded server) | **FAIL** |
| M5 cold start | <= 5 s | 3.8 s (component compile only, not boot to available; runs in the background at boot) | PASS |
| M5 image size | <= 60 MB | +75.1 MB (71.6 MiB) | **FAIL** |

Items 1 to 3 are not negotiable and item 2 failed, so the gate fails and the branch
stays unmerged. M5 fails twice on its own.

### Reading the failures

**M2 (54 vs 55).** Three definitions give the Elixir engine results and the wasm
engine none: kickasstorrents-ws, magnetcat and torrentsome. For kickasstorrents-ws
and magnetcat the logs show the first link in `links:` answering with a Cloudflare
403 (the wasm guest logs "Cloudflare protection detected"), and the Elixir engine
logging the challenge and then parsing results from the next mirror
(`kickasstorrents.bz` for the first). For torrentsome the Elixir log shows no
Cloudflare hit: it got 0 rows for the movie query and 20 for the rss query without a
block, while the wasm guest logged a Cloudflare 403 on both queries. Why the Elixir
engine was not blocked there was not established. That the wasm engine stops at the
first mirror is inferred from the design (the adapter passes no alternative link and
the guest uses the first one), not separately demonstrated. Prowlarr has no mirror
failover (the user picks the base URL), so for the two confirmed cases this is a Mydia
feature the wasm adapter does not have rather than a fidelity defect. The wasm engine
returns more elsewhere (pandacd, where the Elixir engine gets an HTTP 400, and
anisource, whose DNS resolves only some of the time from this host), which is why the
gap is one and not three. The margin is thin, and the previous gating run, made
before the User-Agent change below, was 46 vs 51. Failover is not possible in the
adapter without extra requests or a new field across the WIT boundary: the guest
swallows a failed request as an empty page exactly as upstream does, so the adapter
cannot tell "blocked" from "no results"; it could instead retry the definition's other
links on every empty result, at the cost of an extra round trip each time.

**M4 (marginal pass, 8 ms, within run-to-run noise).** The wasm p50 is 76 ms against 27 ms and the p95 244 ms
against 126 ms. A fresh instance per call costs about 31 ms with no network
involved (measured below); the rest is definition parsing and session reads. The
Elixir p95 is not stable between runs: the non-gating `--concurrency 1` runs made
earlier the same day measured Elixir p95 values of 69 ms (wasm 175 ms, which would
FAIL) and 126 ms. With Elixir at 121 ms or less the wasm engine fails this item.
This is one run; treat M4 as unstable, not as a pass with headroom.

**M5 RSS (+955 MB).** After the component is compiled the BEAM holds about
955 MB more resident memory, and it does not change once the pool is warm
(20 sequential searches add nothing measurable on top). The Elixir engine adds 12 MB
after 20 searches. `smaps` of the BEAM process shows about 1.14 GB of anonymous
memory, mostly in mappings of roughly 64 MB that look like malloc arenas, and an
executable mapping of only about 64 MB. The cause is undiagnosed: it has not been
shown to be compiled code, module data or allocator memory retained from the
compile, and no tuning was tried. The figure is a lower bound for a loaded server:
the 20 searches were sequential (one instance at a time) against a tiny fixture, in
a script process without the rest of the application.

**M5 image (+75.1 MB).** The artifact is 74.9 MB and is stored once in the image
(`priv/cardigann/cardigann-<hash>.wasm`). It would need to be under 60 MB.

## M5 and M6 measurements

| Item | Gate | Result |
|---|---|---|
| M5 steady-state BEAM RSS delta, pool warm | <= 200 MB | **+955.0 MB** (runs: 955.0, 953.0, 964.2; baseline about 226 MB, 1,180 to 1,192 MB after compile, unchanged after 20 searches). Elixir engine: +12.2 MB (runs: 13.2, 12.2, 10.6) |
| M5 cold start (component compile at boot) | <= 5 s | **3.8 s**, compile only, not boot to available (runs: 3,857, 3,826, 3,792 ms; the first dev boot logged 4,120 ms). The compile runs in the engine's `handle_continue`, so it does not delay the rest of boot: it delays the engine becoming available |
| M5 Docker image size delta | <= 60 MB | **+75,116,476 B (75.1 MB, 71.6 MiB)**: `mydia:wasm` 810,719,991 B vs `mydia:master` 735,603,515 B |
| M6 Elixir lines deleted at cutover vs C# shim lines added | report | Task 12 deletes up to **6,338** lines of `lib/` (`cardigann_parser`, `_template`, `_filters`, `_result_parser`, `_compat`, `_overrides`, `cardigann/{features,template_context,json_path}`, `cardigann_search_engine`, `cardigann_auth`, `mix/tasks/mydia.cardigann_compat`; the figure counts the parts of `cardigann_search_engine` and `cardigann_auth` that Task 12 keeps, so it is an upper bound) plus their tests and fixtures. The guest adds **2,422** lines of C# (`shim/*.cs` and `exports/*.cs`; the vendored Prowlarr sources are excluded) |

Methods.

- **RSS.** A `mix run --no-start` script in the test environment (the wasm
  adapter's SSRF gate only admits loopback there) on a copy of the bench database:
  start the app with `cardigann_wasm_eager: false`, read `VmRSS` from
  `/proc/self/status` (baseline), force the component compile with
  `Engine.available?/0` and read again, run 20 searches through
  `Wasm.Adapter.search/3` (or `Adapter.Cardigann.search/3` for the Elixir engine)
  against a local fixture server, wait 500 ms and read again. Three fresh processes
  per engine, median reported. This is not `./dev up -d` with the whole application
  idling: the baseline is the application booted without the engine, which is the
  quantity the gate asks about (the delta the engine adds).
- **Cold start.** The engine's own log line, "compiled in N ms", and the time
  `Engine.available?/0` blocks in the script above.
- **Image size.** `docker build` of clean detached checkouts of this branch (HEAD
  `3fe2dd49c`, before the User-Agent change, which does not move the size) and of
  `origin/master` (`272ef9447`), then `docker image inspect -f '{{.Size}}'`. The
  branch checkout had the locally built `cardigann.wasm` copied into
  `priv/cardigann/` under its hashed name, with the two `.dockerignore` lines that
  exclude `priv/cardigann/*.wasm` removed in that scratch checkout, so the size
  includes the engine as a published release would ship it (the asset is not
  published). The image build also needed a fix to `mix mydia.cardigann_guest`
  (committed), which crashed on `config/runtime.exs` in a prod image build.
- **Per-call overhead of the engine.** Without a network, a `capabilities` call
  takes a median 32.7 ms and a one-request `search` 31.0 ms on an idle machine:
  that is the cost of a fresh sandboxed instance per call.

## Memory spike

The M5 RSS cause (undiagnosed above) is transient Cranelift compile memory that
glibc malloc keeps: the component compile peaks at about 1.1 GB and `malloc_trim(0)`
afterwards returns about 880 MB of it. Full numbers and method:
`.superpowers/sdd/2026-10-11-cardigann-wasm-engine/memory-spike-report.md`.

| Variant (BEAM, `m5.exs`, 3 runs, 20 searches) | Delta MB, runs | Median |
| --- | --- | --- |
| `Component.new`, no trim (the gating setup, re-measured) | 954.4, 951.0, 964.7 | 954.4 |
| `Component.new` + `malloc_trim(0)` | 180.0, 183.1, 180.4 | 180.4 |
| precompiled `.cwasm` via `Component::deserialize_file` + trim | 114.0, 112.0, 113.9 | 113.9 |

Standalone wasmtime 47.0.2, a fresh process loading the `.cwasm`: 21.9 MB RSS (4.8 MB
anonymous) after `deserialize_file` (7.8 ms), 72.4 MB after 20 search cycles, almost
all of it file-backed code pages. The `.cwasm` is 119,052,152 B against the 74,938,817 B
`.wasm`. Compile at boot takes 3.8 s on glibc and 18 s on musl (standalone binary);
loading the `.cwasm` takes 83-92 ms in the BEAM.

Wasmex 0.15.1 has no component precompile or deserialize, so this spike carries
`patches/wasmex/component-precompile-and-deserialize.patch` (`@dep_patches` in
`mix.exs`; it needs a source build of Wasmex, `WASMEX_BUILD=1`). `Engine` loads
`<artifact>.cwasm` when present (`mix mydia.cardigann_guest precompile` writes it),
falls back to compiling, then trims. The `.cwasm` is tied to the wasmtime version, the
architecture and the CPU features of the machine that built it, so it must be built
where the image runs (the Dockerfile builder stage, per architecture), never shipped as
a release asset. It adds 119 MB to the image on top of the 75 MB `.wasm` (M5 image item
is worse, not better). The production image is Alpine (musl), where `malloc_trim` does
not exist and the BEAM was not measured.

## Triage record

Every definition on which the wasm engine disagreed with Prowlarr in the
iteration runs, and what it was:

| Definitions | Symptom | Classification | Resolution |
|---|---|---|---|
| thepiratebay, anibt, onejav, freejavtorrent, pornxlab | 0 releases although the tracker answered 200 | host response mapping: a header the server repeats (`Vary` twice) made `HttpHeader.GetSingleValue` throw in the Cloudflare detection and the page was dropped | fixed in `shim/RequestMapping.cs` (`FromRaw` collapses repeated headers joined by ";", as `ToNameValueCollection` does); tests in `FixtureTests` and the Wasmex `engine_test` |
| bigfangroup, noname-club, pctorrent | 0 releases, no HTTP request made | shim/runtime: `windows-1251` and similar code pages unsupported until `CodePagesEncodingProvider` is registered (Prowlarr does it in `Bootstrap`) | fixed in `exports/Runner.cs` (static constructor); the failure only exists on wasm, so the regression test runs the real guest under Wasmex |
| torrent-pirat | `YamlDotNet ... multiline plain scalar` | the definition file starts with a byte order mark that upstream's `File.ReadAllText` drops | fixed in `shim/DefinitionService.cs`; tests in both suites |
| nyaasi, sukebeinyaasi | 0 releases for the keywordless query | host HTTP: the server sends a gzip body without being asked; the gate returns bodies undecoded | fixed in `HostHttp` (inflate gzip, drop `Content-Encoding` and `Content-Length`, capped); two Bypass tests |
| internetarchive | 0 releases on a 30 to 50 s answer | host HTTP: 30 s deadline against Prowlarr's 100 s | `HostHttp` default 100 s, adapter call default 120 s |
| megapeer, 0magnet, 52bt | Cloudflare 403 for the wasm engine and Prowlarr, 200 for a browser | host HTTP: upstream's `Prowlarr/<version> (linux)` User-Agent is refused. kickasstorrents-ws, magnetcat and torrentsome stayed blocked after this change | default User-Agent changed to the Chrome string the Elixir engine already sends (a definition's own header still wins); the one deliberate difference from upstream, recorded in `SUBSTITUTIONS.md` |
| image build | `mix mydia.cardigann_guest fetch` raised `DATABASE_PATH is missing` | task ran `app.config`, which evaluates `runtime.exs` | task now runs `loadpaths` and `loadconfig` |
| filemood (rss), limetorrents (rss), ehentai (rss) | differing release sets | tracker drift: a rate limit hit by the previous query, a live feed that moved between engines, a 4-release difference at Jaccard 0.96 | not a defect; agrees on rerun or inside the 0.95 bound |
| opensharing, torrent-pirat (generic) | slow tracker, 24 to 41 s | tracker slowness; agrees after the deadline change | none |

### Known wasm defects left open

- **Fixed after the gating run: a 5xx response ended in
  `PlatformNotSupportedException`.** Upstream retries a server error twice through
  Polly with a real delay, and the guest has no event loop, so the blocking wait
  on a pending timer task threw. `shim/HttpIndexerBase.cs` (one line changed, see
  `SUBSTITUTIONS.md`) gives the retry pipeline a `TimeProvider` whose timers
  `Thread.Sleep` and fire at once. The retries now happen as upstream's do (three
  requests, the delays of `RateLimit`), a transient 503 followed by a good answer
  returns results, and a final 5xx is swallowed into an empty page with
  `request-failed` and the status set. Native tests cover each case and a Bypass
  test runs the retries inside the wasm component.
- **Fixed after the gating run: no mirror failover** (see M2 above). The `search`
  result carries a `request-failed` flag (a transport error, an HTTP status of 400
  or more, or a Cloudflare challenge on any request of the search), and the
  adapter repeats an empty, failed search against the next entry of `links:`,
  remembering the winner as `active_link` as the Elixir engine does. A live run
  against the two confirmed cases, wasm engine and Elixir engine side by side
  (Prowlarr answered both with a Cloudflare block): kickasstorrents-ws now returns
  60 and 50 releases, the same counts as the Elixir engine; magnetcat returns none
  on either engine, because every mirror was dead or blocked that day (the Elixir
  engine ends on HTTP 410, the wasm engine logged all three mirrors failing). The
  gate table above is the pre-fix run and has not been re-run.
- **LAN trackers are refused.** The wasm host goes through `Plugins.Net.Gate`,
  which rejects private addresses; the Elixir engine does not. Not exercised by
  the public corpus.
- **Brotli.** Prowlarr decompresses `gzip` and `br`; the host handles `gzip` only
  (the `brotli` library is not a dependency).

## Concerns about the numbers

- The trackers are live and the three engines run seconds apart, not at the same
  instant. Rotating the order spreads the effect but does not remove it.
- Prowlarr's own state degrades across runs (it disables indexers that fail), so
  the gating run used a fresh data directory. 37 of 81 definitions return nothing
  on Prowlarr (Cloudflare, dead mirrors), which leaves M1 with 44 definitions.
- Two gating-style runs differ in M2 (46 vs 51 before the User-Agent change, 54 vs
  55 after) and in the Elixir p95 (126 ms against 69 ms in an earlier run). The
  Elixir engine changed under the branch twice (two `origin/master` merges), and
  its numbers are what master ships at `272ef9447`.
- M4 compares `wall - network` with the network time measured differently per
  engine (see the method below). The Elixir figure includes Req's own steps.
- The M5 RSS figure comes from a script process in the test environment, not from
  a running `./dev up` stack, and the image size from an image built without the
  published asset (the asset is not released yet).

Command: `./dev mix mydia.cardigann_bench --concurrency 1 --prowlarr-url http://127.0.0.1:19696 --out <dir>` at `7118d17f7`.

## Harness report (`mix mydia.cardigann_bench`)

| | |
|---|---|
| Mydia commit | `7118d17f71e81adc17c78d924283db961bb40e3f` (worktree-cardigann-wasm-engine) |
| Rebased on origin/master | `272ef9447130ce54bf9f7dee751e8efe2df01edf` (origin/master tip `272ef9447130ce54bf9f7dee751e8efe2df01edf`) |
| Prowlarr tag (oracle and guest) | `v2.6.5.5623` |
| Prowlarr/Indexers ref | `d34bddc56cfd6a55f75a9f69dcc2df9eb591662c` |
| Date | 2026-10-12 |
| Definitions | 81 (162 queries) |
| Left out of the corpus | 498 (498 no_credentials) |
| Upstream files substituted by shims | 12 (`native/cardigann_guest/SUBSTITUTIONS.md`) |

Harness verdicts: M1 PASS, M2 FAIL, M3 PASS, M4 PASS. M5 and M6 are measured by hand and recorded above.


### Metrics

| Metric | Elixir | Wasm | Gate | Verdict |
|---|---|---|---|---|
| M1 Fidelity (agree with Prowlarr, Jaccard >= 0.95 on every query) | 29/44 (65.9%) | 44/44 (100.0%) | wasm > Elixir | PASS |
| M2 Coverage (>= 1 release) | 55/81 | 54/81 | wasm >= Elixir | FAIL |
| M3 Regressions (Elixir agrees, wasm does not) | | 0 | zero unexplained | PASS |
| M4 Engine overhead p50 / p95 (ms), paired searches, n=66 | 27.0 / 126.0 | 76.2 / 243.9 | wasm p95 <= max(2x Elixir, 50 ms); under 10 paired searches the verdict is insufficient sample | PASS (paired n=66) |

The M1 denominator is the 44 definitions on which Prowlarr returned results; 37 definitions where Prowlarr errored or returned nothing are excluded from it and listed under Engine health.

M1 and M3 above use the spec matching rule: same normalised title and (same info hash or sizes within 1%). A release whose size is unknown on one side only does not match.

Diagnostic, lenient rule (a size known on one side only counts as a size match; not gating):

| | Elixir | Wasm |
|---|---|---|
| M1 Fidelity, lenient | 29/44 (65.9%) | 44/44 (100.0%) |
| M3 Regressions, lenient | | 0  |

No definition's agreement changes between the strict and the lenient rule, so the gate does not hinge on missing sizes.


#### How M4 was measured

Overhead is `wall - network` per search, as nearest-rank percentiles. Wall time is the elapsed time of the adapter call in the task that made it. The gating figure is over **paired searches** only: (definition, query) pairs on definitions without a `requestDelay` where Prowlarr, Elixir and wasm all returned results, so both engines are timed on the same searches (n=66; under 10 the verdict is "insufficient sample"). For the gating run use `--concurrency 1`: with parallel definitions the searches contend for CPU and the database, which inflates overhead.

- **Wasm**: network is the sum of the host `http-request` import durations, recorded by the host (`HostHttp.exchange`, after the rate-limit throttle) and reported through the `[:mydia, :cardigann, :wasm, :call]` telemetry event, which fires in the calling task. Before timing starts the run waits for the component to compile and makes one capabilities call (a warm-up, discarded), so compilation is not in the numbers. Wall includes definition parsing, session reads and writes, and the guest's own work.
- **Elixir**: network is the time inside the `Req.Finch` adapter step, measured by `Bench.NetTimer` installed as the Req `:adapter` through `Req.default_options/1` for the run (Req 0.7.4 emits no telemetry). It is attributed to the calling task and its `$callers`. Req's own request and response steps (decompression, redirects, retry sleeps) and FlareSolverr round trips made outside Req are outside it and count as overhead.
- **Prowlarr**: only wall time is available. It is not part of M4.
- **`requestDelay`**: Prowlarr and the wasm engine honour a definition's `requestDelay` (the wasm host sleeps in its rate limiter, outside the timed network call). The Elixir engine does not honour it in practice: `CardigannSearchEngine.apply_rate_limit/1` sleeps for `request_delay`, but `CardigannParser` fills that field from the YAML key `requestdelay` (lower case) and every definition spells it `requestDelay`, so the field is always nil and Elixir never sleeps. That is a behavioural difference from Prowlarr (Elixir hits trackers faster than the definition allows). Paired M4 excludes delayed definitions because the delay would count as overhead for wasm only.
- Diagnostics (not gating). Unpaired, delay-free, every ok search: Elixir 26.8 / 103.4 ms (n=90), wasm 69.0 / 206.8 ms (n=116). Every ok search including delayed definitions: Elixir 24.6 / 104.2 ms (n=113), wasm 70.1 / 1748.9 ms (n=162).


### Engine health

| Engine | ok searches | ok but empty | empty with no HTTP request made | of which empty_with_credentials | errors by kind |
|---|---|---|---|---|---|
| prowlarr | 91 | 11 | 0 | 0 | prowlarr x3, indexer x68 |
| elixir | 113 | 10 | 0 | 0 | rate_limited x1, search_failed x9, connection_failed x39 |
| wasm | 162 | 66 | 0 | 0 | none |

"Empty with no HTTP request made" counts ok-but-empty searches whose measured network time is zero: the engine answered without contacting the tracker (Elixir and wasm only), which usually means it gave up before the request.

`empty_with_credentials` counts rows (a definition and query): a private or semi-private definition with credentials configured that returned no results. Prowlarr and the wasm engine swallow a failed login during search and return an empty list, so this is a possible silent login failure and not a genuine "no results". It is not counted as an error anywhere else.

Definitions Prowlarr errored or returned nothing on (excluded from M1): 0magnet, 1337x, 52bt, acgrip, anisource, btdirectory, btetree, damagnet, dmhy, ebookbay, extratorrent-st, eztv, filemood, gamestorrents, internetarchive, kickasstorrents-to, kickasstorrents-ws, mactorrentsdownload, magnetcat, megapeer, newstudio, pornrips, postman, sexypics, showrss-yml, skidrowrepack, tokyotosho, torrent9, torrentby, torrentbyte, torrentcore, torrentproject2, torrentsome, torrenttip, uindex, vsthouse, xxxclub


### Errors

| Definition | Query | Engine | Error |
|---|---|---|---|
| 0magnet | generic | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access 16mag.net, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| 0magnet | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access 16mag.net, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| 1337x | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access 1337x.to, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| 1337x | movie | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| 1337x | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access 1337x.to, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| 1337x | rss | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| 52bt | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to connect to indexer. Unexpected response status Forbidden code from indexer request", "isWarning"  |
| 52bt | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to connect to indexer. Unexpected response status Forbidden code from indexer request", "isWarning"  |
| acgrip | tv | prowlarr | {:indexer, {:http_status, 400, [%{"detailedDescription" => "One or more errors occurred. (Connection refused)", "errorMessage" => "Unable to connect to indexer. |
| acgrip | tv | elixir | {:connection_failed, "Connection failed: :econnrefused"} |
| acgrip | rss | prowlarr | {:indexer, {:http_status, 400, [%{"detailedDescription" => "One or more errors occurred. (Connection refused)", "errorMessage" => "Unable to connect to indexer. |
| acgrip | rss | elixir | {:connection_failed, "Connection failed: :econnrefused"} |
| anisource | tv | prowlarr | {:indexer, {:http_status, 400, [%{"detailedDescription" => "One or more errors occurred. (Network unreachable)", "errorMessage" => "Unable to connect to indexer |
| anisource | tv | elixir | {:connection_failed, "Connection failed: :nxdomain"} |
| anisource | rss | prowlarr | {:indexer, {:http_status, 400, [%{"detailedDescription" => "One or more errors occurred. (Network unreachable)", "errorMessage" => "Unable to connect to indexer |
| anisource | rss | elixir | {:connection_failed, "Connection failed: :nxdomain"} |
| btdirectory | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access btmulu.live, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| btdirectory | movie | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| btdirectory | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access btmulu.live, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| btdirectory | rss | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| btetree | generic | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access bt.etree.org, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| btetree | generic | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| btetree | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access bt.etree.org, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| btetree | rss | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| damagnet | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access damag.net, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| damagnet | movie | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| damagnet | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access damag.net, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| damagnet | rss | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| dmhy | movie | prowlarr | {:indexer, %Req.TransportError{reason: :timeout}} |
| dmhy | movie | elixir | {:connection_failed, "Request timeout"} |
| dmhy | rss | prowlarr | {:indexer, %Req.TransportError{reason: :timeout}} |
| dmhy | rss | elixir | {:connection_failed, "Request timeout"} |
| ebookbay | generic | prowlarr | {:indexer, {:http_status, 400, [%{"detailedDescription" => "The remote certificate was rejected by the provided RemoteCertificateValidationCallback.", "errorMes |
| ebookbay | rss | prowlarr | {:indexer, {:http_status, 400, [%{"detailedDescription" => "The remote certificate was rejected by the provided RemoteCertificateValidationCallback.", "errorMes |
| extratorrent-st | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access extratorrent.st, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| extratorrent-st | movie | elixir | {:search_failed, "Blocked page: 🚫 This Website is Blocked 🚫"} |
| extratorrent-st | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access extratorrent.st, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| extratorrent-st | rss | elixir | {:search_failed, "Blocked page: 🚫 This Website is Blocked 🚫"} |
| eztv | tv | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access eztvx.to, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| eztv | tv | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| eztv | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access eztvx.to, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| eztv | rss | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| filemood | movie | elixir | {:rate_limited, "Rate limit exceeded"} |
| filemood | rss | prowlarr | {:prowlarr, "{:http_status, 400, %{\"description\" => \"NzbDrone.Core.Exceptions.NzbDroneClientException: Search failed due to all selected indexers being unava |
| gamestorrents | generic | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to connect to indexer. Redirected to https://www.gamestorrents.app/juegos-pc/ from indexer request", |
| gamestorrents | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to connect to indexer. Redirected to https://www.gamestorrents.app/juegos-pc/ from indexer request", |
| internetarchive | movie | prowlarr | {:indexer, %Req.TransportError{reason: :timeout}} |
| internetarchive | rss | prowlarr | {:indexer, %Req.TransportError{reason: :timeout}} |
| kickasstorrents-to | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access kickass.torrentbay.st, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| kickasstorrents-to | movie | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| kickasstorrents-to | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access kickass.torrentbay.st, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| kickasstorrents-to | rss | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| kickasstorrents-ws | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access kickass.ws, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| kickasstorrents-ws | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access kickass.ws, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| mactorrentsdownload | rss | prowlarr | {:prowlarr, "{:http_status, 400, %{\"description\" => \"NzbDrone.Core.Exceptions.NzbDroneClientException: Search failed due to all selected indexers being unava |
| magnetcat | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access magnetcatcat.com, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| magnetcat | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access magnetcatcat.com, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| megapeer | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access megapeer.vip, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| megapeer | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access megapeer.vip, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| newstudio | tv | prowlarr | {:indexer, %Req.TransportError{reason: :timeout}} |
(60 more in bench.json)


### Regressions

None.


### Largest wasm vs Prowlarr disagreements

None.


### Per-query results

Cell: releases, or the error kind. `!` marks empty_with_credentials. Jaccard is against Prowlarr.

| Definition | Type | Query | Prowlarr | Elixir | Wasm | Jaccard Elixir | Jaccard wasm |
|---|---|---|---|---|---|---|---|
| 0magnet | public | generic | err:indexer | 50 | 42 | n/a | n/a |
| 0magnet | public | rss | err:indexer | 50 | 50 | n/a | n/a |
| 1337x | public | movie | err:indexer | err:connection_failed | 0 | n/a | n/a |
| 1337x | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| 52bt | public | movie | err:indexer | 20 | 40 | n/a | n/a |
| 52bt | public | rss | err:indexer | 20 | 40 | n/a | n/a |
| acgrip | public | tv | err:indexer | err:connection_failed | 0 | n/a | n/a |
| acgrip | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| anibt | public | tv | 100 | 100 | 100 | 1.00 | 1.00 |
| anibt | public | rss | 100 | 100 | 100 | 1.00 | 1.00 |
| animetosho-xyz | public | movie | 100 | 100 | 100 | 1.00 | 1.00 |
| animetosho-xyz | public | rss | 100 | 100 | 100 | 1.00 | 1.00 |
| anisource | public | tv | err:indexer | err:connection_failed | 0 | n/a | n/a |
| anisource | public | rss | err:indexer | err:connection_failed | 24 | n/a | n/a |
| bangumi-moe | public | movie | 30 | 30 | 30 | 1.00 | 1.00 |
| bangumi-moe | public | rss | 30 | 30 | 30 | 1.00 | 1.00 |
| bigfangroup | public | movie | 30 | 30 | 30 | 0.00 | 1.00 |
| bigfangroup | public | rss | 30 | 30 | 30 | 0.00 | 1.00 |
| blueroms | public | generic | 0 | 0 | 0 | n/a | n/a |
| blueroms | public | rss | 60 | 60 | 60 | 0.00 | 1.00 |
| btdirectory | public | movie | err:indexer | err:connection_failed | 0 | n/a | n/a |
| btdirectory | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| btetree | public | generic | err:indexer | err:connection_failed | 0 | n/a | n/a |
| btetree | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| byrutor | public | generic | 0 | 0 | 0 | n/a | n/a |
| byrutor | public | rss | 12 | 12 | 12 | 0.00 | 1.00 |
| catorrent | public | generic | 20 | 20 | 20 | 1.00 | 1.00 |
| catorrent | public | rss | 20 | 20 | 20 | 1.00 | 1.00 |
| crackingpatching | public | generic | 9 | 15 | 9 | 0.60 | 1.00 |
| crackingpatching | public | rss | 31 | 31 | 31 | 1.00 | 1.00 |
| damagnet | public | movie | err:indexer | err:connection_failed | 0 | n/a | n/a |
| damagnet | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| dmhy | public | movie | err:indexer | err:connection_failed | 0 | n/a | n/a |
| dmhy | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| ebookbay | public | generic | err:indexer | 0 | 0 | n/a | n/a |
| ebookbay | public | rss | err:indexer | 0 | 0 | n/a | n/a |
| ehentai | public | tv | 0 | 0 | 0 | n/a | n/a |
| ehentai | public | rss | 100 | 50 | 100 | 0.50 | 1.00 |
| extratorrent-st | public | movie | err:indexer | err:search_failed | 0 | n/a | n/a |
| extratorrent-st | public | rss | err:indexer | err:search_failed | 0 | n/a | n/a |
| eztv | public | tv | err:indexer | err:connection_failed | 0 | n/a | n/a |
| eztv | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| filemood | public | movie | 0 | err:rate_limited | 20 | n/a | n/a |
| filemood | public | rss | err:prowlarr | 20 | 20 | n/a | n/a |
| freejavtorrent | public | generic | 60 | 60 | 60 | 1.00 | 1.00 |
| freejavtorrent | public | rss | 60 | 60 | 60 | 1.00 | 1.00 |
| gamestorrents | public | generic | err:indexer | 0 | 0 | n/a | n/a |
| gamestorrents | public | rss | err:indexer | 0 | 0 | n/a | n/a |
| internetarchive | public | movie | err:indexer | 100 | 100 | n/a | n/a |
| internetarchive | public | rss | err:indexer | 100 | 100 | n/a | n/a |
| kickasstorrents-to | public | movie | err:indexer | err:connection_failed | 0 | n/a | n/a |
| kickasstorrents-to | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| kickasstorrents-ws | public | movie | err:indexer | 60 | 0 | n/a | n/a |
| kickasstorrents-ws | public | rss | err:indexer | 50 | 0 | n/a | n/a |
| limetorrents | public | movie | 40 | 40 | 40 | 1.00 | 1.00 |
| limetorrents | public | rss | 150 | 150 | 150 | 1.00 | 1.00 |
| linuxtracker | public | generic | 25 | 25 | 25 | 1.00 | 1.00 |
| linuxtracker | public | rss | 25 | 25 | 25 | 1.00 | 1.00 |
| mactorrentsdownload | public | generic | 0 | 20 | 20 | n/a | n/a |
| mactorrentsdownload | public | rss | err:prowlarr | 20 | 20 | n/a | n/a |
| magnetcat | public | movie | err:indexer | 20 | 0 | n/a | n/a |
| magnetcat | public | rss | err:indexer | 20 | 0 | n/a | n/a |
| magnetdownload | public | movie | 10 | 10 | 10 | 1.00 | 1.00 |
| magnetdownload | public | rss | 10 | 10 | 10 | 1.00 | 1.00 |
| megapeer | public | movie | err:indexer | 50 | 50 | n/a | n/a |
| megapeer | public | rss | err:indexer | 50 | 50 | n/a | n/a |
| mikan | public | tv | 130 | 130 | 130 | 0.98 | 1.00 |
| mikan | public | rss | 100 | 100 | 100 | 1.00 | 1.00 |
| mixtapetorrent | public | generic | 1 | 9 | 1 | 0.11 | 1.00 |
| mixtapetorrent | public | rss | 10 | 9 | 10 | 0.90 | 1.00 |
| mypornclub | public | generic | 39 | 40 | 39 | 0.00 | 1.00 |
| mypornclub | public | rss | 40 | 40 | 40 | 0.00 | 1.00 |
| nekobt | public | movie | 100 | 100 | 100 | 1.00 | 1.00 |
| nekobt | public | rss | 100 | 100 | 100 | 1.00 | 1.00 |
| newstudio | public | tv | err:indexer | err:connection_failed | 0 | n/a | n/a |
| newstudio | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| nipponsei | public | generic | 2 | 2 | 2 | 1.00 | 1.00 |
| nipponsei | public | rss | 30 | 30 | 30 | 0.00 | 1.00 |
| noname-club | public | movie | 50 | 50 | 50 | 0.75 | 1.00 |
| noname-club | public | rss | 50 | 50 | 50 | 0.61 | 1.00 |
| nyaasi | public | movie | 75 | 75 | 75 | 0.72 | 1.00 |
| nyaasi | public | rss | 150 | 75 | 150 | 0.50 | 1.00 |
| onejav | public | generic | 20 | 10 | 20 | 0.50 | 1.00 |
| onejav | public | rss | 20 | 10 | 20 | 0.50 | 1.00 |
| opensharing | public | generic | 24 | 24 | 24 | 1.00 | 1.00 |
| opensharing | public | rss | 24 | 24 | 24 | 1.00 | 1.00 |
| pandacd | public | generic | 10 | err:search_failed | 10 | n/a | 1.00 |
| pandacd | public | rss | 300 | err:search_failed | 300 | n/a | 1.00 |
| pctorrent | public | generic | 0 | 24 | 0 | n/a | n/a |
| pctorrent | public | rss | 24 | 24 | 24 | 1.00 | 1.00 |
| plugintorrent | public | generic | 0 | 30 | 0 | n/a | n/a |
| plugintorrent | public | rss | 30 | 30 | 30 | 1.00 | 1.00 |
| pornotorrent | public | movie | 100 | 100 | 100 | 1.00 | 1.00 |
| pornotorrent | public | rss | 100 | 100 | 100 | 1.00 | 1.00 |
| pornrips | public | generic | err:indexer | err:connection_failed | 0 | n/a | n/a |
| pornrips | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| pornxlab | public | generic | 60 | 60 | 60 | 1.00 | 1.00 |
| pornxlab | public | rss | 60 | 60 | 60 | 1.00 | 1.00 |
| postman | public | movie | err:indexer | err:search_failed | 0 | n/a | n/a |
| postman | public | rss | err:indexer | err:search_failed | 0 | n/a | n/a |
| rintornet | public | generic | 10 | 10 | 10 | 1.00 | 1.00 |
| rintornet | public | rss | 10 | 10 | 10 | 1.00 | 1.00 |
| rutor | public | movie | 100 | 100 | 100 | 0.89 | 1.00 |
| rutor | public | rss | 153 | 153 | 153 | 0.90 | 1.00 |
| sexypics | public | generic | err:indexer | err:search_failed | 0 | n/a | n/a |
| sexypics | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| shanaproject | public | tv | 50 | 50 | 50 | 1.00 | 1.00 |
| shanaproject | public | rss | 50 | 50 | 50 | 1.00 | 1.00 |
| showrss-yml | public | tv | err:indexer | 100 | 0 | n/a | n/a |
| showrss-yml | public | rss | err:indexer | 100 | 100 | n/a | n/a |
| skidrowrepack | public | generic | err:indexer | err:connection_failed | 0 | n/a | n/a |
| skidrowrepack | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| sosulki | public | generic | 0 | 0 | 0 | n/a | n/a |
| sosulki | public | rss | 34 | 34 | 34 | 1.00 | 1.00 |
| sukebeinyaasi | public | generic | 75 | 75 | 75 | 1.00 | 1.00 |
| sukebeinyaasi | public | rss | 75 | 75 | 75 | 1.00 | 1.00 |
| thepiratebay | public | movie | 100 | 100 | 100 | 1.00 | 1.00 |
| thepiratebay | public | rss | 50 | 50 | 50 | 1.00 | 1.00 |
| tokyotosho | public | tv | 0 | 48 | 0 | n/a | n/a |
| tokyotosho | public | rss | err:prowlarr | 74 | 75 | n/a | n/a |
| torrent-pirat | public | generic | 25 | 25 | 25 | 1.00 | 1.00 |
| torrent-pirat | public | rss | 23 | 23 | 23 | 1.00 | 1.00 |
| torrent9 | public | movie | err:indexer | 20 | 20 | n/a | n/a |
| torrent9 | public | rss | err:indexer | 105 | 0 | n/a | n/a |
| torrentby | public | movie | err:indexer | err:connection_failed | 0 | n/a | n/a |
| torrentby | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| torrentbyte | public | movie | err:indexer | err:connection_failed | 0 | n/a | n/a |
| torrentbyte | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| torrentcore | public | movie | err:indexer | err:connection_failed | 0 | n/a | n/a |
| torrentcore | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| torrentdownload | public | movie | 48 | 48 | 48 | 1.00 | 1.00 |
| torrentdownload | public | rss | 66 | 70 | 66 | 0.94 | 1.00 |
| torrentdownloads | public | movie | 50 | 50 | 50 | 1.00 | 1.00 |
| torrentdownloads | public | rss | 50 | 50 | 50 | 1.00 | 1.00 |
| torrentkitty | public | movie | 20 | 20 | 20 | 1.00 | 1.00 |
| torrentkitty | public | rss | 20 | 20 | 20 | 1.00 | 1.00 |
| torrentproject2 | public | movie | err:indexer | err:connection_failed | 0 | n/a | n/a |
| torrentproject2 | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| torrentsome | public | movie | err:indexer | 0 | 0 | n/a | n/a |
| torrentsome | public | rss | err:indexer | 20 | 0 | n/a | n/a |
| torrenttip | public | movie | err:indexer | err:search_failed | 0 | n/a | n/a |
| torrenttip | public | rss | err:indexer | err:search_failed | 0 | n/a | n/a |
| u3c3 | public | movie | 0 | 60 | 0 | n/a | n/a |
| u3c3 | public | rss | 60 | 60 | 60 | 1.00 | 1.00 |
| uindex | public | movie | err:indexer | err:connection_failed | 0 | n/a | n/a |
| uindex | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| vsthouse | public | generic | err:indexer | err:connection_failed | 0 | n/a | n/a |
| vsthouse | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| vstorrent | public | generic | 19 | 30 | 19 | 0.63 | 1.00 |
| vstorrent | public | rss | 30 | 30 | 30 | 1.00 | 1.00 |
| vsttorrents | public | generic | 12 | 12 | 12 | 1.00 | 1.00 |
| vsttorrents | public | rss | 12 | 12 | 12 | 1.00 | 1.00 |
| world-torrent | public | movie | 50 | 50 | 50 | 1.00 | 1.00 |
| world-torrent | public | rss | 50 | 50 | 50 | 1.00 | 1.00 |
| xxxclub | public | generic | err:indexer | err:connection_failed | 0 | n/a | n/a |
| xxxclub | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| xxxtor | public | generic | 50 | 50 | 50 | 1.00 | 1.00 |
| xxxtor | public | rss | 50 | 50 | 50 | 1.00 | 1.00 |
| yts | public | movie | 0 | 0 | 0 | n/a | n/a |
| yts | public | rss | 104 | 104 | 104 | 1.00 | 1.00 |
| zamundalife | public | movie | 50 | 50 | 50 | 1.00 | 1.00 |
| zamundalife | public | rss | 50 | 50 | 50 | 1.00 | 1.00 |
