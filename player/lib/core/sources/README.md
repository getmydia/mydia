# Sources: Mydia, Plex, Stash and Jellyfin

The player browses and plays from more than one kind of server. This
package is the layer that makes them look alike to the screens.

## Model

A `ProviderAccount` is a credential (a plex.tv sign-in, a Stash API key,
a Jellyfin user's token, the Mydia login). A `SourceProfile` is who acts
with it; Plex Home users become profiles later. A Jellyfin account is one
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
  `source/<accountId>/account_token` (plex.tv token, Stash API key,
  Jellyfin access token) and
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
with a resume point, last played first). Then come the server's own rows
when it implements `HomeHubs` (Plex's `/hubs`, minus `home.continue` and
`home.ondeck`), otherwise one row per library. A failed Continue Watching
hides its row; failed hubs fall back to the library rows. Removing from
Continue Watching is a Plex `PUT /actions/removeFromContinueWatching` and a
Stash `sceneSaveActivity` with a zero resume point (which works on every
Stash the source supports; `sceneResetActivity` needs 0.27).

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
