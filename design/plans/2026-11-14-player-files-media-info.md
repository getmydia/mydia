# Media Info for Files libraries Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Media Info panel works for every Files library item, with stream details read on the device by a headless mpv probe, cached by size and mtime, and read ahead of time after each scan on desktop.

**Architecture:** A pure mapping turns mpv's property JSON into a `ProbeResult`; `MpvMediaProbe` opens a muted, video-less media_kit `Player` on the file's `PlayableFile` to read it. `FilesMediaInfoCache` (its own Hive box) stores results. `FilesMediaSource` implements `MediaInfo` from the index plus cache plus probe, and `FilesProbeQueue` fills the cache after a scan on desktop.

**Tech Stack:** Flutter, Riverpod, Hive, media_kit (libmpv).

**Spec:** `design/specs/2026-11-14-player-files-media-info-design.md`

## Global Constraints

- All paths below are under `player/`. Run tests from the repo root with `./dev flutter test --concurrency=1 <paths>`; without `--concurrency=1` files are silently skipped (`player/docs/workflow.md`).
- Probe timeout: 15 seconds overall. One probe at a time, process wide.
- Background probing only where `PlatformFeatures.isDesktop` is true, and never for a peer source (`isPeerFilesSource`).
- "Playback active" is `ref.read(playingSourceProvider).current != null`; poll every 5 seconds while it holds.
- The cache box is `files_media_info`, added to `kMydiaHiveBoxes` (`lib/core/storage/hive_box_migration.dart`) and opened in `openFilesLibraryBoxes`.
- Probe results never go into `FileLibraryIndex` and never bump the peer files revision.
- New text goes into all four ARB files (`app_en`, `app_es`, `app_pt`, `app_pt_BR`) with a description; `test/l10n/untranslated_text_test.dart` must pass.
- Test fixtures use invented titles only. No em dashes in prose or strings.
- No `!` on nullable values without a preceding check; `debugPrint`, never `print`.

## Review Focus

1. **Two panel opens of the same uncached file at once** (detail screen and a version switch): both should get the same probe, not two mpv instances back to back. Task 4 dedupes in-flight probes by file key.
2. **The account is removed while a background probe runs:** the result must not be written back afterwards and resurrect cache rows. Task 5 checks the source is still active before `put`.
3. **An audio-only or still-image file** (no video track, or `albumart` video): `resolution` and `codec` stay null rather than reading the cover art's size. Task 1 maps it.
4. **A paired device's library whose host is offline:** the panel shows the device-named peer fault from `playableForFileKey`, not a blank list. Task 4 tests it.
5. **A file replaced in place with the same size** (re-encode to identical byte count) is still re-read because mtime changed. Task 3 tests mtime alone.

---

### Task 1: mpv property mapping

**Files:**
- Create: `lib/core/player/mpv_probe_mapping.dart`
- Create: `test/core/player/mpv_probe_mapping_test.dart`
- Create: `test/fixtures/mpv_probe/hevc_dv_mkv.json`, `test/fixtures/mpv_probe/sparse_avi.json`, `test/fixtures/mpv_probe/audio_only.json` (each `{"file-format": ..., "duration": ..., "file-size": ..., "track-list": [...], "video-params": {...} | null}` as mpv prints them)

**Interfaces:**
- Produces:
  - `class ProbeResult { final String? container; final double? durationSeconds; final int? bitrate; final List<MediaStream> streams; const ProbeResult({...}); Map<String, Object?> toMap(); factory ProbeResult.fromMap(Map<dynamic, dynamic>); String? get resolution; String? get videoCodec; }`
  - `ProbeResult mapMpvProbe({required String? fileFormat, required double? duration, required int? fileSize, required List<Object?> trackList, required Map<String, Object?>? videoParams})`

- [ ] **Step 1: Write the failing tests**

```dart
test('maps an HEVC 10-bit Dolby Vision MKV', () {
  final r = mapFixture('hevc_dv_mkv.json');
  expect(r.container, 'matroska');
  final v = r.streams.firstWhere((s) => s.type == MediaStreamType.video);
  expect([v.codec, v.width, v.height, v.bitDepth], ['hevc', 3840, 2160, 10]);
  expect([v.colorTransfer, v.colorPrimaries], ['pq', 'bt.2020']);
  expect(r.resolution, '2160p');
  expect(r.videoCodec, 'hevc');
  final audio = r.streams.where((s) => s.type == MediaStreamType.audio).toList();
  expect(audio.where((a) => a.isDefault), hasLength(1));
  expect(audio.where((a) => a.isCommentary), hasLength(1)); // title "Director Commentary"
  final subs = r.streams.where((s) => s.type == MediaStreamType.subtitle).toList();
  expect(subs.where((s) => s.isForced), hasLength(1));
  expect(subs.where((s) => s.isHearingImpaired), hasLength(1));
});
test('external tracks are left out', ...); // fixture has one "external": true sub
test('bitrate falls back to size * 8 / duration', () {
  final r = mapFixture('sparse_avi.json'); // no demux-bitrate, file-size 700000000, duration 5600
  expect(r.bitrate, 1000000);
});
test('audio-only file has no resolution or codec', () {
  final r = mapFixture('audio_only.json'); // one albumart video track + one audio
  expect(r.resolution, isNull);
  expect(r.videoCodec, isNull);
  expect(r.streams.where((s) => s.type == MediaStreamType.video), isEmpty);
});
test('toMap/fromMap round-trips', ...);
```

- [ ] **Step 2: Run to verify failure**

Run: `./dev flutter test --concurrency=1 test/core/player/mpv_probe_mapping_test.dart`
Expected: FAIL, `mpv_probe_mapping.dart` not found.

- [ ] **Step 3: Implement `mapMpvProbe` and `ProbeResult`**

Field mapping is the spec's table. `type: "sub"` maps to `MediaStreamType.subtitle`. Skip tracks with `external: true` or `albumart: true` (or `image: true`). `bitDepth` from `pixelformat`: a trailing `10`/`12` in names like `yuv420p10`, `p010` gives 10, else 8 when present. Colour fields come from `videoParams` and go on the default video track only (first `default: true`, else first video). `isCommentary` is a case-insensitive "commentary" in the title. `bitrate` is the sum of track `demux-bitrate` values when any is present, else `fileSize * 8 ~/ duration` when both are positive. `resolution`: height ≥ 2000 → `2160p`, ≥ 1000 → `1080p`, ≥ 700 → `720p`, ≥ 400 → `480p`, else `${height}p`.

- [ ] **Step 4: Run to verify pass** (same command, PASS)

- [ ] **Step 5: Commit** `feat(player): map mpv probe properties to media streams`

---

### Task 2: `MediaProbe` and the mpv implementation

**Files:**
- Create: `lib/core/player/media_probe.dart` (interface, `SerializedMediaProbe`, `mediaProbeProvider`)
- Create: `lib/core/player/media_probe_native.dart` (`MpvMediaProbe`), `lib/core/player/media_probe_stub.dart` (returns null), chosen with the same `if (dart.library.io)` conditional import pattern as `device_profile_native.dart`
- Create: `test/core/player/media_probe_test.dart`

**Interfaces:**
- Consumes: `ProbeResult`, `mapMpvProbe` (Task 1); `PlayableFile` (`lib/core/sources/files/backend/file_system_backend.dart`).
- Produces:
  - `abstract interface class MediaProbe { Future<ProbeResult?> probe(PlayableFile playable, {Duration timeout = const Duration(seconds: 15)}); }`
  - `class SerializedMediaProbe implements MediaProbe { SerializedMediaProbe(MediaProbe inner); }`
  - `final mediaProbeProvider = Provider<MediaProbe>(...)`: `SerializedMediaProbe(createPlatformMediaProbe())`.

- [ ] **Step 1: Write the failing tests** for `SerializedMediaProbe` with a fake inner probe backed by `Completer`s:
  - `'runs one probe at a time'`: start two probes, assert the inner saw only the first until it completes, then the second.
  - `'a throwing inner probe releases the lock and returns null'`.

- [ ] **Step 2: Run to verify failure**: `./dev flutter test --concurrency=1 test/core/player/media_probe_test.dart`, FAIL.

- [ ] **Step 3: Implement.** `SerializedMediaProbe` chains on a private `Future<void>` tail and catches everything, returning null. `MpvMediaProbe.probe`: `Player()`; if `player.platform is! NativePlayer` return null; `setProperty('vo', 'null')`, `setProperty('ao', 'null')`, `setProperty('pause', 'yes')` before `player.open(Media(url, httpHeaders: headers), play: false)`. Wait (within `timeout`) for `player.stream.tracks` to report a non-empty list, then up to the remaining time for `getProperty('video-params/w')` to be non-empty. Read `file-format`, `duration`, `file-size`, `track-list` (JSON string via `getProperty`, `jsonDecode`), `video-params` (as JSON via `getProperty('video-params')` when non-empty). Return `mapMpvProbe(...)`; return null if `track-list` never came. `player.dispose()` in `finally`. `debugPrint('[MediaProbe] ...')` the elapsed time and outcome.

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit** `feat(player): headless mpv media probe` (the real mpv path is checked by hand in Task 6)

---

### Task 3: `FilesMediaInfoCache`

**Files:**
- Create: `lib/core/sources/files/media_info/files_media_info_cache.dart`
- Modify: `lib/core/storage/hive_box_migration.dart` (add `'files_media_info'` to `kMydiaHiveBoxes`)
- Modify: `lib/core/sources/files/files_providers.dart` (`openFilesLibraryBoxes` opens the box; add `filesMediaInfoCacheProvider`)
- Modify: `lib/core/sources/files/files_accounts.dart` (`removeFilesAccount` calls `clearAccount`)
- Modify: `lib/core/p2p/peer_files_client.dart:156` and `:436` (each `_store.remove(localAccountId)` is followed by `clearAccount(localAccountId)` on the cache, injected into `PeerFilesClient` as an optional `FilesMediaInfoCache?`)
- Create: `test/core/sources/files/media_info/files_media_info_cache_test.dart`

**Interfaces:**
- Consumes: `ProbeResult` (Task 1), `IndexedFile` (`index/index_records.dart`).
- Produces:
  - `class FilesMediaInfoCache { static const boxName = 'files_media_info'; FilesMediaInfoCache(Box<Map<dynamic, dynamic>> box); ProbeResult? get(String accountId, IndexedFile file); Future<void> put(String accountId, IndexedFile file, ProbeResult result); Future<void> sweep(String accountId, Set<String> liveFileKeys); Future<void> clearAccount(String accountId); }`
  - `final filesMediaInfoCacheProvider = Provider<FilesMediaInfoCache?>(...)`: null when the box is not open (tests, failed startup).
  - Key: `'$accountId|${file.key}'`; stored map `{'size': int, 'modified': int ms, 'result': ProbeResult.toMap()}`.

Keyed by account id rather than `SourceId`: the account id is what removal knows, and a files account has one source.

- [ ] **Step 1: Write the failing tests** (in-memory Hive via the existing test helper used by `files_index` tests):
  - `'get returns what put stored'`
  - `'a size change is a miss'`
  - `'an mtime change alone is a miss'` (same size, `modified` +1s)
  - `'sweep drops keys no longer indexed and keeps the rest'`
  - `'clearAccount drops only that account'`

- [ ] **Step 2: Run to verify failure**: `./dev flutter test --concurrency=1 test/core/sources/files/media_info/`

- [ ] **Step 3: Implement** the class and wiring above. `open_files_library_boxes_test.dart` must still pass.

- [ ] **Step 4: Run** the new test plus `test/core/sources/files/open_files_library_boxes_test.dart test/core/sources/files/files_accounts_test.dart`. PASS.

- [ ] **Step 5: Commit** `feat(player): cache files media info by size and mtime`

---

### Task 4: `FilesMediaSource` implements `MediaInfo`

**Files:**
- Modify: `lib/core/sources/files/files_media_source.dart` (constructor gains `MediaProbe? probe` and `FilesMediaInfoCache? mediaInfoCache`; `implements MediaInfo`; `capabilities` adds `SourceCapability.mediaInfo`; `as<T>` already returns `this` for listed capabilities, confirm)
- Create: `lib/core/sources/files/media_info/files_media_info.dart` (pure: `MediaFileInfo filesMediaFileInfo({required IndexedFile file, required LibraryRoot root, ProbeResult? probe})`)
- Modify: `lib/core/sources/files/files_providers.dart` (pass `ref.read(mediaProbeProvider)` and `ref.read(filesMediaInfoCacheProvider)` into the source)
- Modify: `test/core/sources/files/files_fixture.dart` (accept a fake probe and a cache)
- Create: `test/core/sources/files/files_media_info_test.dart`
- Modify: `lib/core/sources/README.md` (Files section: Media Info, the probe, the cache, the desktop queue; one short subsection)

**Interfaces:**
- Consumes: Tasks 1 to 3; `FilesCatalog.sidecarStreams(root, file)` (`files_queries.dart`); `item(ref)` whose `versions[].id` is the file key; `playableForFileKey`.
- Produces:
  - `Future<List<MediaFileInfo>> mediaInfo(ItemRef ref)`
  - `Future<ProbeResult?> probeFileKey(String fileKey)`: probes and caches one file, deduped in flight; used by Task 5.

- [ ] **Step 1: Write the failing tests**

```dart
test('lists mediaInfo and answers from the index before any probe', ...);
// fake probe returns null: one entry, fileName/directory/size/container 'mkv', streams null
test('probe fields override and are cached', ...);
// fake probe returns a ProbeResult; second call does not call the probe again
test('a failed probe gives streams null and is not cached', ...);
// probe returns null twice: called twice
test('a movie with two versions gives two entries in version order', ...);
test('a show gives an empty list; an unknown ref throws notFound', ...);
test('two concurrent calls for the same file probe once', ...);
test('a lent library whose host is unreachable throws the peer fault', ...);
// use peer_files_harness.dart; expect SourceException with SourceFault.peerFilesHostUnreachable
test('external subtitles come from sidecars', ...);
// sidecar 'Movie.en.forced.srt' → SubtitleTrack(language 'en', format 'srt', embedded false)
```

- [ ] **Step 2: Run to verify failure**: `./dev flutter test --concurrency=1 test/core/sources/files/files_media_info_test.dart`

- [ ] **Step 3: Implement.** `mediaInfo`: `final detail = await item(ref)`; for each version, look up `index.files()[version.id]` and its root, read the cache, and on a miss call `probeFileKey`. `probeFileKey` holds a `Map<String, Future<ProbeResult?>>` of in-flight probes, resolves `playableForFileKey` (letting its `SourceException` propagate), calls the probe, and `put`s a non-null result. `filesMediaFileInfo` sets `id` to the file key, `fileName`/`directory` split from `file.path`, `sizeBytes`, `container` from the probe or the lowercased extension, `resolution`/`codec` from `ProbeResult.resolution`/`videoCodec`, `durationSeconds`, `bitrate`, `streams` (null when no probe), and `externalSubtitles` from `sidecarStreams` mapped to `SubtitleTrack(id, language ?? 'und', title, format: codec ?? '', embedded: false)`.

- [ ] **Step 4: Run** the new test and `test/core/sources/files/files_media_source_test.dart` (the Files contract run lives there). PASS.

- [ ] **Step 5: Commit** `feat(player): Media Info for files libraries`

---

### Task 5: Desktop probe queue after a scan

**Files:**
- Create: `lib/core/sources/files/media_info/files_probe_queue.dart`
- Modify: `lib/core/sources/files/files_scan_controller.dart` (end of `_run`, after matching, when the run scanned: `cache.sweep(...)` then `ref.read(filesProbeQueueProvider(sourceId).notifier).enqueueStale()`)
- Modify: `lib/presentation/widgets/files/files_scan_banner.dart` (show the probe line when `!scan.running` and probe progress is running)
- Modify: `lib/l10n/app_en.arb`, `app_es.arb`, `app_pt.arb`, `app_pt_BR.arb` (`filesProbeProgress`: "Reading file details {done} of {total}", placeholders as `filesScanProgress`)
- Create: `test/core/sources/files/media_info/files_probe_queue_test.dart`
- Modify: `test/presentation/widgets/files/files_scan_banner_test.dart`

**Interfaces:**
- Consumes: `FilesMediaSource.probeFileKey`, `FilesMediaInfoCache.get`/`sweep` (Tasks 3, 4); `playingSourceProvider`; `PlatformFeatures.isDesktop`.
- Produces:
  - `@immutable class ProbeProgress { final bool running; final int done; final int total; }`
  - `final filesProbeQueueProvider = NotifierProvider.family<FilesProbeQueue, ProbeProgress, SourceId>(...)`
  - `final filesProbeDesktopProvider = Provider<bool>((_) => PlatformFeatures.isDesktop)` (overridden in tests)
  - `FilesProbeQueue.enqueueStale()`: no-op unless desktop and not a peer source; collects indexed files whose cache `get` is null, replaces any pending list, and runs if idle.
  - `final filesProbeIdlePollProvider = Provider<Duration>((_) => const Duration(seconds: 5))` (overridden in tests)

- [ ] **Step 1: Write the failing tests**

```dart
test('probes every stale file after enqueue on desktop, one at a time', ...);
test('does nothing when not desktop', ...);
test('does nothing for a peer source', ...);
test('skips files with a fresh cache entry', ...);
test('waits while playingSourceProvider.current is set, resumes after release', ...);
test('a second enqueue replaces the pending list', ...);
test('stops and writes nothing after the source is no longer active', ...);
// remove the source mid-run (FilesMediaSource.activeSources no longer has it); the next file is not probed, cache unchanged
test('progress counts done of total and clears running at the end', ...);
```

Banner test: `'shows Reading file details while probing after a scan'` with `filesProbeQueueProvider` overridden to `ProbeProgress(running: true, done: 3, total: 10)`; finds `Key('files-probe-progress')`.

- [ ] **Step 2: Run to verify failure**: `./dev flutter test --concurrency=1 test/core/sources/files/media_info/files_probe_queue_test.dart test/presentation/widgets/files/files_scan_banner_test.dart`

- [ ] **Step 3: Implement.** The loop reads `mediaSourceProvider(sourceId)` per file and stops when it is not a `FilesMediaSource` in `FilesMediaSource.activeSources`. Before each file it waits while `playingSourceProvider.current != null`, polling at `filesProbeIdlePollProvider`. A failed probe is counted as done and not retried in the run. `filesScanBannerShows` also returns true while probe progress runs.

- [ ] **Step 4: Run** the tests above plus `test/core/sources/files/files_scan_controller_test.dart test/l10n/`. PASS.

- [ ] **Step 5: Commit** `feat(player): read files media info in the background after a scan on desktop`

---

### Task 6: Verify

- [ ] **Step 1:** `./dev flutter analyze` → no issues.
- [ ] **Step 2:** `./dev flutter test --concurrency=1 test/core/sources/files test/core/player test/presentation/widgets/files test/l10n` → all pass; note the test count.
- [ ] **Step 3: Manual, Linux desktop** (`./dev player` native run per `player/docs/workflow.md`): add a local folder, an SMB share and `rclone serve webdav` library with invented-title files; after the scan, the banner shows "Reading file details"; open Media Info on a movie and confirm streams, HDR fields, audio flags. Replace a file and rescan: its details refresh.
- [ ] **Step 4: Manual, Android TV** (`./dev player android tv-run`): SMB library; no probe line after scan; opening Media Info shows a loading state, then streams.
- [ ] **Step 5:** `git log origin/master..HEAD --oneline` lists the spec, the plan and five feature commits; `git status --porcelain` is clean.
