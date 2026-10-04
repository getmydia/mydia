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

The Mydia login predates this layer. It appears as `Source.legacyMydia()`,
read from `AuthService`'s own keys, and keeps its unprefixed routes.

The source switcher groups servers by account, with a caption per
non-Mydia account.

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

## HTTP and errors

`SourceHttp` turns non-2xx answers into typed source errors. It has an
opt-in `passThrough` status set for callers whose server puts a useful body
on an error status. `StashClient.query` passes `{400, 422}`, because Stash
(gqlgen) answers GraphQL validation errors with those statuses and the
client needs the error body.

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
uses, `transcode_codecs.dart`) and offers only what it allows. `PlaybackFeature` lists what only Mydia does
(downloads, cast, library refresh, its connection's link path); the
screen checks before using any of them.

Plex, Stash and Jellyfin report progress through `PeriodicProgressReporter`: every
10 seconds, on every play and pause, and on a seek (a position jump of more
than 3 seconds). Watched is marked once per playback, at the same 90%
threshold `ProgressService` uses for Mydia.

## Screens

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

## Tests

The Stash GraphQL documents under `stash/` target Stash's schema, so the
Mydia schema guard (`test/core/graphql/schema_conformance_test.dart`)
skips that directory.

## Adding a source kind

1. A `MediaSource` subclass with its mapping and client, plus the shared
   contract suite in `test/core/sources/media_source_contract.dart`.
   `ContinueWatching` and `HomeHubs` are optional; a source that implements
   one also lists the matching `SourceCapability`.
2. A `SourceKind` value and a case in `source_factories.dart`.
3. A `SourcePlaybackSession` subclass and a case in
   `playbackSessionFor`.
4. An add flow under `presentation/screens/sources/`.
