# Sources: Mydia, Plex, Stash and Jellyfin

The player browses and plays from more than one kind of server. This
package is the layer that makes them look alike to the screens.

## Model

A `ProviderAccount` is a credential (a plex.tv sign-in, a Stash API key,
a Jellyfin user's token, the Mydia login). A `SourceProfile` is who acts
with it: the owner, or for Plex each Plex
Home user. The admin is always profile `owner`; other Home users use their
plex.tv uuid. A Jellyfin account is one
user on one server; its profile id is the Jellyfin user id, which every
per-user call sends as `userId`. A `SourceServer` is what the viewer browses. A
`Source` is one of each, and `SourceId` (`account:profile:server`) is what
routes, caches and memories key on. Ids are `[A-Za-z0-9_-]+`; the store
refuses anything else.

The Mydia login that predates this layer is migrated at startup into an
ordinary account (`core/migration/`), and its stored data moves to that
account's `SourceId`. There is no fixed source id: every Mydia server is a
stored account with a `MydiaSource`. The legacy screens and the legacy
GraphQL client still serve one of them, the bound instance
(`boundMydiaProvider` in `mydia/bound_mydia.dart`): the migrated account while
it exists, else the first Mydia added. That instance keeps the unprefixed
routes, so its `/s/<id>` root redirects to `/`.

The source switcher groups servers by account, with a caption per account.

## Storage

- Accounts, profiles and servers: Hive box `source_accounts`, one JSON
  record per account (`HiveSourceStore`).
- Tokens: `AuthStorage` (secure storage) under the account's namespace,
  `source/<accountId>/account_token` (plex.tv admin token, Stash API key,
  Jellyfin access token),
  `source/<accountId>/<profileId>/user_token` (the active Plex Home user's
  plex.tv token; the owner falls back to the account token) and
  `source/<accountId>/<profileId>/<serverId>/token` (`SourceSecrets`).
  A record is written only after its tokens.

## Connections

Every request reads `SourceConnection.base()` at call time.
`RacingConnection` probes every known connection (Plex's from plex.tv,
Jellyfin's entered URL and LAN address) with an identity request (3s,
relay 6s) and uses the first that answers with
the expected server id, moving to a better-ranked one when it answers
(local, then remote, then relay; HTTPS before HTTP; plain HTTP only on the
LAN). It looks again on resume, on a network change, after a failed
request and every 15 minutes, re-reading `connections[]` from plex.tv.
A stream already playing keeps the URL it opened with.

## Plex Home

A Plex account has one active Home user (`activeProfileId`). Its record
lists every Home user as a profile, refreshed at sign-in and when the
switch-user sheet opens, but stores only the active user's servers and
tokens. `chosenServerIds` remembers which servers the viewer picked; each
user is shown the ones plex.tv lists for them.

`PlexHomeSwitcher.switchTo` asks plex.tv every time
(`POST /api/v2/home/users/{uuid}/switch`, `pin=` for a protected user), so
a PIN is checked on every switch and none is stored. It writes the new
user's tokens, then the record (inside the records write queue), then
deletes the previous user's tokens; a failed write deletes the new tokens
and keeps the old record. Switching to the already-active user deletes the
tokens of servers they no longer see. Rediscovery reads the active user's
token, so it sees that user's servers. Signing in again resets the account
to the owner.

`SourceSecrets.deleteAll` deletes server tokens for every profile crossed
with the chosen and stored server ids, so an inactive user's leftovers go
when the account is removed.

## Mydia servers

Every Mydia server is an ordinary account of `SourceKind.mydia` in
`HiveSourceStore`: account `m<instanceId>`, profile `owner`, server
`<instanceId>`, so its `SourceId` is `m<instanceId>:owner:<instanceId>`. An
`instanceId` that fails `isValidSourceIdComponent` is refused at add time.
There is no fixed source id and no distinguished first server.

All of an instance's credentials are one JSON secret (`MydiaCredentials`) at
`source/m<instanceId>/account_token`: access, device and media tokens, plus
the server URL or the iroh node address. It is written before the account
record.

The instance id comes from the first of: the pairing QR, the claim result,
`serverCompatibility { instanceId }`, the iroh node id (`n<nodeId>`, for a
paired server that sent none), and for a URL login the first 16 hex
characters of the SHA-256 of the normalized URL (`u<hash>`). Two
consequences: a URL account on a server that never enabled remote access can
appear twice if the same server is later paired, and a hashed id gets no
wrong-instance check. A reinstalled server has new keys and rejects the
stored token, which flags the account `needsReauth` through the 401 path.

Add one from Add server, Mydia (`/sources/add/mydia`), by claim code, QR or
URL and password (`saveMydiaServer`). Adding an existing instance again signs
it in again: its credentials are replaced and `needsReauth` clears. Remove one
with `removeMydiaInstance`: it unwatches the peer, deletes the secrets and the
record, and changes nothing on the server (`revokeDevice` is not called,
because pairing never learns the server-side device id). Every Mydia server
must run a build with the GraphQL fields the player asks for
(`serverCompatibility.instanceId`, sortable lists and `playlistMode`); an
older server answers with GraphQL errors.

### Requests

`MydiaClient` (`mydia/mydia_client.dart`) is one instance's requests. It
sends GraphQL over a `MydiaGqlTransport`, an HTTP POST to `/api/graphql` or
`P2pService.sendGraphQLRequest` for a paired instance. It owns that account's
token refresh (the device token for a new access token, and the media token,
which it renews within an hour of expiry), reports a refused refresh as
`needsReauth` through its status, and builds media URLs. The documents are the
generated `documentNode...` constants, so the schema guard checks them. Status
is per source: there is no global auth state.

HLS uses `playlistMode: FULL` and `SimplePlaybackTransport`, with the bearer
token on the stream. Over p2p the local proxy serves an instance at
`/t/<accountId>/...`, and the bound instance also keeps the bare path. The
player screen lets go of its targets with `MediaProxy.release(owner)`, which
releases every target that owner took.

### Startup migration

The single-server sign-in that predates this layer is migrated at startup
(`core/migration/`, `migrateLegacyMydia`). It reads `auth_token`,
`server_url`, `instance_id`, `server_node_addr` and the `pairing_*` keys and
stores them as an ordinary account. It reuses an account already stored when
its instance id, p2p node id or normalized URL matches, refreshing that
account's tokens instead of adding a second server. A sign-in that names no
usable server is skipped.

Data recorded under the pre-account source id (`preAccountSourceId`, the old
`'mydia'`) then moves to the account's `SourceId`: downloads (a record with no
`sourceId` counts as pre-account), offline progress (re-keyed to
`<sourceId>|<id>`), the All servers choices, the active source and the
persisted cast session. The old `mydia/*` cache entries are purged.
`HiveLegacyDataRewriter` does this and every step is idempotent. Records with
a missing `sourceId` are kept and treated as pre-account until migrated, and
the orphan download sweep never deletes them.

The `legacy_instance_id` marker is written last, so a run that died earlier
starts over, and a run after the marker repeats only the data steps. The
migration only reads the legacy keys: nothing deletes them before the stage
that retires `AuthService` and the pairing storage, which also keeps a
downgrade working.

### The bound instance

Until the legacy screens and services move to sources, one instance serves
them. `boundMydiaProvider` (`mydia/bound_mydia.dart`) is the account named by
`legacy_instance_id` while that account exists, else the first Mydia account
added. The legacy GraphQL client is a `TransportLink` over its `MydiaClient`,
so those screens share its token and refresh. Cast, remote control, device
registration and the Mydia settings serve the bound instance only; the other
instances share the device's single p2p identity and `device_id`. Signing out
removes the bound instance, and the first Mydia left becomes bound. The
shell's offline state follows the route's source.

### Web

Mydia accounts are kept on web, where other third-party sources are filtered
out. The instance-hosted build upserts its own account from the injected
`window.mydiaConfig` on every load (`upsertWebConfigAccount`): a fresh token
for the hosting server, matched to a stored account by instance id, node or
URL. It runs even when the migration fails.

## Locks

A server can be `locked` (listed with a badge, opens after authenticating)
or `hidden` (in no list until the app is unlocked). The mode is stored per
server id on the account record (`serverLocks`), so every Plex Home user
shares it and removing the account removes it. `putAccount` carries the
stored locks over a fresh sign-in. The Mydia login cannot be locked.

`SourceLockController` is true while unlocked, memory only, so a cold start
is locked. It relocks one minute after the app goes to the background,
unless a locked or hidden source is playing (`hold()` from the player
route), in which case it relocks when that playback ends. A Dart timer does
not count time the device slept, so the grace is also checked against the
wall clock when the app resumes.

Unlocking uses `local_auth` (Face ID, Touch ID, fingerprint, Windows Hello,
device passcode) where `isDeviceSupported()`, and a PIN everywhere else
(Linux, a TV or phone with no screen lock). The PIN is set with the first
lock on every device, as the backup: PBKDF2 in `AuthStorage` under
`app_lock/`, five free tries, then a doubling delay from 30 seconds (wall
clock time, capped, and an unreadable stored block counts as blocked). The
device passcode also unlocks, because device auth allows it. Forgot
PIN removes every account with a lock.

`thirdPartySourcesProvider` drops hidden sources while locked, and the
router sends any `/s/<id>/...` of a locked or hidden source to `/unlock`.
That screen never names a source, and "Show hidden servers" is always
offered, so nothing on screen says whether anything is hidden. Whenever
the app is unlocked and any server has a lock, Android sets `FLAG_SECURE` and
iOS blurs the window when it resigns active. While a locked source plays,
MPRIS and the macOS Dock now-playing menu show "Mydia" with no title or
artwork.

## Cast

Plex, Jellyfin and Stash items cast to Chromecast and DLNA, not to Mydia
player targets. `SessionSourceCastBinding` builds the receiver's route from
the item's playback session in receiver mode: H.264/AAC
(`receiverDeviceProfile`), and the credential in the query (`X-Plex-Token`,
`api_key`, `apikey`), because a receiver cannot send headers. Local playback
never does this. The TV fetches from the source's current connection, so a
server this device reaches only over a VPN cannot be cast from.

Chromecast gets HLS (copy for H.264, otherwise a transcode, and a transcode
after one rejected load; DLNA is not retried) and DLNA the direct file.
Subtitles:

- Jellyfin converts any text track, embedded or sidecar, to WebVTT. Image
  tracks are excluded.
- Stash serves its captions as WebVTT.
- Plex burns the chosen track in, image tracks included. That forces a
  transcode, and selecting it on the part also changes the track Plex picks
  for that file on its other clients. Changing the track restarts the stream.
- DLNA gets no subtitles.

Progress goes to the source's own reporter from the receiver's position. The
persisted cast record keeps no stream URL, because it carries the credential.

## HTTP and errors

`SourceHttp` turns non-2xx answers into typed source errors. It has an
opt-in `passThrough` status set for callers whose server puts a useful body
on an error status. `StashClient.query` passes `{400, 422}`, because Stash
(gqlgen) answers GraphQL validation errors with those statuses and the
client needs the error body.

## Caching

Every leaf provider in `source_browse_providers.dart` and
`sourceSimilarProvider` is a `SourceWatcher` (`cache/`). It shows the last
answer while the fetch log still has a time for its key, always fetches,
and stores what comes back as JSON in the `source_cache` Hive box. Keys
are ordinary `QueryKey`s named `<sourceId>/<op>` (`SourceKeys`), so the
fetch log, `FreshnessHeader`, `WatcherRegistry` and `Invalidator` that
Mydia's own screens use serve sources too, and the resume sweep covers
both.

Writes invalidate through `SourceRules`, one family per operation on the
written item's source: live watchers refetch, the rest lose their
fetch-log entry and mount cold. With no fetch-log time but a stored entry,
a failed fetch still shows the entry with the failed-refresh banner. A
refetch that arrives while a fetch is in flight queues exactly one
follow-up fetch rather than joining it, so a write mid-fetch cannot leave
pre-write data stamped as fresh.

Only a library's first page is stored. Once the viewer pages, that
library's watcher declines automatic refetches and ignores page-1 answers.
A failed page-2 load clears the paging flag, so page 1 can refresh again.

A fetched answer equal to what the watcher already emitted (compared as
JSON) is not emitted again, though it still refreshes the stored entry and
the fetch-log time. Pull-to-refresh and retry rebuild the watcher, which
paints the stored answer first, so the indicator finishes while the
freshness line keeps running until the network answers.

The source detail notifiers ignore an error from a provider that was
disposed or rebuilt mid-load, but only when the build itself is stale: an
error reaching a build that has already been replaced belongs to nobody
and is dropped (`source_detail_controllers.dart`).

Changing any model's `toJson` shape means bumping
`SourceCache.schemaVersion`; old entries then read as absent. The box is
swept in the background after it opens: entries older than 30 days go,
then the oldest beyond 2000. Removing an account (or Forgot PIN) deletes
its entries. That delete is best-effort: a failed one is logged and does
not stop the removal. The account's fetch-log entries stay, since the
fetch log has no sweep; they are a timestamp each and nothing reads them
once the source is gone. Entries of a server dropped without removing the
account are left for the 30-day sweep. Locked and hidden servers are cached like any other; the
router's lock gate is what hides them.

## Credentials stay out of URLs

Plex tokens travel as `X-Plex-Token`, Stash keys as `ApiKey`, both as
headers, including to the player (media_kit sends them with every segment
request). Jellyfin tokens travel in the `Token=` field of a `MediaBrowser`
`Authorization` header. Stash adds `apikey=` to URLs it generates; `stashRelativePath`
strips it. Artwork caches on `sourceId|path|width`, never the URL. The log
and crash redactors know both header names.

## Playback

`PlaybackSession` is the player screen's only view of a server. Mydia's
session wraps the GraphQL calls, `PlaybackController` and the p2p proxy.
Plex, Stash and Jellyfin share `SourcePlaybackSession` (data from the
neutral item detail) and `SimplePlaybackTransport` (no readiness probe: all
serve a complete HLS playlist). Jellyfin asks the server first
(`PlaybackInfo`, with a device profile built from the same codec list Plex
uses, `transcode_codecs.dart`) and offers only what it allows. `PlaybackFeature` lists what a session
supports: library refresh and the connection's link path are Mydia's; cast
is Mydia's, Plex's, Jellyfin's and Stash's. Downloads are not a session
feature: they are the source's `Downloadable` capability. The screen checks
before using any of them.

Source episodes get Up Next. `SourcePlaybackSession.seasonEpisodes` walks
show, season, episodes, and plays each entry's `defaultVersionId`.

Plex, Stash and Jellyfin report progress through `PeriodicProgressReporter`: every
10 seconds, on every play and pause, and on a seek (a position jump of more
than 3 seconds). Watched is marked once per playback, at the same 90%
threshold `ProgressService` uses for Mydia.

## Downloads

Every source implements `Downloadable`; see `player/docs/downloads.md`.

## Screens

Plex and Jellyfin movies, shows, seasons and episodes open on the same
detail screens as Mydia (`/s/:sourceId/movie|show|season|episode/:id`,
`source_detail_routes.dart`), fed by `detail_providers.dart`.
`SourceItemScreen` serves Stash videos and folders; the generic item route
redirects the other kinds to their detail route. Actions only Mydia has
appear by `DetailFeature`; a source gets Watched and Favorite when it lists
`watchedState` and `favorites` (`sourceFeatures`). Cast and trailer come
with the item. Similar and next up are the `Similar` and `NextUp`
capabilities. A failed similar rail is hidden, and a failed next up leaves
the show's hero on its first episode.

Source screens show messages through the app's toast (`Toaster`), not a
`SnackBar`, and reserve dock clearance with `DockInsets` so content is not
hidden behind the bottom dock.

A source's home shows Continue Watching first when the source implements
`ContinueWatching` (Plex: `/hubs/continueWatching/items`; Stash: scenes
with a resume point, last played first; Jellyfin: `/UserItems/Resume`, then
`/Shows/NextUp` for shows with nothing under way, 20 in all). Then come the
server's own rows when it implements `HomeHubs` (Plex's `/hubs`, minus
`home.continue` and `home.ondeck`), otherwise one row per library. A failed
Continue Watching hides its row; failed hubs fall back to the library rows.
Removing from Continue Watching is a Plex
`PUT /actions/removeFromContinueWatching`, a Stash `sceneSaveActivity` with
a zero resume point (which works on every Stash the source supports;
`sceneResetActivity` needs 0.27), and a Jellyfin
`POST /UserItems/{id}/UserData` with a zero `PlaybackPositionTicks`.
Jellyfin cannot dismiss a Next Up episode, so
`canRemoveFromContinueWatching` is false for one and the row's menu offers
Details only.

### Shared sort and recently added

Each source tags the sort options it already offers with a `SharedSort`
(`title`, `added`, `released`), so a view over several servers can ask
each library for the same order without knowing its sort ids. Untagged
options (rating, random, last watched) have no cross-server meaning.
Summaries carry `sortTitle`, `addedAt` and `lastPlayedAt` where the server
sends them: Plex `titleSort`, `addedAt`, `lastViewedAt` (Unix seconds);
Jellyfin `SortName` and `DateCreated` (only when `Fields` asks) and
`UserData.LastPlayedDate`; Stash `created_at` and `last_played_at`, no sort
title. `RecentlyAdded` is Plex `/library/recentlyAdded`, Jellyfin
`/Items/Latest` with no `ParentId` (a bare JSON array, read with
`JellyfinClient.getList`), and Stash scenes by `created_at`. Jellyfin
groups new episodes under their show, whose `addedAt` comes from
`DateLastMediaAdded` (the show's own `DateCreated` is when it was first
added); browse keeps `DateCreated` to match the server's sort.

## All servers

The switcher's "All servers" row (shown once two or more servers are
included) opens `/all`: Continue Watching and Recently Added from every
included server, merged newest first, then merged Movies and TV Shows
grids (`/all/movies`, `/all/shows`) and search (`/all/search`).
`LiveMergedReader` (`lib/domain/merged/`) asks each server live with an 8
second timeout; a server that fails is named in a banner, and one without
the capability or the chosen sort sits out. Grids are a k-way merge of each
library's own pages in the `SharedSort` order, so an item is shown only
once every server still paging has one buffered. Search keeps each
server's ranking and interleaves servers within Movies, Shows, Episodes and
Videos. `/all*` redirects to `/` when fewer than two servers are included,
including on a cold start before the saved servers load, as `/s/<id>` does.

Each server's "Include in All servers" switch (Manage servers) is stored by
`SourceId` beside the accounts; Stash defaults to off. Every Mydia joins
through `mediaSourceProvider` like any other server, and the bound
instance's items open Mydia's own detail screens.

## Tests

The Stash GraphQL documents under `stash/` target Stash's schema, so the
Mydia schema guard (`test/core/graphql/schema_conformance_test.dart`)
skips that directory.

## Adding a source kind

1. A `MediaSource` subclass with its mapping and client, plus the shared
   contract suite in `test/core/sources/media_source_contract.dart`.
   `ContinueWatching`, `HomeHubs`, `Similar`, `Favorites`, `NextUp`,
   `RecentlyAdded` and `SkipSegments` are optional; a source that implements one also lists
   the matching `SourceCapability`.
2. A `SourceKind` value and a case in `source_factories.dart`.
3. A `SourcePlaybackSession` subclass and a case in
   `playbackSessionFor`.
4. An add flow under `presentation/screens/sources/`.
5. Map `cast`, `contentRating`, `show` and `season` in the item detail, and
   `overview`, `airDate` and `defaultVersionId` in summaries, so the shared
   detail screens and Up Next have what they need. Tag existing sort
   options with `SharedSort` and fill `sortTitle`, `addedAt` and
   `lastPlayedAt` where the server has them.
