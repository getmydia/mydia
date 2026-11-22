# Custom poster selection

Status: approved in conversation 2026-11-21. Issue #1480.

## Goal

Let an admin replace a media item's poster with one of three sources, and keep
that choice until they reset it:

1. An alternative poster from TMDB or TVDB.
2. An uploaded image.
3. An image file already sitting in the item's folder, such as the
   `poster.jpg` Jellyfin writes next to the media.

The requester wants Mydia's posters to match the ones they already curated in
Jellyfin. Success means the chosen poster shows on the web detail page, the
library grid, the dashboard rails and in the player (HTTP and p2p), and that a
metadata refresh does not undo it.

Out of scope: backdrops, logos, season and episode artwork, per-user posters,
and following later changes to a folder file (see "Folder file is copied once").

## What exists today

- The poster is `metadata.poster_path` inside the `MediaItem.metadata` blob
  (`Mydia.Media.MetadataType`). A refresh rewrites the blob, and nothing records
  a user choice.
- Every consumer builds the URL with `Mydia.Metadata.ImageUrl.poster_url/2`,
  which prefixes TMDB relative paths with the TMDB CDN and passes `http…` URLs
  through. The web reads it via `MydiaWeb.Live.Helpers.MediaImages.poster_url/2`;
  GraphQL via `MydiaWeb.Schema.Resolvers.ItemBuilder` (`posterUrl`).
- metadata-relay already serves `/tmdb/movies/:id/images`,
  `/tmdb/tv/shows/:id/images` and `/tvdb/artwork/:id`, and
  `Mydia.Metadata.fetch_images_by_ref/3` wraps them. Nothing calls it yet. No
  relay change is needed.
- Avatar upload (`Mydia.Accounts.Avatar`, `ProfileLive`) writes files under
  `<generated_media_path>/avatars/` and serves them unauthenticated at
  `/generated/avatars/…` through the endpoint's `Plug.Static`. Posters follow
  the same pattern.
- The player loads artwork only from absolute, credential-free http(s) URLs
  (`absoluteArtworkRequest` in `player/lib/core/sources/mydia/mydia_source.dart`).
- The p2p local proxy forwards only `/hls`, `/direct`, `/download` and
  `/peerfile` (`player/lib/core/p2p/media_route.dart`), dispatched server-side in
  `Mydia.P2p.Server.handle_hls_stream/3` by session id prefix.

## Data model

A migration adds `media_items.poster_override`, type `:text`, nullable, with
no default. The filename uses a real timestamp checked against every remote
branch (AGENTS.md, "Migration filenames"). Both adapters handle it as a plain
`add`.

The column holds one of:

- a provider poster: a TMDB relative path (`/abc.jpg`) or a TVDB URL, the same
  values `metadata.poster_path` holds;
- a Mydia-hosted path: `/generated/posters/<media_item_id>-<sha8>.<ext>`, where
  `sha8` is the first 8 hex characters of the image's SHA-256 and `ext` is
  `jpg`, `png` or `webp`.

`nil` means "use the provider default".

### Why a separate column

The override lives outside `metadata`, so the refresh pipeline never sees it,
and surviving a refresh needs no code in the refresh path. Writing into
`metadata.poster_path` behind a pin flag would make every refresh and merge
path responsible for honoring the flag, and would lose the provider default
that reset needs. A general images table is more schema than one poster needs.

## Resolution

`Mydia.Media.Posters.effective_path/1` returns `poster_override` when set,
otherwise `metadata.poster_path`. Every place that reads an item's poster
calls it: `MediaImages.poster_url/2`, `ItemBuilder`, and the remaining media-item
poster reads found by grepping `poster_path` under `lib/` (collections, library
search, calendar, dashboard, playback stats, plugin shelves). Places that read a
raw provider search result (Discover, add-media, requests, import lists) are
not media items and stay as they are.

`ImageUrl.image_url/2` gains a clause that passes a `"/generated/" <> _` path
through unchanged instead of treating it as a TMDB path.

## Writes: `Mydia.Media.Posters`

| Function | Effect |
| --- | --- |
| `set_provider_poster(scope, item, path)` | Stores the provider path. Deletes a previous hosted file. |
| `set_uploaded_poster(scope, item, binary)` | Validates, writes `/generated/posters/<id>-<sha8>.<ext>`, stores it, deletes the previous hosted file. |
| `set_poster_from_library_file(scope, item, library_path_id, rel_path)` | Validates the path, reads the bytes through `Mydia.Storage`, then behaves as `set_uploaded_poster`. |
| `reset_poster(scope, item)` | Sets the override to nil and deletes a hosted file. |
| `list_library_poster_candidates(item)` | Image files in the item's folders, `poster.*`, `folder.*` and `cover.*` first. |

Every write takes a `Mydia.Accounts.Scope` first and refuses a user who fails
`can_update_media?` (`{:error, :unauthorized}`) or whose access restriction
excludes the item (`{:error, :restricted}`). A scope with no user is the
system and may write.

Each write goes through a changeset on `poster_override` only and records the
usual `media_item.updated` event. Other open detail pages of the item refresh;
library grids and dashboard rails show the new poster on their next load.
Deleting a media item deletes its hosted poster.

### Validation

- Format by magic bytes, not by extension: JPEG, PNG or WebP. The stored
  extension comes from the detected format.
- 10 MB cap, matched by `allow_upload`'s `max_file_size`.
- A library file must resolve inside one of the item's folders: a movie's
  media file directory, or a TV show's root (not season folders). Absolute
  paths, `..` segments and symlinks that leave the folder are rejected.
  Resolution goes through `Mydia.Storage`, so S3-backed libraries work.

### Folder file is copied once

Picking a folder file copies its bytes into the poster store. Later changes
to that file are not followed. One serving path covers uploads and folder
files, it works the same on S3 libraries, and the poster survives the source
file being renamed, moved or deleted. A user who changes the poster in
Jellyfin re-selects it in Mydia.

## Web UI

- The poster on the media detail page gets a pencil button, shown on hover
  and always visible on touch. It uses the same admin gate as Fix Match.
- The button opens `PosterPickerModal`, a LiveComponent in
  `lib/mydia_web/live/media_live/show/poster_picker.ex`. It owns its upload
  and events, so `show.ex` only mounts it. It has three daisyUI `tabs`:
  - **Browse.** `start_async` calls `Metadata.fetch_images_by_ref/3` for the
    item's TMDB ref, and its TVDB ref when it has one. Results show as a poster
    grid labeled with source and language, best rated first, with the current
    poster marked. A relay failure shows an inline alert with a retry button,
    and the other tabs keep working.
  - **Upload.** `allow_upload(:poster, accept: ~w(.jpg .jpeg .png .webp),
    max_file_size: 10_000_000)` with a live preview before saving.
  - **From folder.** Lists `list_library_poster_candidates/1` with thumbnails
    from an authenticated preview route
    (`/media/:id/poster-candidates/:library_path_id/*path`) that streams the
    candidate through `Mydia.Storage`. Any user who may edit media gets
    thumbnails; the controller checks `can_update_media?` itself.
- The footer has "Reset to default" (only when an override is set), Cancel
  and Save.
- Strings go through `gettext`. DOM ids for tests: `#poster-edit-button`,
  `#poster-picker`, `#poster-tab-browse`, `#poster-tab-upload`,
  `#poster-tab-folder`, `#poster-reset`, `#poster-save`.

## Player and p2p delivery

GraphQL has no schema change. `posterUrl` stays a `String`, so the Rust SDL
parity gate is untouched. A provider override arrives as an absolute TMDB or
TVDB URL, as today. A hosted override arrives as the server-relative
`/generated/posters/<file>`.

`MydiaSource.artwork` keeps `absoluteArtworkRequest` for absolute URLs. A path
starting with `/generated/posters/` is resolved by connection mode:

- **HTTP**: `serverUrl + path`, no headers, since `/generated` is public static.
  The web player served at `/player` takes this path.
- **p2p**: `MediaRoutes.artwork(base, file)` builds `$base/artwork/<file>`.
  `MediaRoutes.resolve` maps it to
  `MediaRouteMatch(sessionId: 'artwork:<file>', path: 'file', kind: MediaRouteKind.hls)`,
  a bounded single response, so the native loopback proxy and the Service
  Worker both serve it with no new code path. The source takes a proxy hold
  the way downloads do (`_holdsProxy`, released in `dispose`).

Any other relative path still returns null. `cacheKey` includes the sha'd
filename, so a new poster is a cache miss.

`Mydia.P2p.Server.handle_hls_stream/3` gains an `"artwork:"` branch after its
token check. The filename must match
`^[0-9a-f-]+-[0-9a-f]{8}\.(jpg|png|webp)$` and resolve inside the posters
directory. Otherwise it answers 404. Valid files go out through
`stream_hls_file`.

### Compatibility window

A player released before this change drops the relative URL and shows its
placeholder for items with a hosted poster, until it updates. Provider-picked
posters work on every player version.

## Error handling

- Relay failure in Browse: inline alert plus retry. Nothing is written.
- Rejected upload or folder file: the reason shows in the modal (format, size,
  outside the item's folder). Nothing is written.
- A hosted file that is missing on disk: the static route 404s, and web and
  player fall back to their placeholder. Reset clears it.
- File write failure: the transaction is not committed, the previous override
  stays, and a flash explains it.

## Testing

`Mydia.P2p.Server` (21 fixes in six months, 3 in `handle_hls_stream`) and
`MediaLive.Show` (21 fixes, the latest three days ago) are bug magnets.
That's why the picker gets its own module and the p2p branch stays small.

- **`Posters` (DataCase)**: each setter changes `effective_path/1`; reset clears
  the override and deletes the hosted file; replacing a hosted poster deletes
  the old file; a metadata refresh keeps the override; bad magic bytes and
  oversize files are rejected; `..`, absolute paths and escaping symlinks are
  rejected; a copy from an S3 library works through the `Mydia.Storage` double.
- **`ImageUrl`, `MediaImages`, `ItemBuilder`**: `/generated/` passthrough,
  override precedence, `posterUrl` for each override kind.
- **p2p**: extend `test/mydia/p2p/server_storage_stream_test.exs` with
  `test/support/recording_p2p_nif.ex`. A valid `artwork:` name streams the file,
  a malformed or traversal name gets 404, a missing or bad token gets 401.
- **LiveView**: the pencil is admin-only; Browse lists relay images (Bypass)
  and saves a selection; Upload through `file_input`/`render_upload`; the From
  folder tab lists candidates; Reset; a relay failure shows the alert.
- **Player**: `MediaRoutes.resolve` maps `/artwork/<file>`;
  `MydiaSource.artwork` builds the HTTP and proxy URLs and returns null for
  other relative paths, scripted with `ScriptedMydiaTransport`.
- Fixtures use invented titles only.
