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
carried to the redirect target unchanged.

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
option: `attach_cookies/4` in `lib/mydia/indexers/cardigann_search_engine.ex`
sets `redirect: false` whenever it attaches a `Cookie`, and an unfollowed 3xx
falls through to the existing failover. Trusted-origin scoping for absolute paths
and mirror failover is tracked in issue #602.

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
