# Indexers

## category_mapping.ex is Torznab protocol, not a media vertical

`lib/mydia/indexers/category_mapping.ex` has around 14 references to music, books
and adult, and reads like part of those verticals. It is not. It maps
Torznab/Newznab protocol categories, an external standard that still defines
Audio (3000), XXX (6000) and Books (7000) regardless of what Mydia stores.

Its `@audio_*`, `@xxx_*` and `@books_*` module attributes feed three things that
parse and render what third-party indexers publish: `category_name/1` (IDs to
display names like `"XXX/DVD"`), `category_id_for_name/1` (Cardigann category
names to IDs), and the full category list near the end of the module. Deleting
those constants breaks indexer capability parsing for every user.

Only the clauses whose argument is a Mydia library type are dead when the
verticals go: `categories_for_type(:music | :books | :adult)` and
`parent_category(:music | :books | :adult)`.

`type_for_category/1` is the interesting one. It feeds auto-detection in
`search_live/index.ex:386`, which treats `:other` as "no type detected, show the
manual library picker". Letting 3000, 6000 and 7000 fall through to `:other`
routes those results to the picker instead of auto-filing them. Nothing leaks and
nothing is hidden; the operator just picks a library. Its tests should be changed
to assert `:other` rather than deleted.

## Req carries a manual Cookie header across redirects

Req forwards a manually supplied `Cookie` header along a redirect, including to a
different host. It special-cases only the `authorization` header, which is
dropped on untrusted cross-host redirects and tunable via
`:redirect_trusted_hosts`. Headers you set yourself, `Cookie` included, are
carried to the redirect target unchanged. That includes a cached FlareSolverr
`cf_clearance`, so the search engine disables redirects whenever a session or
clearance cookie is attached.

Verified empirically on 2026-08-29 with two Bypass servers on different ports:
server A returned a 302 to server B, and B received `session=secret` verbatim. Req
has no cookie jar and no origin model, so do not assume it scopes cookies.

Any code attaching a session cookie as a raw header and letting Req follow
redirects hands that credential to whatever host the `Location` names. When the
redirect source is remote content such as a tracker, a mirror or a scraped site,
that is attacker-triggerable rather than accidental.

When attaching credentials as a raw header, either set `redirect: false` and
handle hops yourself with a per-hop origin check, or accept that the credential
goes wherever the response points. The Cardigann search engine takes the first
option: `session_cookie_pairs/4` in `lib/mydia/indexers/cardigann_search_engine.ex`
sets `redirect: false` whenever it attaches a `Cookie`, and an unfollowed 3xx
falls through to the existing failover. Trusted-origin scoping for absolute paths
and mirror failover is tracked in issue #602.

## Cardigann login

`Mydia.Indexers.Cardigann.Login` owns authentication for a definition. It picks
the strategy from the definition's `login.method` (`cookie`, `get`, `post` or
`form`), never from which credentials happen to be filled in, and returns a
`Login.Session` of cookies. The pieces live under `cardigann/login/`: `Simple`
for the first three methods, `Form` for scraping and submitting a login form,
`Http` for the requests, `Inputs` for rendering and `Verify` for the
definition's `login.error` and `login.test` blocks.

**Setting names come from the definition.** Login paths, inputs and headers are
rendered through `CardigannTemplate` with the stored config as `.Config`, so a
definition that writes `{{ .Config.apikey }}` or `{{ .Config.pin }}` reads the
setting called `apikey` or `pin`. The `cookie` method reads a setting literally
named `cookie` and accepts a pasted Cookie header. Mydia has no username and
password fields of its own to map onto; do not add one, or definitions that
name their settings differently stop working.

**Login HTTP never lets Req follow a redirect.** `Login.Http` sends every
request with `redirect: false` and walks `Location` headers itself, up to five
hops. Req would carry the Cookie header we set to whatever host a redirect
names (see the Req section above), and a login is exactly when that header
holds credentials. Each hop is checked first: a cleartext non-loopback URL is
refused, and so is any origin outside `CredentialScope.trusted_origins/2`. A
redirect after a POST becomes a GET, as browsers do, and `Set-Cookie` values
are folded into a jar that rides along on later hops. Login goes to the
definition's active link when that is one of its own origins, otherwise to the
first link, so a legacy mirror never receives credentials.

**A form login can pause for a person.** `Form.begin/1` fetches the login page
and scrapes the form. When the definition has an image captcha, or its inputs
reference a 2FA key (`2facode`, `2fa_code`, `alt2fatoken`), it returns
`{:needs_input, %Challenge{}}` instead of submitting. The challenge keeps the
cookie jar and the scraped page, so the captcha image and the eventual submit
share one tracker session, and `Login.complete/2` finishes it with the answers.
Nothing submitted by a person (captcha text, one-time code, credentials) is
logged.

### Sessions and recovery

`SessionManager` is what searches and health checks call. There is one stored
session row per definition (`CardigannAuth.store_session/3` upserts) and no
fixed TTL: a session lives until the tracker stops honoring it. Stored cookies
are used as they are. With none stored, the manager logs in. Saving a changed
config (a pasted cookie is the credential) or removing the definition from the
library deletes the stored session, via `Indexers.configure_cardigann_definition/2`
and `Indexers.remove_cardigann_definition/1`.

When a search that sent our cookies comes back logged out, `with_session/3`
invalidates the session, logs in once and retries once. `LoggedOut.check/3`
follows Prowlarr's CheckIfLoginIsNeeded and recognizes three signs: a redirect,
a 401 or 403, and an HTML page missing the definition's `login.test.selector`.
The selector test is skipped when every search path declares a json or xml
`response.type`, whatever content-type the tracker sent.
It only looks at requests that carried our cookies, and any redirect counts
because the search engine never follows a cookie-bearing redirect, so a 3xx can
only be the tracker sending us to its login page. If the retry is still logged
out, the error says so rather than looping.

### needs_login

`health_status: "needs_login"` is set only when a login needs a person, that
is when `Login.begin/2` returns a `Challenge`. While it is set,
`SessionManager.user_config/2` returns a `:login_required` error, so searches
skip the indexer and the health check reports "Needs login" without writing
anything or counting a failure. Two things clear it: a stored session
(`SessionManager.store/2` moves the definition back to `healthy`) and saving a
changed config, which resets it to `unknown` so new credentials get a fresh
attempt. Do not clear it from a health check or a timer; the health check's
status write skips rows that are `needs_login`, so a probe that was running when
a search parked the row cannot overwrite it. A check that passes while the tracker still
needs a captcha would hide the problem until the next search failed.
Status changes broadcast on `SessionManager.topic/0` for the admin page.

## Ranking has one path

Every ranking decision ends in `QualityProfile.score_media_file/2`, and every
input to it is built by `Mydia.Quality.Attrs`: `from_quality/3` for a release,
`from_media_file/2` for a file on disk. Search ranking (`SearchScorer`), upgrade
decisions (`Upgrades.Comparator`) and profile codec preferences all read that
vocabulary. A release or codec spelling that scores wrong is fixed there, once.

Search adds exactly one rule on top, in `SearchScorer.release_attrs/2`: a
release with no resolution token is judged as 360p. Upgrades leave it unknown
instead, because a file's missing resolution means "not analyzed yet".

The manual search dialog gets a row's score, breakdown, detected values and
violations from one `ReleaseRanker.explain/2` call, the same pipeline automatic
search ranks with. Do not score a row a second way for display.

## Limits vs preferences

There is no minimum score before an automatic grab. A release that is only
scored down is still grabbed whenever it tops a list of bad releases, which is
how a 1080p profile took a 360p XviD and an episode profile with a size floor
took episodes far below it. So every quality-profile setting falls in one of
two classes, and the class decides where it is enforced.

**Limits.** A setting that constrains the resulting file and is phrased as a
limit (min, max, require, exclude). Automatic and upgrade search never grab a
release that breaks one (`Mydia.Indexers.ProfileLimits.reject/2`), and a file
on disk that breaks one is a violation in
`Mydia.Settings.QualityProfile.score_media_file/2`, so it scores 0 and is
eligible for upgrade. Manual search passes `apply_profile_limits: false`, lists
the release below every compliant one, and shows the reason.

**Preferences.** Everything else. They only change ranking.

| Setting | Class |
|---|---|
| `excluded_sources` | limit |
| `min_resolution`, `max_resolution` | limit |
| `require_hdr` | limit |
| `movie_min_size_mb`, `movie_max_size_mb`, `episode_min_size_mb`, `episode_max_size_mb` | limit (a season pack is judged per episode; an unknown size passes) |
| `preferred_*`, `hdr_formats` | preference |
| `min_ratio`, minimum seeders | preference: they describe whether a download will finish, not the file, and `StallDetector` handles dead torrents |
| audio language | preference (outermost sort key) |

Blocked tags, rejecting custom formats and identity mismatches are also hard
removals, but they are not profile settings.

A new `quality_standards` key must be classified in `ProfileLimits`.
`test/mydia/indexers/profile_limits_test.exs` fails until it is, and checks
every limit in all three places (automatic removal, manual listing, file
violation). Changing a limit to a preference means changing that test, not
just the ranker.

## Grab delay

`grab_delay_hours` on a quality profile is neither a limit nor a preference: it
decides when an automatic search grabs, not what. `Mydia.Indexers.GrabDelay`
runs on the ranked list wherever an automatic search picks a release (movie
searches, episode searches and season-pack searches, including their upgrade
modes) and answers grab now or wait until a time.

The clock is the oldest `published_at` among the releases left after limits,
blacklist, identity and the upgrade candidate filter. A newer upload never
resets it, and a backlog item grabs at once because its releases are old.
A release without a date counts as old. A release dated in the future (indexer
clock skew) cannot stretch the wait: it is capped at the delay from now.

A best release that already scores at or above `upgrade_until_score` grabs at
once. That comparison uses the file-scale score from
`SearchScorer.score_quality/3`, the scale the upgrade cutoff is defined on, not
the ranker's total, which adds seeders and title match.

A wait records no backoff. `Mydia.Jobs.SearchDeferral` logs `search.deferred`
and schedules a re-check for that episode, season or movie (or the same
upgrade) a minute after the delay ends, since upgrades otherwise only run
nightly. The event is recorded once per wait: the re-check is unique while it
is scheduled, and a repeat insert emits nothing.

While the re-check is pending, the cron searches skip that item (and, for a
season re-check, every episode of that season), since searching cannot grab
anything before then. The re-check carries a `recheck` marker, and if the item
was unmonitored in the meantime it does nothing. Searches a person starts
carry `bypass_delay` and never wait; that includes search on add, request
approvals and plugin page adds. Cron, the upgrade sweep, failed-download
replacement searches and the re-check itself never set it. Manual search
ignores the delay entirely.

## Prowlarr pauses indexers; Mydia only reports it

Prowlarr puts a failing indexer on an escalating backoff (1m, 5m, 15m, 30m,
1h, 3h, 6h, 12h, 24h) and drops it from every search until `disabledTill`,
even when the search names it in `indexerIds`. Prowlarr never retests a
paused indexer on its own. Mydia caches nothing here: every search is a live
`GET /api/v1/search`, so a "missing" indexer is Prowlarr's backoff, not stale
Mydia state.

Mydia reads `GET /api/v1/indexerstatus` to show what is paused
(`Adapter.Prowlarr.list_paused_indexers/1`): in Prowlarr health details on the
admin Indexers page, and on the Prowlarr row of manual search
(`search_all/2` with `report_paused: true`). A user may click Retest, which
calls Prowlarr's per-indexer `POST /api/v1/indexer/test?forceTest=true`, one
indexer at a time. Never call that from a background job or `testall`: a
failed test escalates the backoff, and the backoff exists to protect trackers.

## FlareSolverr earns a clearance; the request is repeated directly

Cardigann follows Prowlarr's FlareSolverr model
(`src/NzbDrone.Core/IndexerProxies/FlareSolverr/FlareSolverr.cs`).

- A request goes direct first.
- On a Cloudflare challenge, FlareSolverr gets the bare URL. It never gets
  cookies: FlareSolverr 3.x adds them to a browser that has already
  navigated, and Chrome rejects any whose domain does not match ("invalid
  cookie domain").
- The solution's cookies and `userAgent` go into
  `Mydia.Indexers.FlareSolverr.ClearanceCache`, keyed by host and port.
- The request is repeated directly, and that response is what gets parsed.

`cf_clearance` is bound to the user-agent that earned it, so the two are only
sent together.

Parsing `solution.response`, Chrome's rendered DOM, is a fallback for a site
whose clearance does not carry over. Parsing it routinely is what made 1337x,
EZTV and kickass return zero rows: that path dropped the definition's own
headers, EZTV's `layout=def_wlinks` cookie among them.

Every FlareSolverr request opens a Chrome tab. They queue on
`Mydia.Indexers.FlareSolverr.Gate`, sized by
`flaresolverr.max_concurrent_requests` (`FLARESOLVERR_MAX_CONCURRENT_REQUESTS`,
default 1). Without it, `search_all/2` asked for one tab per protected indexer
at once and FlareSolverr crashed them.

A queued caller waits up to `flaresolverr.max_timeout` for a slot (the longest
one solve can hold it), then gets `:flaresolverr_busy`. `search_all/2` cancels
its tasks at the search deadline first, and the gate's monitors free their
places. Req waits `max_timeout` plus 10s for an answer, and a transport timeout
is not retried because FlareSolverr's first tab may still be alive. The health
probe (`sessions.list`) does not go through the gate because it opens no tab.

No sessions (`sessions.create`): each keeps a Chrome instance resident, which
is the resource the gate exists to protect.

## Cardigann HTML runs on lexbor, not Floki

Definitions are written against goquery (Jackett) and AngleSharp (Prowlarr),
which build an HTML5 tree and implement modern CSS. Floki's mochiweb parser
inserts no implied `<tbody>`, and its selector engine mis-evaluates nested
`:has()` and `:not(:has())`. On 2026-10-11 that alone left five public trackers
with zero or wrong rows.

`Mydia.Indexers.Cardigann.Selector` parses with LazyHTML (lexbor) and evaluates
every standard selector natively. Cardigann's only non-standard pseudo-class,
`:contains()`, is precomputed: `Selector.parse/2` takes the selectors the caller
will use, marks each element whose text contains a needle with a
`data-mydia-cN` attribute, and `find/3` rewrites `:contains(...)` to that
attribute. A `:contains` that was not declared at parse time raises. Nothing
under `lib/mydia/indexers/cardigann*` calls Floki.

## Cardigann engines: built-in and Prowlarr-based

Two engines can run Cardigann definitions, chosen by the layered setting
`cardigann.engine` (env `CARDIGANN_ENGINE` pins it and locks the admin UI;
otherwise the Indexers tab writes it):

- `builtin` (the default): the Elixir engine under `lib/mydia/indexers/cardigann*`.
  Costs nothing extra: no download, no compile, no memory.
- `prowlarr`: Prowlarr's own C# Cardigann engine, compiled to a wasm component and
  run inside Mydia (`Mydia.Indexers.Cardigann.Wasm.*`). Definitions are read by the
  code that reads them in Prowlarr, so results match Prowlarr's. Anything else
  raises at boot, naming the two valid values. `ENABLE_CARDIGANN=false` turns
  Cardigann off whichever engine is set.

The UI calls the second one Prowlarr-based. It has nothing to do with `Adapter.Prowlarr`, which talks to a Prowlarr server under Indexer Connections; the engine runs Prowlarr's code inside Mydia with no server.

What `prowlarr` gives: on the 44 public definitions where Prowlarr returned
results, the wasm engine agreed with Prowlarr on all of them (the Elixir engine on
28); it fails over to the next entry of `links:` when a mirror is down or blocked,
and remembers the one that worked. What it costs, measured on the Alpine image
(`native/cardigann_guest/BENCH.md` has the method and every number):

- **First boot.** The engine is not in the image. It downloads about 39 MB from the
  `cardigann-guest-<hash>` GitHub release and verifies it against a SHA-256 that is
  compiled into the build (a mismatch is an error, never a fallback). It then
  downloads the CI-compiled form (`cardigann-cwasm-...` release, 28.8 MB
  compressed), verifies that against a pin baked into the image and caches it. That
  takes about 6 s from container start to ready and peaks near 0.65 GB of resident
  memory. Without a published or reachable `.cwasm` (a Nix build, a failed
  download, a file wasmtime rejects) it compiles locally instead: about 18 s on
  Alpine, peaking near 1.6 GB. Both settle at about 500 MB. Until it is done,
  the built-in engine keeps serving searches and the Indexers tab shows progress;
  the rest of Mydia boots normally. A failed download or compile retries
  in the background, 30 s doubling to 30 min.
- **Where it lives.** `cardigann/` under `MYDIA_DATA_DIR`, or next to the database
  file when that is unset (`/config` in the image). It holds the `.wasm` (39 MB) and
  the compiled `.cwasm` (119 MB, named for the wasm hash, the wasmtime version and
  the CPU architecture, with a checksum file that is verified before every load).
  Files for other versions are deleted after a successful load. Keep the directory
  on a volume: without one, every recreate downloads the `.wasm` and the published
  `.cwasm` again, and compiles locally only when the published file is unavailable
  or rejected.
- **Later boots.** The `.cwasm` loads in under a second. A `.cwasm` that fails its
  checksum or is rejected by wasmtime (another CPU, a corrupt file) is deleted and
  rebuilt.
- **Air-gapped installs.** Set `CARDIGANN_WASM_PATH` to a local copy of
  `cardigann-<hash>.wasm`. It is verified against the same pin, so it must be the
  file published for this Mydia version, and nothing is downloaded. The compiled
  form is still cached in the data directory.
- **Memory.** About 64 MB more than the default engine at rest. Each running
  search adds about 58 MB on a small page and 175 to 185 MB on a 1 MB page, freed
  when the search ends. `config :mydia, :cardigann_wasm_max_instances` (default 2)
  caps how many run at once; the rest queue (the `queue` measurement of the call
  telemetry is the wait, in native time units) and the wait counts against the call timeout. With
  the cap the peak is about 117 MB over idle for any number of small searches and
  360 to 450 MB for a burst of 1 MB pages, against 230 to 455 MB and up to 1.2 GB
  without it. Containers capped below about 2 GB can be killed during
  the local compile, which only runs when the precompiled download is not used.
- **Latency.** About 60 ms more per search at the median, and 110 ms more at p95,
  on top of the network time, one search at a time. Searches beyond the cap wait
  for a slot: eight small searches at once take about 150 ms in total instead of
  100 ms.
- **Experimental toolchain.** The component is built with a pre-release .NET
  (NativeAOT-LLVM to `wasm32-wasip2`) and runs on a patched Wasmex that is built
  from source. Expect rough edges.
- **Errors are Prowlarr's.** A failed search says what the C# engine says: an HTTP
  status, "Cloudflare protection detected", "No answer from the tracker". 20 of the
  81 public definitions in the benchmark end in such an error; Prowlarr returned
  nothing on all 20 too. FlareSolverr is still the way through a Cloudflare block.
- **LAN trackers are refused** (the host's SSRF gate), and Brotli responses are
  not decoded. The Indexers tab recommends it for private trackers because their
  logins run through Prowlarr's own login code. The benchmark itself covers public
  definitions only.

The gate that decided this: fidelity, coverage and regressions pass, latency
passes with 24 ms to spare, the first-boot compile time and the memory under load
do not, which is why it is opt-in. Builds from a commit whose guest has not been
published yet have no pin; the engine then reports "no published Cardigann engine
for this build" and the default engine is unaffected.

### Switching at runtime

`Mydia.Indexers.Cardigann.EngineSwitcher` applies the setting without a restart
(boot uses the same path). Switching to `prowlarr` starts `Wasm.Engine` while the
built-in adapter keeps serving; once the engine reports ready, the switcher
cuts over by re-registering `:cardigann`. Switching back re-registers the
built-in adapter, then stops the engine, which frees the compiled component. The
cache on disk is kept; `remove_cache/1` deletes it. If the engine stops being
ready after the cutover, the switcher falls back to built-in until it is ready
again. `CardigannFeatureFlags.active_engine/0` reads the active engine.

### Verified badges

The Indexers tab shows which engines each definition is verified on, from
`Mydia.Indexers.Cardigann.EngineSupport`. To refresh it, run
`mix mydia.cardigann_bench` and paste the map at the end of its `bench.md` over
`@verified`, then update `@verified_on`.

## Measuring live compatibility

`mix mydia.cardigann_compat` scores YAML features statically and reads about 99%
for public definitions. It cannot see runtime failures. `mix
mydia.cardigann_health --from-cache <dir> --type public` runs each definition
through the real search path and buckets the result (`ok`, `ok_empty_query`,
`rows_dropped`, `blocked_page`, `parse_error`, ...). It talks to real trackers:
run it by hand, never in CI. `--capture tmp/cardigann_captures` saves raw pages;
committed fixtures are reduced from them with invented titles, never copied.
