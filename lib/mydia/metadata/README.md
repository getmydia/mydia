# Metadata providers: what TVDB and TMDB actually send

Everything here was measured against the live relay rather than inferred from
provider documentation. Where a date is given, that is when it was verified.

## The relay base URL is relay.mydia.dev

The real metadata-relay is `https://relay.mydia.dev`, from
`Mydia.Metadata.metadata_relay_url/0` (the `METADATA_RELAY_URL` env var, with that
default). It has no `/tmdb` suffix; endpoint paths supply their own `/tmdb/...`
prefix.

Ten docstrings in `lib/mydia/metadata.ex` still say
`https://metadata-relay.dorninger.co/tmdb`. That host is no longer the relay. It
answers with an unrelated FastAPI service that returns plausible TMDB detail
JSON, honours `language`, and silently ignores `append_to_response` while
returning HTTP 200. Its `/health` gives `{"detail":"Not Found"}` instead of the
relay's `{"status":"ok","service":"metadata-relay",...}`.

Testing against it will convince you that `append_to_response` is broken
relay-wide and that `recommended_tmdb_ids` is empty for every install. Both are
false. Against relay.mydia.dev, append works for `credits`, `keywords`, `images`,
`videos` and `recommendations`, on movies and TV alike.

The docstrings predate the move to mydia.dev and nothing tests them, since no
test file declares `doctest Mydia.Metadata`. Confirm the base URL against
`metadata_relay_url/0` before curling it, and check `/health` first as a cheap
identity probe. When probing through Cloudflare, add a random cache-buster param,
or `cf-cache-status: HIT` will serve your own earlier request back to you.

## append_to_response covers more than you think

TMDB's `recommendations` (similar titles), `release_dates` (movie certification)
and `content_ratings` (TV certification) need no new relay endpoint. They are
fetched the same way `credits`, `videos` and `keywords` already are, through the
`append_to_response` query param on the existing `/movie/{id}` and `/tv/{id}`
detail calls.

`MetadataRelay.TMDB.Handler.get_movie/2` and `get_tv_show/2` forward `params`
straight to TMDB with no allowlist (`Client.get("/movie/#{id}", params: params)`),
and the backend already sends `append_to_response` as one of those params
(`lib/mydia/metadata/provider/relay.ex:238-244`). Extending the append list in the
three backend call sites is sufficient. Those sites are `lib/mydia/media/refresh.ex`,
`lib/mydia/library/metadata_enricher.ex` and `lib/mydia/media/provider_switch.ex`,
all three of which duplicated the same literal
`["credits", "images", "videos", "keywords"]` list.

Movies and TV use different resource names for certification: `release_dates` for
movies, with a nested per-country list each carrying its own `certification`, and
`content_ratings` for TV, flat per-country with `rating`. Both ride the same
mechanism and are parsed differently.

This was discovered while scoping the player detail-page redesign on 2026-08-05.
The initial assumption was that "similar movies" needed a full new relay endpoint
plus a backend fetch and storage layer, which would have been the most expensive
part of the feature. Before proposing any new relay endpoint for a TMDB
detail-page sub-resource, check TMDB's `append_to_response` docs first. Most
detail-adjacent resources are appendable.

## TVDB extended carries no episodeCount

TVDB's `/series/{id}/extended` season records carry only these keys: `companies`,
`id`, `image`, `imageType`, `lastUpdated`, `nameTranslations`, `number`,
`overviewTranslations`, `seriesId`, `type`. There is no `episodeCount`. Verified
2026-08-17 against `relay.mydia.dev/tvdb/series/331753/extended` (Black Clover).

`Relay.transform_tvdb_seasons/2` writes
`"episode_count" => s["episodeCount"] || 0` into stored `SeasonInfo`, so every
TVDB show's stored `episode_count` is 0 in production. Confirmed on galactica,
where Black Clover's stored seasons JSON reads `"episode_count":0` for both
seasons.

Real per-season counts require fetching `/tvdb/seasons/{season_id}/extended` per
season and counting `data["episodes"]`. Episode records there carry the
ordering's own coordinates, not the aired ones. DVD season 2 returns
`id=6832458 seasonNumber=2 number=1 absoluteNumber=52`, while official ordering
returns that same episode as season 1 number 52. `absoluteNumber` is stable
across orderings, which is what makes a reorder mappable.

This surfaced because a test fixture contained fabricated `episodeCount` values.
The test passed against data TVDB never sends, and `available_orderings/1`
silently returned all zeros on real payloads. Build provider fixtures from
captured real responses.

## TVDB orderings disagree only on specials

Measured live for Black Clover (TVDB 331753) on 2026-08-19:

| ordering | numbered episodes | specials | season layout |
|---|---|---|---|
| official | 170 | 19 | 1x170 |
| dvd | 170 | 27 | 51, 51, 52, 16 |
| absolute | 170 | 0 | 1x170 |

The 170 numbered episode ids are identical across all three orderings, with zero
difference in either direction. Every disagreement is in season 0. Two orderings
also routinely assign the same `(0, n)` coordinates to different episodes: DVD
hands (0,26) and (0,27) to episodes that are not the official ordering's
(0,26)/(0,27), whose ids the DVD ordering does not list at all.

Any completeness check over "every episode" therefore refuses every switch over a
disagreement about specials, and remapping specials anyway collides on the
`(media_item_id, season_number, episode_number)` unique index. An ordering with
zero specials blocks every show that has one.

Scope ordering work to numbered seasons and leave specials where they are on both
sides. `SeasonOrder`'s `@specials_season` and `fetch_alternative_counts/3` both
draw that line.

## TVDB has no popularity, and puts years in reboot titles

Two traits that shape TV match scoring in `Mydia.Library.MetadataMatcher`.

TVDB search results never populate `popularity`. It is a TMDB field, and
`parse_tvdb_search_result/1` in `lib/mydia/metadata/provider/relay.ex` does not
set it, so `popularity_score/1` contributes exactly 0.0 for every TV match. Any
scoring term relying on popularity to break a tie is dead weight on the TV path.
Verified against relay.mydia.dev on 2026-08-18.

TVDB also disambiguates same-title reboots by appending the premiere year to the
name. The 1977 original is `"Passe-Partout"` (id 117091) and the 2019 revival is
`"Passe-Partout (2019)"` (id 356390), and both come back from one search. A title
comparison that does not strip a trailing `(YYYY)` reads that suffix as a
derivative or spin-off title and scores the correct reboot down for carrying the
marker that identifies it.

Together these left the year as the only discriminator on the TV path, and it was
too weak, which auto-filed the 2019 revival as the 1977 original on galactica.
When touching `calculate_tv_match_score/2`, do not add signals depending on
popularity for TV, and compare against the year-stripped title
(`split_title_year/1`). Movies have neither trait, since TMDB sends popularity
and does not put years in titles.

## TVDB translation language codes

TVDB's `/tvdb/.../extended?meta=translations` bundles key each translation by a
language code. Measured across 5 popular shows in June 2026 via the relay:

- Almost every language uses the ISO 639-2/T three-letter code: `eng`, `spa`,
  `fra`, `deu`, `ita`, `jpn`, `kor`, `rus`, `zho`. Note `deu` rather than `ger`
  and `zho` rather than `chi`, the terminological variants.
- Portuguese is the exception, appearing as both `por` (639-2) and `pt` (639-1),
  and some shows carry only one. Frieren (tvdb 424536) had only `pt`.
  Traditional Chinese shows up as `zhtw`.
- A TVDB series' own `original_language` field is the three-letter code (`jpn`,
  `eng`), while TMDB-sourced shows store the two-letter form (`ja`, `en`).

Map each configured language to both its three-letter and two-letter candidates
rather than a single code. See `Mydia.Metadata.LanguageCode.tvdb_candidates/1`.
The relay does not proxy `/tvdb/languages`, so there is no authoritative list
endpoint; validate against real show bundles.

## Metadata.genres/1 returns atom-keyed maps

`Mydia.Metadata.genres/1` returns `{:ok, [%{id: integer(), name: String.t()}]}`.
`Relay.fetch_genres/2` re-maps the TMDB payload into atom-keyed maps, so the raw
`g["id"]` and `g["name"]` shape does not survive.

Every other TMDB payload in the codebase is string-keyed, so reaching for
`genre["id"]` is the natural reflex. It returns nil for every entry rather than
raising, which turns a genre lookup into a silent empty result.

Use `genre.id` and `genre.name`. When mapping TMDB `genre_ids` to names, build the
index as `Map.new(genres, &{&1.id, &1.name})`.

## plex.tv Home switching keys on uuid

`GET https://plex.tv/api/v2/home/users` returns each Home account with both an
`id` (numeric) and a `uuid` (hex string). The profile-switch endpoint that mints a
per-user token accepts only the uuid:

```
POST /api/v2/home/users/14861644/switch          -> 404 {"errors": [...]}
POST /api/v2/home/users/2ed8d606cadd57f0/switch  -> 201 + authToken
POST /api/home/users/14861644/switch   (v1, XML) -> 201   # v1 does take the id
```

Verified live 2026-08-12, fixed in PR #427. `Home.parse_user/1` stores the uuid in
`plex_account_id`.

Two related traps in the same payload. `username` is null for managed and guest
profiles, where only `title` is set, and on a typical household that is most of
the profiles, so anything matching on username must fall back to title. And a
successful switch answers 201 rather than 200, so status checks need
`status in 200..299`.

The failure was silent for a long time, because `seed_links/2` logs "could not
mint a per-user token" and skips the profile. The symptom was an empty
`media_server_user_links` table rather than an error anywhere.
