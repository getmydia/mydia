# Downloads: one pipeline for every source

Home Mydia, guest Mydia, Plex, Jellyfin and Stash all download through the same
service (`lib/core/downloads/download_service_native.dart`). What differs per
source is a plan, not a code path. Web has no downloads (`isDownloadSupported`
is false there).

## Model

A source that can download implements `Downloadable` (`capabilities.dart`).
It has two methods: `downloadOptions(ref)` lists what the viewer may pick, and
`resolve(ref, optionId)` returns a `DownloadPlan` (`domain/models/download_plan.dart`).
There are two kinds of plan:

- `DirectFile` is a URL, the headers that carry the credential, a file
  extension and an optional expected size. Plex, Jellyfin and Stash return one
  for their single `original` option (`core/sources/original_download.dart`).
  The credential goes in the headers, never in the URL, except for home
  Mydia's existing `?token=` media URL.
- `TranscodeJob` is a server-side job the pipeline prepares, polls and then
  fetches from. `MydiaTranscodeJob` implements it for home and guest Mydia.
  There "original" is just one of the server's options beside the quality
  rungs, and the option id is the `DownloadOption.resolution` string.

A screen asks for a download with a `DownloadRequest`: an `ItemRef`, the option
id, and a `DownloadMetadata` captured at that moment so the Downloads screen
has titles and art offline. `startItemDownload` (`presentation/screens/detail/start_download.dart`)
builds the request for the detail screens.

## The pipeline

Nothing is stored about how to fetch. Connections move and tokens expire, so
the plan resolver (`setPlanResolver`, wired in `download_providers.dart`) runs
on every start, resume, recovery and restart, and `_runTask` is the only loop
that moves bytes. It resolves, sees a transcode job through if there is one,
then fetches with `fetchRange` (`range_fetch.dart`), appending from whatever is
already on disk.

Rules that are easy to break:

- Starting, queued and resumed tasks are claimed as `downloading` before the
  loop runs, so they hold a concurrency slot at once, and `lastProgressAt` is
  refreshed so a slow resolve does not eat the stall window.
- Pause cancels the task's `CancelToken` first, then writes `paused`. After the
  cancel every write from the loop is a no-op (`superseded()`), so nothing can
  overwrite the status. Only active tasks pause; a finished, failed or
  cancelled one is left alone. The same cancelled-token rule is how cancel,
  restart and the stall watchdog take a task over.
- A 200 answer to a Range request means the server ignored the range and is
  sending the whole file, so `fetchRange` rewrites the file from the start
  rather than appending to it.
- A 401 or 403 re-resolves the plan once and retries. A second one fails the
  task for good with a "sign in again" message.
- A resolve failure splits two ways. A `SourceException` of kind `unreachable`
  parks the task as `interrupted`, to be resumed by the next sweep, and the
  sweep's attempt is handed back (`_ParkTask.countsAsAttempt`), so being offline
  never runs a task out of `recoveryAttempts`. Anything else (including a 404
  from the server) fails it permanently.
- The resolver (`download_providers.dart`) treats a source with no
  `MediaSource` as unreachable, not gone, while its account is still in the
  stored records, while the records have not loaded, and for signed-out home
  Mydia. A hidden source has no `MediaSource` while the app is locked, and the
  sweep runs on launch and resume. Only a third-party account missing from the
  records fails the task for good.
- Any transport failure with no HTTP response (`connectionError`, a timeout,
  `unknown`) parks the task as `interrupted`, whether or not bytes are on disk,
  so it resumes with a Range request. HTTP error statuses keep their own
  handling. Dio does not wrap an error from a streamed body, so `fetchRange`
  converts one into a `connectionError` `DioException` whose message is only
  the error's type name: the platform's text names the URL, and home Mydia's
  carries a token. Transport drops still count as recovery attempts.
- The transcode job calls (`prepare` and `status`) go through `_guardJobCall`,
  which maps a dropped connection the same way. The home HTTP job service
  throws `http` `ClientException`, `SocketException` or `HttpException`, and a
  timeout is a `TimeoutException`; those park the task as a counted attempt. A
  guest or p2p `SourceException` of kind `unreachable` parks it uncounted, as
  `_resolve` does. `DeadJobException`, `_TaskFailure` and every other error
  propagate unchanged, so a long remote transcode is resumed by the sweep
  with its `transcodeJobId` kept instead of failing.
- Progress is persisted and emitted at most every 500 ms (`_clock`) or every
  4 MiB, whichever comes first, and the state at the end of each fetch is
  always written. A large file arrives in tens of thousands of chunks, and
  each save is a Hive write plus an Android notification update. The speed
  tracker still sees every chunk.
- No saved `error` keeps a URL query: `_runTask` strips `?...` from any URL in
  an error text (`stripUrlQueries`) at the save point.
- For a `DirectFile` the size the response reports replaces the plan's
  `expectedBytes`, which is only an estimate (a bitrate guess for some
  sources), for progress, `fileSize` and the completeness check. A transcode
  job keeps its own count, since the file is still growing.
- Cancel writes `cancelled` and deletes the partial first, then cancels the
  server-side job without waiting, so an unreachable server cannot hang it.
- A `DeadJobException` (the server forgot the job) is only recoverable by
  restarting, which prepares a new job.

Interrupted tasks resume from the recovery sweep (launch, app resume and the
watchdog tick), not on their own.

## Records

`DownloadTask` and `DownloadedMedia` (`domain/models/download.dart`) carry
`sourceId`, `itemKind` and the art paths (`posterPath`, `backdropPath`,
`thumbnailPath`). A null `sourceId` means home Mydia, so records written
before sources existed keep working (`SourceId.legacyMydia`). The option id
lives in the existing `quality` field; Plex, Jellyfin and Stash always store
`original`.

Everything is looked up by `ItemRef` (source plus the server's id), through
`getDownloaded`, `isDownloaded`, `getMediaFor` and the `matches` method on both
record types. Never look up by the bare id: two sources can share one.

## Artwork

At completion the service saves the poster, backdrop and thumbnail beside the
file (`_saveArtwork`), fetched through the source so its credentials apply.
For an episode the saved poster is the show's poster, and the episode's own
still becomes the thumbnail. A failed picture never fails the download, and it
is skipped quietly if the download was deleted meanwhile.

`DownloadArtwork` prefers the saved copy. Only legacy home records, made
before pictures were saved, fall back to a URL, and it never fetches a source's
art path, which would need credentials.

## Playback

The Downloads screen builds the location in `downloadedPlayLocation`: the home
player route for home Mydia, `/s/<sourceId>/player/<id>?fileId=offline` for
anything else, so a source's route also puts the download behind that source's
lock. `fileId=offline` tells the player to use the local file.

The player asks `getDownloaded(session.item)`, under the session's own source.
When `session.reachable` is false it takes the offline path and plays only the
downloaded file; when the source is reachable and a local copy exists, the
local file is still preferred.

## Progress

Positions recorded while a source is out of reach go to the local progress
store, keyed by `progressKey`: bare ids for home Mydia, `<sourceId>|<id>` for
everything else. Home keeps `flushUnsyncedProgress` and `progressFlushProvider`.

`flushSourceProgress` (`playback_progress_store.dart`) handles the rest. The
`sourceProgressFlushProvider` runs it at startup, when the app resumes and
whenever a source comes back into reach. It pushes every unsynced record
through the source's `ProgressSync` without comparing against the server;
newer-wins is decided at play time by `pickNewerProgress`. Records for sources
that are gone, out of reach or that refuse the push stay unsynced for the next
run.

## Locks and removal

`visibleDownloadSources` is home plus every source the switcher shows. A hidden
source drops out of the Downloads lists while the app is locked, and its
downloads with it.

The Android foreground notification shows on the lock screen, so a locked or
hidden source's downloads count in it but never name a title
(`buildDownloadNotificationText`). `downloadManagerProvider` installs the
predicate with `setDiscreetSources`, reading `sourceLocksProvider` at call time
so the provider never watches sources.

Removing an account deletes the downloads of every profile on it, matched on
the account prefix of the source id (`deleteAccountDownloads`). Tasks go first,
so an in-flight download cannot finish and write a media row while the files
are being removed, and the cancel does not call the server (the credentials
are going). The removal waits at most `downloadLookupTimeout` (5 seconds) for
the download manager and then carries on without it, so it never hangs on
startup. That cleanup is best effort, so `orphanDownloadSweepProvider`
(`orphan_download_sweep.dart`, watched in AppShell) retries it: once per app
session, only on native, and only after the source records have loaded
successfully (never while loading or after an error, when the known accounts
are not known), it calls `deleteDownloadsOfUnknownAccounts` with the stored
account ids. That deletes the tasks, media rows and files of every account
that is not stored, matched on the source id's account prefix, and never
touches home Mydia. It is a separate provider so the keep-alive
`downloadManagerProvider` still never watches the source providers. Downloads from another Plex Home user stay on disk but are not listed
while a different user is active.

## Tests

`test/core/downloads/download_test_harness.dart` has the pieces: `FakeResolver`
(counts resolves, can fail or wait on a gate), `RecordingHttpAdapter` (with
`ignoreRange` to simulate a server that answers 200 to a Range request, and
`bodyError` for a connection that dies mid-body),
`TestClock` and `DownloadHarness`. `download_pipeline_test.dart` drives the
loop through them.
