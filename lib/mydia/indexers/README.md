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

`health_status: "needs_login"` is set only when a login needs a person:
`SessionManager.park/1`, called when `Login.begin/2` returns a `Challenge` or
when the wasm engine's search stops at the login form. While it is set,
`SessionManager.user_config/2` returns a `:login_required` error, so searches
skip the indexer and the health check reports "Needs login" without writing
anything or counting a failure. Two things clear it. A stored session:
`SessionManager.clear_needs_login/1` is the one conditional writer, called by
`store/2`, by the wasm adapter when it writes a session, and by `park/1` itself
when it finds a session stored meanwhile; it reads the row, not the caller's
struct. And saving a changed config, which resets it to `unknown` so new
credentials get a fresh attempt. Do not clear it from a health check or a timer; the health check's
status write skips rows that are `needs_login`, so a probe that was running when
a search parked the row cannot overwrite it. A check that passes while the tracker still
needs a captcha would hide the problem until the next search failed.
Status changes broadcast on `SessionManager.topic/0` for the admin page.

The Prowlarr-based engine parks the same definitions the same way. Prowlarr's
search logs in by itself and swallows a failed login into an empty page, so
for a definition where `Login.needs_person?/1` holds, `Wasm.Adapter` parks it
(`SessionManager.park/1`) when a search reached the login form, came back
empty and left the cookies unchanged (a login that went through changes them,
so an honest empty page on a fresh login is not parked). "Reached the login
form" is `HostHttp` flagging a request whose scheme, host, port and path match
`login.path` or `login.submitpath`, rendered with the stored settings and
resolved on each current link, through the ctx's `:login_watch`; the flag is
reset before each mirror attempt. Only the rejected session is deleted, and
`park/1` writes `needs_login` first and reads the stored session after, so a
session stored meanwhile (by `store/2`, which clears `needs_login` from the
database row rather than the caller's struct) never stays parked; `park/1`
then returns it. The Indexers page's **Log in** always runs the built-in `Login`, on
either engine, and both engines read the session it stores. The guest's own
`login/2` can return a captcha too, but nothing calls it from the UI.

### Private-tracker journeys

`test/mydia/indexers/private_tracker_journey_test.exs` (built-in),
`test/mydia/indexers/cardigann/wasm/private_tracker_journey_test.exs` (wasm,
`:cardigann_wasm`) and
`test/mydia_web/live/admin_indexers_live/private_tracker_login_test.exs` run
whole journeys against three invented trackers in
`Mydia.PrivateTrackerFixtures`: a UNIT3D API tracker (Bearer key, JSON rows
under `attributes`, rsskey in the download path), a Gazelle form login (CSRF
token from `selectorinputs`, `torrent_pass` links) and a captcha + 2FA form
posting to a separate `submitpath`. They found three gaps, all fixed: search
headers were sent unrendered (every UNIT3D definition sent
`Bearer {{ .Config.apikey }}`), a JSON `rows.attribute` naming an object was
ignored, and `TorrentFetch` logged release URLs and torrent bodies with the
passkey in them. They assert at `:info`, the production default; at `:debug`
Ecto's query log still prints `downloads.download_url`. That row keeps the raw
URL on purpose: re-grab and duplicate detection match on it, and a redacted
Gazelle URL cannot be rebuilt (the authkey is not a setting).

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

## Tracker terms

`SearchResult.terms` is a `Mydia.Indexers.Structs.TrackerTerms`: `private?`,
`minimum_ratio`, `minimum_seed_time` (seconds) and the download and upload
volume factors. Every field may be nil, meaning unknown, never "no
requirement". Terms belong to the tracker named in `SearchResult.indexer`, not
to the Mydia indexer config, since one Prowlarr or Jackett connection fronts
many trackers.

What each adapter can know:

| Adapter | Volume factors | Ratio and seed time | Private |
| --- | --- | --- | --- |
| Jackett | `torznab:attr` | `minimumratio`, `minimumseedtime` attrs | unknown |
| Newznab | `newznab:attr`, same names | same | unknown |
| Prowlarr | from `indexerFlags` | unknown | `GET /api/v1/indexer` `privacy` |
| Built-in Cardigann | definition fields of the same names | same | definition `type` |
| WASM engine | the guest's release record | same | definition `type` |

Prowlarr's `/api/v1/search` JSON carries no factors or minimums
(`ReleaseResource.cs`), only flags it derives from the factors:
`freeleech` is a download factor of 0, `halfleech` 0.5, `neutralleech` 0 both
ways, `doubleupload` an upload factor of 2. The adapter maps them back, and
still reads `minimumRatio`, `downloadVolumeFactor` and the rest first in case a
Prowlarr version adds them. Privacy comes from the indexer list, cached per
connection by `Adapter.ProwlarrPrivacy` (an hour, five minutes after a
failure). Reads are single-flight per connection, an expired map is served
while one background read replaces it, and a cold search waits at most three
seconds before carrying on without privacy, so the lookup never eats the
search task's deadline. Test config turns that lookup off (`:prowlarr_privacy_lookup`) so a
Bypass search stub does not also need an indexer-list stub.

Overrides are `tracker_rules` (YAML, `TRACKER_RULE_<N>_*`, and
`tracker_rule_configs` rows). A row shadows the runtime rule for the same
tracker field by field: a field the row leaves empty keeps the YAML or env
value, so a row cannot clear a runtime value, only replace it.
`TrackerRules.effective/3` applies them field by field: the rule's
value, then what the tracker reported for that release, then nil. A rule's
`seed_time` is in minutes. Volume factors are never overridden.

At grab, `Queue.build_download_metadata/1` freezes the effective terms into
`Download.metadata["tracker_terms"]` (`TrackerTerms.to_map/1`; read back with
`from_map/1`), so a later override never changes the rules of a torrent
already seeding. A download with no known terms has no key.

`TrackerSightings` keeps one row per tracker seen in search results, written
once a minute by its recorder, for the admin list. An override is stale when
its tracker was neither seen nor grabbed in 30 days and it is not a row
created within that window.

## Tracker limits

`tracker_rules` also carry `grab_limit` and `query_limit`, each per rolling 24
hours and optional. `TrackerLimits` applies them:

- Searches: `search_all/2` runs each indexer's search through
  `TrackerLimits.guard_query/2`. A rule applies to the Mydia indexer whose name
  matches its tracker (a built-in Cardigann definition, or a Jackett or Torznab
  feed for one tracker). A Prowlarr or aggregate Jackett connection sends one
  search to trackers Mydia cannot see, so those rely on Prowlarr's limits.
  Every attempt counts. At the cap the indexer is skipped with a
  `:rate_limited` error, which manual search shows as the indexer's status.
  Counts live in `RateLimiter`'s rolling windows, in ETS, and reset on
  restart. `reserve_window/3` inserts the slot before counting and backs out
  over the limit, so concurrent searches cannot all take the last slot.
- Grabs: counted from `downloads` rows whose `indexer` is the tracker and that
  were inserted in the last 24 hours, failed grabs included and deleted rows
  not. `background_search_opts/0` sets `skip_capped_trackers: true`, so
  automatic searches drop a capped tracker's results before ranking. Manual
  search keeps them, notes the reason on the row
  (`MydiaWeb.MediaLive.Show.TrackerLimitNote`) and still allows the grab.

## Download URLs carry credentials

A release's `download_url` (and often its `guid`) can carry the searching
account's passkey (`passkey=`, `torrent_pass=`, `apikey=`). Keep it on the
server:

- Search rows send `MydiaWeb.Live.SearchResultRef.ref/1`, and the LiveView
  resolves the result it already holds. Never put the URL in a `phx-value-*`.
- Anything rendered or logged goes through
  `Mydia.Downloads.Client.Helpers.redact_url/1`. It redacts credential query
  parameters (Gazelle's `authkey`, `torrent_pass`), userinfo, and path parts
  that look like keys (UNIT3D's `/torrent/download/<id>.<rsskey>`): 24+
  characters of `[A-Za-z0-9_-]` with letters, digits and a 16-character run
  without separators. Its result is for display and logs only, never a URL
  to fetch.
- Events carry the download id (`Downloads.Grabber` broadcasts
  `%{download_id: id}`), never the URL.

`test/mydia/no_raw_download_url_test.exs` fails on a `Logger` call or HEEx
interpolation that mentions `download_url` without `redact_url(`. It reads
source, so a URL renamed to `url` before logging slips past it.

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

## Search paths are pages

A definition paginates by listing several `search.paths` entries (1337x has
four pages of 20, KickassTorrents two of 50). Like Prowlarr, the built-in
engine requests every path whose categories match the query
(`Cardigann.SearchPaths`: site ids mapped through `categorymappings`, a query
without categories runs them all, `"!"` inverts) and merges the rows.

Page 1 is the search: it gets mirror failover, FlareSolverr and the login
session, and its error is the search's error. Later pages
(`Cardigann.SearchPages`) are best effort. They are pinned to the mirror
page 1 answered on (`response.base_url`, `pin_base_url: true`), reuse its
session and clearance, and stop at the first failed or empty page. Requests to
one definition are spaced by its `requestDelay`. Paging also stops once 15
seconds have passed since the search began, so a slow site returns the pages it
has instead of losing the whole search to the caller's deadline. Rows are de-duplicated within the indexer by
info hash, then download URL.

Each path keeps its own `inputs` (merged over the search inputs unless
`inheritinputs: false`), `method`, `response` type and `followredirect`.
The health check and `LiveCheck` request page 1 only.

## Cardigann result parsing

`CardigannResultParser` is a thin facade over `lib/mydia/indexers/cardigann/result/`.
`Result.Plan.compile/2` turns a definition's `search.rows` and `search.fields`
into typed structs once per parsed response: the row selector, its attribute,
`after`/`count`, `andmatch`, `missingAttributeEqualsNoResults` and row filters,
plus one `Plan.Field` per field with its selector, attribute, `case`, `remove`,
`optional`/`default` and `text`. A template that reads `.Result` stays raw and is
rendered per row; every other template is rendered at compile time. Each page's
response compiles its own plan, so a multi-page search compiles once per page.
The search path's declared `response.type` picks the format, and only a
definition that declares none gets the body sniffed: a pre-decoded map or list
is JSON, a body starting with `{` or `[` is JSON when it decodes, an `<?xml`
prolog or an `<rss>` or `<torrents>` root is XML, and anything else is HTML.

`Result.Pipeline.run/3` asks a format adapter to decode the body and list its
rows, then runs `Result.Fields` over each row. The extractor makes two passes:
selector fields in dependency order, each seeing the fields before it through
`.Result`, then text fields in dependency order among themselves. It folds
`title_default`/`title_optional` into `title` and `download2`/`magnet` into
`download`, and a row without a title or without a download or infohash is
dropped. `Result.Transform` then builds the `SearchResult`s, and `ParseStats`
counts what matched, what a row filter removed and what was dropped.

The adapters only read a document: HTML through lexbor and `Selector`, JSON
through `JsonPath` (`..` reaches the parent row, and `case` keys compare by
equality), XML through SweetXml with CSS child combinators and attribute
predicates translated to XPath. Everything a definition declares around the
value (filters run after `case` and after a default, text fields, `rows.after`
and `rows.count`, the row-level `andmatch` filter) lives in the pipeline and
extractor, so all three formats behave the same.

A field that is wrong for every format is fixed once in `Result.Fields` or
`Result.Transform`: the extractor owns ordering, defaults, compound fields and
filters, while the transform owns the title and download choice, size, date,
category, guid and external ids. A field wrong only for one response format
belongs in that format's adapter, and a filter that mangles a value belongs in
`CardigannFilters`.

`guid` is always set now: the download field, else the resolved download URL
(often a magnet built from the infohash), as Prowlarr's release cleanup does. A
row with neither is already dropped, so its details URL never stands in for a
guid. `Mydia.Downloads.Blacklists.release_guid/1` therefore keys new Cardigann
bans by guid instead of the `sha256:` fallback of indexer, title and size.

That guid is a URL, so it changes when a definition fails over to another
mirror or the link carries a session token. Each new ban also records the
`sha256:` key in `fallback_guid`, and lookups (`reject_blacklisted/2` and the
manual search's prior-attempt labels) compare a result's guid and its
`sha256:` key against both columns. The ban therefore follows the release
across mirrors as long as the title and size match.

A ban the built-in engine wrote before the upgrade is keyed by the `sha256:`
value, so it still matches when the release comes back with the same title and
size. Legacy matching stops there: a pre-upgrade row has no `fallback_guid`, so
one keyed by a URL guid (the Prowlarr-based engine already set those) matches
only that exact URL, and no key survives a change of title or size.

Upgrading also changes which rows come back: `rows.filters: andmatch` now drops
rows whose title lacks a keyword in every format, not only HTML. Six definitions
declare it: five snapshot fixtures (showrss, crackingpatching, eztv, ebookbay and
torrentlt) and the seeded parity definition pctorrent, so a keyworded query
against any of them returns fewer rows than before.

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

## Cardigann parity oracle

The wasm engine runs Prowlarr's own Cardigann code, so on the same HTTP it gives
the answer Prowlarr would. The parity oracle uses it as the reference for the
built-in engine: it records real tracker responses once, replays them offline
through both engines, and compares the results field by field (title, size,
seeders, leechers, download and info URLs, guid, category, date, external IDs,
info hash, volume factors). Code is under `lib/mydia/indexers/cardigann/parity/`;
the task is `mix mydia.cardigann_parity` (its moduledoc lists every flag).

- `record [--ref SHA] [--only a,b]` runs the wasm engine live against the
  trackers at a Prowlarr/Indexers commit and saves every exchange under
  `~/.cache/mydia-cardigann-parity/<ref>/<definition>/<query>/`. This is the
  only command that touches the network. Nothing it writes goes in the repository.
- `diff [--only a,b] [--seed] [--write-ratchet]` replays a capture set (the
  newest one, or the committed seed with `--seed`) and prints a report of every
  divergence. `--write-ratchet` rewrites the ratchet, keeping existing reasons
  and marking new entries `"TODO"`.
- `seed <definition>` scrubs one definition's cached captures into
  `test/fixtures/cardigann/parity/<definition>/`: pages trimmed to their rows,
  real names replaced, and the result replayed to prove the wasm engine still
  parses it the same way. It refuses to write a capture that fails that check.

### The seed set

Recorded at Prowlarr/Indexers `d34bddc56cfd6a55f75a9f69dcc2df9eb591662c` on
2026-10-28. Nine definitions, 18 captures, 2.7 MB. The set leans on game,
distro and anime trackers, whose titles carry fewer film and series names for
the scrubber to catch.

| Definition | Captures | What it covers |
|---|---|---|
| bigfangroup | movie, rss | windows-1251 HTML; a title selector that matches three links per row |
| blueroms | generic, rss | a title built from another field by an `append` filter template; console categories; `generic` is a page with no results |
| dmhy | movie, rss | CJK fansub titles with several names each; a hidden absolute date beside a relative one |
| linuxtracker | generic, rss | `categorydesc`; magnets built from an info hash; rows whose category has no mapping |
| mikan | tv, rss | a chain of text fields (`date_year_raw` to `date_year` to `date`) and fuzzy relative dates |
| nekobt | movie, rss | XML (Torznab feed), kept whole |
| nyaasi | movie, rss | a multi-page search: the keywordless `rss` query reads two pages from two search paths |
| pctorrent | generic, rss | windows-1251 HTML; `rows.filters: andmatch` (24 rows against 0) |
| yts | movie, rss | JSON; the `case` block (one of three public definitions with one), exercised by `rss` only: `movie` is an empty answer (`movie_count: 0`), because the corpus's movie term `1080p` matches no YTS title |

byrutor and crackingpatching were seeded once and dropped: their pages repeat
real names outside the titles (a developer that shares words with a title,
software names in descriptions and image alt text), which the leak check
rejects. Adult trackers are never in the set. `parity_test.exs` pins the list
of captures, so adding or dropping one is a deliberate change to the test, the
ratchet and this table together.

### The ratchet

`test/fixtures/cardigann/parity/known_divergences.exs` lists every divergence
the built-in engine still has on the seed, one entry per definition, query,
kind and field, each with a reason. The current seed has none; the built-in
engine agrees with Prowlarr on every capture, up to the two rules below.
`test/mydia/indexers/cardigann/parity_test.exs`
replays every capture (one test per capture, tagged `cardigann_wasm`, so it runs
wherever the guest is present) and fails when:

- a divergence is not in the file (a regression, or a new capture);
- an entry no longer occurs (a fix: delete the entry, so the file only shrinks);
- an entry still reads `"TODO"`.

A reason comes from reading both engines' output for that field and the code
that produced it. When the cause is not known, the reason starts with
`unexplained:` and says what differs.

To refresh the seed: `record`, then `seed` each definition, then
`diff --seed --write-ratchet`, then annotate the new entries and run the test.

### Deliberate differences

Two magnet differences from Prowlarr are on purpose, and `Parity.Diff`
compares through them rather than listing them in the ratchet:

- **Trackers and hash case.** Native builds magnets with
  `TorrentHash.build_magnet/2`, which the Prowlarr adapter and
  `cardigann_download.ex` share: Mydia's eight trackers and a lowercase hash.
  Prowlarr adds its own trackers. Two magnets with the same btih compare
  equal without their `tr` parameters, in `download_url` and in `guid` (an
  info-hash-only row's guid is that magnet in both engines). `dn`, `ws`,
  `x.pe` and the rest still count.
- **The info hash wins over the download link.** When a row has both, native
  hands out the info-hash magnet, because some sites (YTS) answer the
  download link with an HTML page. It keeps the link in
  `metadata.source_download_url`, and a native magnet equals Prowlarr's link
  only when that field names the same URL.

Native also follows Prowlarr's `IsValidRelease`: automatic searches drop a
release with no category or no size, and the manual search UI, which passes
`interactive: true`, keeps it.

### What scrubbing guarantees, and what it does not

Work names in the seed's release titles are invented (`Mellow Kiln`). The one
exception is a work that equals a category name in the definition, which is
kept as the limits below describe. The scrubber learns real names from the
titles both engines parse: the text before the first release marker, each
bracketed, slashed, comma-listed, `+`-joined or colon-split segment, the same
without numbered or version tokens at its edges, the Latin part of a name
written in two scripts, and an episode title of two or more words between two
markers. It replaces them one work at a time, longest first, in every spelling
a tracker uses (escaped, percent-encoded, as a slug, in the page's charset,
with any punctuation between its words, with accents stripped or dropped, with
an acronym's dots taken out), so a shorter name never renames the start of a
longer one and leaves the rest.

Real identifiers are replaced too: IMDb ids, TMDB, TVDB, TVMaze, AniList and
similar ids in Torznab attributes and JSON keys, and BitTorrent info hashes
(hex or base32, bare, in magnets or in URLs, keeping their case). Each becomes
a deterministic stand-in, so both engines still see the same value. The
stand-ins sit in ranges that have never been issued but still fit a 32-bit
int (`tt2` and 8 digits for IMDb, `20` and 8 digits for the others), so none
of them names a real title.

The seed then replays the scrubbed capture and fails if parsing changed (ids
and hashes are compared through their stand-ins), if any learned name is still
there in a renamer form, in text with every encoding undone, or as a pair of
its distinctive words (what a partial rename leaves behind), or if any original
id or hash survived.

That guarantee covers names learned from titles, and ids and hashes, and
nothing else:

- a name too short to rename safely (under three characters, or a segment
  under five, or three for CJK) is left as it is;
- a one-word episode title (`S01E04 Lantern 1080p`) is not learned, because
  between two markers a single word reads as a release tag as often as a name;
- a work that equals a category name in the definition (`SparkyLinux` on a
  distro tracker) is tracker vocabulary and stays, since renaming it would also
  rename the category label;
- text no title contains passes through: uploader and fansub group names,
  descriptions, category labels, and an alternate name that only appears
  elsewhere in a row or in an untrimmed body (XML feeds, pages with no rows,
  error pages);
- a body that is neither UTF-8 nor a clean round trip through its charset only
  gets the fixed spellings, and `seed` says so;
- a tracker's own release ids in row links (`/view/2179870`,
  `details.php?id=420750`, `torrents/14726011222030`) are kept, so a link still
  resolves to the real release page on that tracker. Every tracker shapes them
  differently, and some share digits with dates in the same URL, so there is
  no safe general rule for them yet.

`seed` prints a `WARNING` line for every body it keeps whole, every category
name it leaves alone and every body the word pass could not read. Read those
bodies, and skim the others, before committing. A film or series title found
there is a gap in the scrubber: fix the scrubber with a test and seed again, or
drop the definition. Never edit a fixture by hand.

## Search metrics

Every indexer call settles into one `[:mydia, :indexers, :search, :stop]`
event (`Mydia.Indexers.SearchStats.Telemetry`): searches from `search_all/2`,
including tasks the deadline killed (`outcome: :deadline`), and Cardigann
health probes (`kind: :health`). `SearchStats.Recorder` buffers them into
`indexer_search_events`; rows are pruned after 14 days. The admin Indexers
page reads `SearchStats.summary/2`, and `/metrics` (when
`MYDIA_METRICS_ENABLED=true`) exports `mydia_indexer_search_total` and
`mydia_indexer_search_duration_milliseconds`.

`engine` says which Cardigann engine served the call. Network time is only
known for the Prowlarr engine, which measures its host HTTP exchanges.

The Cardigann health check probes through the active engine. Under Prowlarr
it is one search through the adapter registered for `:cardigann`; mirror
probing and `active_link` promotion happen only on the built-in path.
