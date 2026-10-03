# Sources: Mydia, Plex and Stash

The player browses and plays from more than one kind of server. This
package is the layer that makes them look alike to the screens.

## Model

A `ProviderAccount` is a credential (a plex.tv sign-in, a Stash API key,
the Mydia login). A `SourceProfile` is who acts with it; Plex Home users
become profiles later. A `SourceServer` is what the viewer browses. A
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
  `source/<accountId>/account_token` and
  `source/<accountId>/<profileId>/<serverId>/token` (`SourceSecrets`).
  A record is written only after its tokens.

## Connections

Every request reads `SourceConnection.base()` at call time.
`PlexConnectionManager` probes every advertised connection with
`GET /identity` (3s, relay 6s), uses the first that answers with the right
`machineIdentifier`, and moves to a better-ranked one when it answers
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
request). Stash adds `apikey=` to URLs it generates; `stashRelativePath`
strips it. Artwork caches on `sourceId|path|width`, never the URL. The log
and crash redactors know both header names.

## Playback

`PlaybackSession` is the player screen's only view of a server. Mydia's
session wraps the GraphQL calls, `PlaybackController` and the p2p proxy.
Plex and Stash share `SourcePlaybackSession` (data from the neutral item
detail) and `SimplePlaybackTransport` (no readiness probe: both serve a
complete HLS playlist). `PlaybackFeature` lists what only Mydia does
(downloads, cast, library refresh, its connection's link path); the
screen checks before using any of them.

Plex and Stash report progress through `PeriodicProgressReporter`: every
10 seconds, on every play and pause, and on a seek (a position jump of more
than 3 seconds). Watched is marked once per playback, at the same 90%
threshold `ProgressService` uses for Mydia.

## Screens

Source screens show messages through the app's toast (`Toaster`), not a
`SnackBar`, and reserve dock clearance with `DockInsets` so content is not
hidden behind the bottom dock.

## Tests

The Stash GraphQL documents under `stash/` target Stash's schema, so the
Mydia schema guard (`test/core/graphql/schema_conformance_test.dart`)
skips that directory.

## Adding a source kind

1. A `MediaSource` subclass with its mapping and client, plus the shared
   contract suite in `test/core/sources/media_source_contract.dart`.
2. A case in `source_factories.dart`.
3. A `SourcePlaybackSession` subclass and a case in
   `playbackSessionFor`.
4. An add flow under `presentation/screens/sources/`.
