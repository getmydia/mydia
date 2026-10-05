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
  parks the task as `interrupted`, to be resumed by the next sweep. Anything
  else (including a 404 from the server) fails it permanently.
- A connection dropped mid-body, with bytes already on disk, also parks the
  task as `interrupted`, so it resumes with a Range request instead of
  restarting. A failure on the first request, with nothing on disk, still ends
  as `failed`.
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

Removing an account deletes the downloads of every profile on it, matched on
the account prefix of the source id (`deleteAccountDownloads`). Tasks go first,
so an in-flight download cannot finish and write a media row while the files
are being removed, and the cancel does not call the server (the credentials
are going). The removal waits at most `downloadLookupTimeout` (5 seconds) for
the download manager and then carries on without it, so it never hangs on
startup. Downloads from another Plex Home user stay on disk but are not listed
while a different user is active.

## Tests

`test/core/downloads/download_test_harness.dart` has the pieces: `FakeResolver`
(counts resolves, can fail or wait on a gate), `RecordingHttpAdapter` (with
`ignoreRange` to simulate a server that answers 200 to a Range request),
`TestClock` and `DownloadHarness`. `download_pipeline_test.dart` drives the
loop through them.
