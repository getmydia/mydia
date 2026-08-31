# metadata-relay gotchas

## Subtitles: the backend is SubDL, and it needs a key

Relay subtitle search failed on every default install until 2026-08-13, from two
defects. `Mydia.Subtitles.Client.MetadataRelay` resolved its own base URL ending
in `|| ""`, unlike every other relay consumer, which uses
`Mydia.Metadata.metadata_relay_url/0` (fixed in PR #432). And the deployed relay
had no subtitle credentials, so `/api/v1/subtitles/*` answered 503 "Service not
configured".

The second was not fixed by adding OpenSubtitles credentials. OpenSubtitles is
structurally unsuited to a shared relay: downloads need a per-account JWT (an API
key alone returns `401 "missing token"`) and the download allowance is metered per
account, so one relay account would mean one daily budget for every install on
earth.

PR #436 replaced the relay's subtitle backend with SubDL. SubDL's key gates search
only, and `dl.subdl.com` archive downloads are unauthenticated, verified as HTTP
200 and byte-identical with and without the key, so downloads never touch the
2000/day allowance. The relay's OpenSubtitles client, auth and handler are
deleted. Mydia's direct `:opensubtitles` provider is deliberately retained as the
only hash-capable source.

Four things to know:

- The relay needs `SUBDL_API_KEY`, deploy field `relay_subdl_api_key` in the
  gitignored `infra/config.yaml`. Subtitle search 503s until it is set and the
  relay redeployed.
- SubDL serves ZIPs while deployed Mydia clients expect plain bytes, so the relay
  unwraps server-side and serves them from its own
  `GET /api/v1/subtitles/download/:id`. Never point clients at `dl.subdl.com`.
- Relay results score exactly 50 in `Mydia.Subtitles.calculate_score/2`, since
  SubDL carries no rating, download count or hash, so auto-download effectively
  never fires through the relay regardless of `@high_confidence_threshold`.
- `/health` returning 200 says nothing about per-service credentials. The relay
  now warns at boot and reports `subtitles_configured` on `/health` precisely
  because this ran 503ing every install for months. Before believing any
  relay-backed feature works, curl the endpoint directly.

## The cache only covered GETs

`MetadataRelay.Plug.Cache` matched only `%Plug.Conn{method: "GET"}`, so every POST
endpoint fell through uncached, silently. This went unnoticed until 2026-08-13
even though a design doc asserted that "search caching is what makes the 2000/day
allowance viable". `POST /api/v1/subtitles/search` was hitting the upstream on
every request, verified as three identical searches producing three upstream
calls.

Fixed in PR #436. The plug now caches exactly one POST, matched on a
`@cacheable_post` literal path equality rather than a prefix, keyed on the path
plus a sha256 of the canonicalised parsed body.

The relay serves other POSTs: `/crashes/report`, `/feedback` and
`/pairing/claim`. Caching any of those would silently swallow requests, and
crash-report ingestion runs its own IP rate limiter inside the route that a cache
hit would skip. Any change here must stay an exact-path match.

Three things to hold onto:

- Adding caching to a POST route requires `Plug.Parsers` to have run first, which
  it has, since the cache plug is mounted after it. An unfetched body must degrade
  to uncached, never to a shared bare key.
- Graceful degradation plus caching manufactures cache poisoning.
  `SubDL.Handler.search/1` turned upstream anomalies (a CDN interstitial, an
  unexpected shape) into `{:ok, %{"subtitles" => []}}`, meaning HTTP 200, which the
  new cache then pinned as "no subtitles for this title" for 7 days in a Redis
  shared by every install. Anomalies must return an error so the cache's
  `status in 200..299` gate skips them. Empty-but-genuine results get a 1-hour TTL
  rather than the 7-day search TTL.
- `Cache.auto_ttl/1` picks a TTL by matching substrings in the key, so a key
  containing `/search` inherits the search TTL by coincidence. Verify the TTL you
  get is the TTL you meant.

## Feedback triage state is not in the relay

The `feedback_submissions` table has `state` (`unread`, `read`, `archived`) and
`github_ref` columns, but as of 2026-08-24 every one of the 22 rows was `unread`
with `github_ref: nil`. The triage columns have never been used, because PR #395
("file issues from feedback"), which would populate `github_ref`, was never
merged.

So "no `github_ref`" tells you nothing about whether feedback was acted on.
Reconstructing triage state means checking each item against `git log` and the
current code.

The reports get fixed fast, usually before anyone files an issue. Measured across
the 19 real submissions, 15 were already shipped or already tracked, and several
landed the same morning as the report:

- badge overlap on movie posters, `73d8f610c`, about 4h after the report
- unmonitored items showing real availability, `aefeb7d84`, same morning
- Custom Formats (VFF/VFQ/VF2/MULTI), `1745bdc6f`, 8 minutes after the report

Before filing an issue from relay feedback, grep master for the fix. Filing from
the dashboard alone produces mostly duplicates of already-shipped work.
