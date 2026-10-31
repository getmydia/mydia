# Private trackers: roadmap

Status: approved design, 2026-10-30. Each numbered spec below is planned and
shipped separately (one or two PRs each).

## Where Mydia stands

Already in place on `origin/master` (915c39a0a):

- Cardigann login: `cookie`, `get`, `post` and `form` methods, `selectorinputs`,
  `getselectorinputs`, `submitpath`, image captcha and 2FA challenges that pause
  for a person, stored sessions with re-login on logout, and `needs_login`
  (`lib/mydia/indexers/README.md`, "Cardigann login").
- The opt-in Prowlarr-based WASM engine.
- Import hardlinks first and never consumes the source of a seeding client
  (`ClientRemoval.import_consumes_source?/1`).
- Remove After Import waits for seed-aware clients to report paused or completed.
- `Client.Helpers.redact_url/1` strips `passkey`, `torrent_pass`, `rsskey` and
  similar; `Indexers.RateLimiter` rate-limits indexer queries.

Missing:

- No adapter keeps a tracker's minimum ratio, minimum seed time or volume
  factors. Prowlarr's JSON (`minimumRatio`, `minimumSeedTime`,
  `downloadVolumeFactor`, `uploadVolumeFactor`, `indexerFlags`) and the WASM
  engine's `MinimumRatio`/`MinimumSeedTime` are dropped. Volume factors are read
  only by the parity tooling.
- Nothing stops removal before a tracker's seeding rules are met. rqbit and
  rTorrent are removed right after import when Remove After Import is on.
- No private-tracker journey is tested end to end, and
  `docs/using/how-to/cardigann-indexers.md` still warns that captcha, selector
  inputs and submit paths are unimplemented, which is no longer true.
- Download URLs reach the DOM, LiveView payloads, one details modal and a grab
  event unredacted.

## Decisions

- All indexer paths count equally: built-in Cardigann, the WASM engine, and
  external Prowlarr, Jackett and Newznab feed one shared set of tracker terms.
- Seeding rules are enforced both ways: Mydia pushes per-torrent limits into
  clients that accept them and refuses automatic removal until the rules are met.
- Freeleech is shown and is a ranking preference. There is no "freeleech only"
  limit.
- Login is proven with synthetic trackers in tests. No real accounts are used.

## Roadmap

| # | Spec | Depends on | Outcome |
|---|---|---|---|
| 0 | Tracker terms | none | Every adapter fills ratio, seed time, volume factors and the private flag; terms are frozen on the download at grab; per-tracker overrides in layered config |
| 1 | Seeding guard and client limits | 0 | No automatic removal before the terms are met, on any client; limits pushed to qBittorrent and Transmission |
| 2 | Freeleech | 0 | Badges in search and a `freeleech_preference` profile setting |
| 3 | Login hardening | none | Synthetic private trackers cover full journeys on both engines; docs rewritten |
| 4 | Etiquette audit | 0 | Download URLs never leave the server unredacted; per-tracker query and grab caps |

Specs 0 and 3 can run in parallel.

## Spec 0: Tracker terms

Terms belong to the tracker, not to the Mydia indexer: one Prowlarr or Jackett
connection fronts many trackers. The tracker is identified by the name each
result already carries in `SearchResult.indexer`.

### Data

- New struct `Mydia.Indexers.Structs.TrackerTerms`: `private?`,
  `minimum_ratio` (float), `minimum_seed_time` (seconds),
  `download_volume_factor`, `upload_volume_factor`. Every field may be nil,
  meaning unknown.
- `SearchResult` gains `terms: TrackerTerms.t() | nil`.
- Adapters:
  - Prowlarr: `minimumRatio`, `minimumSeedTime`, `downloadVolumeFactor`,
    `uploadVolumeFactor`, and the indexer's privacy. As built: Prowlarr's
    search JSON (`ReleaseResource.cs`) has none of the four, only
    `indexerFlags`, so the factors come from the flags (`freeleech` 0,
    `halfleech` 0.5, `neutralleech` 0 both ways, `doubleupload` upload 2),
    the minimums stay unknown, and privacy comes from `GET /api/v1/indexer`,
    cached per connection for an hour.
  - Jackett and Newznab: the matching `torznab:attr` elements. As built:
    neither says whether the tracker is private, so `private?` is unknown
    there unless an override sets it.
  - Built-in Cardigann: the definition's `downloadvolumefactor` and
    `uploadvolumefactor` fields, and `private?` from the definition's `type`
    (`private` and `semi-private` are private).
  - WASM engine: what `native/cardigann_guest/exports/EngineImpl.cs` already
    emits.
- At grab, the effective terms (overrides applied) are written to
  `Download.metadata["tracker_terms"]`. No migration. A later override never
  changes the rules of a torrent already seeding.

### Overrides

- New top-level `tracker_rules` list in the layered config (YAML, env, and the
  DB overlay edited from the admin UI): `tracker` (matched case-insensitively
  against `SearchResult.indexer`), `seed_ratio`, `seed_time`, `private`. Spec 4
  adds `grab_limit` and `query_limit` to the same entry.
- Precedence per field: override, then the tracker's value for that release,
  then nil.
- As built: `seed_time` is in minutes (the Prowlarr and *arr convention), and
  database overrides live in a `tracker_rule_configs` table that shadows a
  YAML or env rule for the same tracker, the path-mappings pattern. Recently
  seen trackers come from a small `tracker_sightings` table (one row per
  tracker) written from `search_all/2`.
- The admin Indexers page lists trackers seen in recent results with their
  effective terms and an edit action, and flags overrides that matched nothing
  in 30 days (the usual cause is a tracker renamed in Prowlarr).

### Edges

- The WASM engine falling back to the built-in engine can change which terms a
  tracker reports. Overrides apply to both.

### Tests

- Per-adapter fixtures carrying the attributes.
- A precedence table test.
- Terms are frozen on `Download` at grab and unaffected by a later override.

## Spec 1: Seeding guard and client limits

### Rule

A download's terms are met when its ratio is at least `minimum_ratio` or it has
seeded at least `minimum_seed_time`, whichever comes first (the *arr
convention). With only one of the two set, that one decides.

- No terms and not private: behavior unchanged.
- Private with no known ratio or seed time: never removed automatically.
  Keeping a file is the safe wrong answer.

### Guard

- `ClientRemoval.terms_met?/2` runs before the existing state check in
  `maybe_remove_after_import/1` and `finish_pending_removal/2`, for
  qBittorrent, Transmission, rTorrent and rqbit; SABnzbd, NZBGet, debrid,
  blackhole and unknown types are skipped.
  A guarded row returns `:still_seeding` and stays pending. rTorrent was
  already seed-aware (it waited for paused or completed); rqbit was removed
  right after import. `maybe_remove_after_import/1`
  also returns `:still_seeding`, and `MediaImport` keeps the row pending.
- `DownloadStatus` gains `seeding_time` (seconds): qBittorrent `seeding_time`,
  Transmission `secondsSeeding`, otherwise time since the client's
  `completed_at`, falling back to `Download.completed_at`.
  As built: the wall-clock fallback is used only while the client reports
  the torrent as seeding, so a paused, stopped or missing torrent never meets
  a seed time goal from time it did not seed.
  For rTorrent and rqbit, which report no seed time, `DownloadMonitor`
  accumulates the time it observes the torrent seeding in
  `Download.metadata["observed_seeding"]` (steps capped at three cron
  intervals), which stands in for the reported value.
- Manual removal (queue delete, `Removal`, deleting media together with its
  download) stays possible while guarded. The confirm dialog names the tracker,
  the required and current ratio and seed time, and says that removing now
  risks a hit-and-run.
  As built: the dialogs are the Downloads page cancel and clear confirms and
  the media page cancel dialog; `Removal` itself is unchanged and unguarded.
  Deleting a media item never touches the client (its download rows cascade
  away and the torrent keeps seeding), so it carries no warning. Batch delete
  and Clear all completed carry none either.

### Pushed limits

At grab, best effort; a failure is logged and the guard still applies.

- qBittorrent: `setShareLimits` with `ratioLimit` and `seedingTimeLimit`
  (minutes). As built: an optional `set_share_limits/3` adapter
  callback; minutes round up, an unset limit is `-1` (none) rather than `-2`
  (global), and `inactiveSeedingTimeLimit` is `-2`, which qBittorrent 4.6+
  requires.
- Transmission: `seedRatioLimit` with `seedRatioMode=1`. Transmission has no
  total seed time limit, so time relies on the guard.
- rTorrent and rqbit: nothing pushed; the guard alone.

### Visibility

- The downloads queue and history show a seeding chip ("0.42 / 1.0 · 1d / 3d",
  or "Seeding goal met").
- The download client admin page says which clients receive limits.

### Tests

- `terms_met?/2` truth table: ratio only, time only, both, neither, private
  without terms.
- Bypass tests for each adapter's share-limit call.
- Removal paths: guarded, unguarded, private without terms, rqbit.
- LiveView test of the removal warning.

## Spec 2: Freeleech

Freeleech is a property of the release, like seeders, not of the file. It enters
`SearchScorer`'s combined score beside `availability_score` and `title_bonus`,
never the file-scale `score_quality/3` or `QualityProfile.score_media_file/2`.
So it cannot move `upgrade_until_score`, create a file violation or trigger an
upgrade.

- Quality profile key `freeleech_preference`: `ignore` (default) or `prefer`.
  It is a preference: added to the limits-vs-preferences table in
  `lib/mydia/indexers/README.md` and classified in `ProfileLimits`, whose test
  fails until it is.
- `freeleech_bonus = (1 - download_volume_factor) * 10` when `prefer`; 0 when
  the factor is unknown or the setting is `ignore`. Full freeleech adds 10, half
  adds 5, the same scale as the title bonus: it breaks ties among comparable
  releases and does not lift a 720p over a 1080p.
- The upload factor is shown, not scored.
- `ReleaseRanker.explain/2` lists the bonus in the breakdown, so the manual
  search dialog shows it without a second scoring path.
- Manual search rows show `FL`, `50%` and `2x up` badges, and a private icon
  from `terms.private?`.

Tests: scorer cases (full, half, unknown, `ignore`), the bonus never changes
`score_quality/3`, the `ProfileLimits` classification test, and the explain
breakdown.

## Spec 3: Login hardening

Unit tests cover the login pieces; nothing runs a whole private-tracker journey.

### Synthetic trackers

Three Bypass-backed fictional trackers, each with a definition shaped like a real
upstream family:

- UNIT3D-style: API key in the query, JSON search, `.torrent` download that
  needs the key.
- Gazelle-style: form login with a CSRF token from `selectorinputs`, cookie
  session, HTML search, passkey in the download URL.
- Form with captcha and 2FA: a `Challenge` pauses the login, the submit goes to
  a separate `submitpath`, and the session expires partway through.

### Journeys, on the built-in and the WASM engine

1. Configure, log in (including the challenge round trip from the Indexers
   page), search.
2. Results carry `terms` from Spec 0.
3. Grab fetches the `.torrent` with the session or key; `ensure_trackers/1` and
   `ensure_torrent_trackers/1` leave it untouched; the passkey appears in no log
   or history row.
4. The session expires: the next search re-logs in once. A captcha on re-login
   moves the indexer to `needs_login`.

Gaps found are fixed in this spec. The first thing to check is whether the WASM
engine can surface a `Challenge`; if it cannot, the UI says that captcha logins
need the built-in engine instead of failing silently.

### Compatibility and docs

- Run `mix mydia.cardigann_compat --type private` across the upstream catalogue
  and publish supported and unsupported login-method counts in the docs.
- Replace the warning in `docs/using/how-to/cardigann-indexers.md` with a
  private trackers how-to: cookie, form and API-key setup, captcha and 2FA,
  seeding rules, freeleech, per-tracker overrides, and a request for user
  reports, since real-account verification comes from users.

## Spec 4: Etiquette audit

### Known leaks on 915c39a0a

- `lib/mydia_web/live/media_live/show/modals.ex:749` renders
  `download_details.download_url` raw.
- `phx-value-download-url` / `phx-value-download_url` carry the full URL in
  `manual_search_components.ex` (two places) and `search_live/index.html.heex`
  (three places), putting passkeys in the DOM and LiveView payloads.
- `Grabber` broadcasts `{:grab_completed, %{download_url: ...}}`.

### Changes

1. Credentials stay on the server: search rows send a result reference (the
   `guid`, or a key into the search session's results) and the LiveView looks
   the URL up.
2. Every rendered download URL (download details, history, blocklist, activity
   feed, GraphQL `downloadUrl`) goes through `redact_url/1`. GraphQL returns the
   redacted form.
3. Events and logs carry the download id, not the URL. A static test,
   `no_raw_download_url_test.exs` (modeled on `no_varchar_columns_test.exs`),
   fails on any `Logger` call or HEEx interpolation of `download_url` not passed
   through `redact_url/1`.
4. `tracker_rules` gains `grab_limit` and `query_limit` (per rolling 24 hours).
   The query cap reuses `Indexers.RateLimiter`; the grab cap counts `Download`
   rows for the tracker. At a cap, automatic search skips the tracker and manual
   search shows the reason ("daily grab limit reached (5/5)"). Both are optional,
   since Prowlarr may already enforce them.

Tests: LiveView pages render no `passkey=` or `torrent_pass=`, the static test,
query cap and grab cap including the automatic-search skip.
