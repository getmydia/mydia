# Player Files Offline Downloads and Casting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add offline downloads for network `Files` libraries (WebDAV and SMB) and Chromecast/DLNA casting for all `Files` libraries (local folders, WebDAV, and SMB) via a LAN HTTP range bridge (`FilesCastBridge`) with WebVTT subtitle sidecars.

**Architecture:** Network `FilesMediaSource` instances (`account.id != kFilesLocalAccountId`) advertise `SourceCapability.downloadable` and implement `Downloadable` via `originalOption` / `originalFile`, using `MediaVersion.sizeBytes` for exact byte sizes and adding a download button on `SourceItemScreen`. All `FilesMediaSource` instances advertise `SourceCapability.castable`; `FilesPlaybackSession` opens a session on a dedicated Dart LAN HTTP server (`FilesCastBridge`, bound to `InternetAddress.anyIPv4` only while a cast is active) that serves byte ranges from local files or authenticated HTTP/SMB upstreams plus CORS-enabled WebVTT subtitle sidecars (converted from `.srt` in pure Dart). `SessionSourceCastBinding` routes `FilesPlaybackSession` casts as progressive `CastRouteKind.localBridge` streams, and `CastSessionManager` avoids transcode retries on `localBridge` routes while tearing down the bridge session on cast stop or replacement.

**Tech Stack:** Flutter, Dart (`dart:io` `HttpServer`, `http`), Riverpod, `flutter_test`

**Spec:** `design/specs/2026-11-08-player-files-downloads-and-casting-design.md`

---

## Global Constraints

- **Fictional media names only:** Never use real movie or TV show titles in tests, fixtures, or commit messages. Invent titles (e.g., `Copper Valley`, `The Harbor Lights`, `Glass Orchard`, `Lanterns Over Fennick`).
- **Git commits:** Always commit inside the devenv shell (`devenv shell -- git commit -F <msgfile>` or `devenv shell -- git commit -m "..."`) after staging only your task's files, and verify every commit with `git show --stat HEAD`. Leave untracked files from other sessions alone.
- **No placeholders:** Every code block in this plan is complete and ready to write.

---

## File Structure

### New Files
- `player/lib/core/sources/files/cast/subtitle_vtt.dart` — Pure-Dart `.srt` / `.vtt` normalizer (`toWebVtt(String raw, {required String format})`).
- `player/lib/core/sources/files/cast/files_cast_bridge.dart` — `FilesCastBridge` LAN HTTP server (`openSession`, `closeSession`, `activePort`, `healListener`, `dispose`), `FilesCastSession` handle, and `FilesCastSubtitle` descriptor.
- `player/test/core/sources/files/files_download_test.dart` — Unit tests for `FilesMediaSource` offline download capability gating (`flocal` vs WebDAV/SMB), exact byte size reporting, and `prepareDownload` URL/header pass-through.
- `player/test/core/sources/files/cast/subtitle_vtt_test.dart` — Unit tests for `toWebVtt` (BOM stripping, CRLF normalization, comma-to-dot Cue timestamps, cue settings preservation, `.vtt` pass-through).
- `player/test/core/sources/files/cast/files_cast_bridge_test.dart` — Unit tests for `FilesCastBridge` (capability-token routing, local file `200`/`206`/`416`/`HEAD` range serving, upstream HTTP/SMB header forwarding and range streaming, `.srt` → WebVTT serving with `Access-Control-Allow-Origin: *`, session replacement/teardown, and `healListener`).

### Modified Files
- `player/lib/core/sources/original_download.dart` — Populate `DownloadOption.actualSize` from `version.sizeBytes` and prefer `version.sizeBytes` in `estimatedSize` and `PreparedDownloadFile.expectedBytes`.
- `player/lib/core/sources/files/files_media_source.dart` — Implement `Downloadable`; include `SourceCapability.downloadable` for non-local accounts (`source.account.id != kFilesLocalAccountId`) and `SourceCapability.castable` for all accounts; gate `as<T>()` so `as<Downloadable>()` returns `null` when `SourceCapability.downloadable` is absent.
- `player/lib/presentation/screens/sources/source_item_screen.dart` — Add `SourceItemDownloadButton` next to the Play and Watched actions when `source.capabilities.contains(SourceCapability.downloadable)` and the item is a movie or episode with at least one version.
- `player/test/core/sources/media_source_contract.dart` — Allow `ContractFixture` to test non-downloadable and downloadable `FilesMediaSource` instances cleanly.
- `player/test/core/sources/files/files_media_source_test.dart` — Add contract and capability assertions for local vs network `FilesMediaSource`.
- `player/test/presentation/screens/sources/source_item_screen_test.dart` — Widget tests verifying the download button appears for downloadable sources and is hidden when `SourceCapability.downloadable` is absent or the item is a folder/show.
- `player/lib/core/sources/files/files_providers.dart` — Register `filesCastBridgeProvider` and wire it into `FilesMediaSource` / `SourcePlaybackSession` construction.
- `player/lib/core/playback/simple_playback_transport.dart` — Add optional `String Function(String trackId)? subtitleUrl` to `ResolvedStream`.
- `player/lib/presentation/screens/player/session/source_playback_session.dart` — Add `bool get castsAsProgressive => false;` to `SourcePlaybackSession`.
- `player/lib/presentation/screens/player/session/files_playback_session.dart` — Override `castsAsProgressive => true`, accept `FilesCastBridge? bridge`, open a bridge session when `FilesStreamResolver.resolve` is called with `forCast: true`, populate `ResolvedStream.subtitleUrl` and `sessionId`, and implement `endServerSession(String sessionId)` to close the bridge session.
- `player/lib/presentation/screens/player/session/source_playback_sessions.dart` — Pass `ref.watch(filesCastBridgeProvider)` into `FilesPlaybackSession` in both `sourcePlaybackSessionProvider` and `openSourceSession`.
- `player/lib/presentation/screens/player/session/source_cast_binding_impl.dart` — Handle `_session.castsAsProgressive` in `SessionSourceCastBinding.resolve` (use `DirectPlayPlan` for both Chromecast and DLNA, populate `CastSubtitleTrack.url` from `stream.subtitleUrl`, and return `CastRouteKind.localBridge` / `CastMediaKind.progressive`).
- `player/lib/core/cast/cast_session_manager.dart` — Guard `_retryRouteFor` so `SourceCastContent` routes with `attempted.kind == CastRouteKind.localBridge` return `null` instead of retrying with `forceTranscode: true`.
- `player/lib/presentation/widgets/cast_actions.dart` — Check `filesCastBridgeProvider.activePort` in `castErrorMessage` when `localProxyServiceProvider` is not LAN-accessible so firewall error toasts name the bridge port.
- `player/lib/app.dart` — Call `ref.read(filesCastBridgeProvider).healListener()` alongside `mediaProxyProvider` and `smbNativeProvider` on `AppLifecycleState.resumed`.
- `player/test/presentation/screens/player/session/files_playback_session_test.dart` — Add tests for `FilesPlaybackSession` cast stream resolution, subtitle URLs, and `endServerSession`.
- `player/test/presentation/screens/player/session/source_cast_binding_impl_test.dart` — Add `Files` group testing Chromecast and DLNA `CastRoute` resolution through `FilesCastBridge`.
- `player/test/core/cast/cast_session_manager_source_test.dart` — Add test verifying `CastRouteKind.localBridge` is not retried with `forceTranscode: true` on media load failure and still calls `endServerSession` on stop.

---

### Task 1: Offline Downloads for Network `FilesMediaSource` and `SourceItemScreen` Download Button

**Files:**
- Modify: `player/lib/core/sources/original_download.dart`
- Modify: `player/lib/core/sources/files/files_media_source.dart`
- Modify: `player/lib/presentation/screens/sources/source_item_screen.dart`
- Create: `player/test/core/sources/files/files_download_test.dart`
- Modify: `player/test/presentation/screens/sources/source_item_screen_test.dart`

- [ ] **Step 1: Write failing unit tests in `player/test/core/sources/files/files_download_test.dart`**

Create `player/test/core/sources/files/files_download_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_ids.dart';
import 'package:player/core/sources/files/files_media_source.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/match/file_matcher.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/download_option.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

import '../media_source_contract.dart';
import 'fake_backend.dart';
import 'fake_media_names.dart';
import 'files_fixture.dart';

class _WebDavFakeBackend extends FakeBackend {
  _WebDavFakeBackend(super.files);

  @override
  Future<PlayableFile> playable(String path) async => PlayableFile(
        url: 'https://dav.example$path',
        headers: const {'Authorization': 'Basic dXNlcjpwYXNz'},
      );
}

final _webdavAccountId = webdavAccountId(Uri.parse('https://dav.example/media'));

final _webdavSource = Source(
  account: ProviderAccount(
    id: _webdavAccountId,
    kind: SourceKind.files,
    displayName: 'dav.example',
    storageNamespace: 'source/$_webdavAccountId',
    activeProfileId: kOwnerProfileId,
  ),
  profile: SourceProfile(
    id: kOwnerProfileId,
    accountId: _webdavAccountId,
    name: 'Owner',
    isOwner: true,
  ),
  server: SourceServer(
    id: _webdavAccountId,
    accountId: _webdavAccountId,
    profileId: kOwnerProfileId,
    name: 'dav.example',
  ),
);

Future<(FilesFixture, FilesMediaSource)> _buildSource(
  Source source,
  FileSystemBackend backend,
) async {
  final f = await FilesFixture.create();
  final relay = FakeFilesRelay();
  final mediaSource = FilesMediaSource(
    source: source,
    backend: backend,
    index: f.index,
    progress: f.progress,
    matcher: FileMatcher(
      tmdb: relay,
      names: FakeMediaNames(),
      index: f.index,
      progress: f.progress,
      sourceId: source.id,
    ),
    tmdb: relay,
    invalidate: (_) async {},
    l10n: () => filesL10n,
  );
  addTearDown(mediaSource.dispose);
  return (f, mediaSource);
}

void main() {
  const filePath = '${FilesFixture.rootPath}/Copper Valley (2018) 1080p.mkv';
  final versionKey =
      fileKeyFor(FilesFixture.rootId, 'Copper Valley (2018) 1080p.mkv');

  runMediaSourceContract('Network Files (WebDAV)', () async {
    final (f, source) = await _buildSource(
      _webdavSource,
      _WebDavFakeBackend({filePath: 1000}),
    );
    return ContractFixture(
      source: source,
      library: LibraryRef(sourceId: _webdavSource.id, id: FilesFixture.rootId),
      playable: ItemRef(
        sourceId: _webdavSource.id,
        kind: ItemKind.movie,
        externalId: '101',
      ),
      libraryItemCount: 3,
      show: ItemRef(
        sourceId: _webdavSource.id,
        kind: ItemKind.show,
        externalId: '201',
      ),
    );
  });

  test('local files source is castable but not downloadable', () async {
    final (_, source) = await _buildSource(
      filesLocalSource,
      FakeBackend({filePath: 1000}),
    );
    expect(source.capabilities, contains(SourceCapability.castable));
    expect(source.capabilities, isNot(contains(SourceCapability.downloadable)));
    expect(source.as<Downloadable>(), isNull);
  });

  test('network files source offers Original download with exact file size',
      () async {
    final (_, source) = await _buildSource(
      _webdavSource,
      _WebDavFakeBackend({filePath: 1000}),
    );
    expect(source.capabilities, contains(SourceCapability.downloadable));
    expect(source.capabilities, contains(SourceCapability.castable));

    final downloadable = source.as<Downloadable>();
    expect(downloadable, isNotNull);

    final movieRef = ItemRef(
      sourceId: _webdavSource.id,
      kind: ItemKind.movie,
      externalId: '101',
    );
    final options = await downloadable!.downloadOptions(movieRef, versionKey);
    expect(options, hasLength(1));
    final option = options.single;
    expect(option.id, kOriginalDownloadOptionId);
    expect(option.type, DownloadType.original);
    expect(option.actualSize, 1000);
    expect(option.estimatedSize, 1000);

    final prepared =
        await downloadable.prepareDownload(movieRef, versionKey, option);
    expect(prepared.url, 'https://dav.example$filePath');
    expect(prepared.headers, {'Authorization': 'Basic dXNlcjpwYXNz'});
    expect(prepared.container, 'mkv');
    expect(prepared.expectedBytes, 1000);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./dev mix cmd -- sh -c "cd player && flutter test test/core/sources/files/files_download_test.dart"` (or `devenv shell -- bash -c "cd player && flutter test test/core/sources/files/files_download_test.dart"`)
Expected: Fails because `local files source` is neither `castable` nor `downloadable`, and `FilesMediaSource` does not implement `Downloadable`.

- [ ] **Step 3: Update `original_download.dart` and `files_media_source.dart`**

Update `player/lib/core/sources/original_download.dart`:

```dart
import '../../domain/models/download_option.dart';
import '../../domain/sources/item.dart';
import 'media_source.dart';

const kOriginalDownloadOptionId = 'original';

/// Byte estimate from a version's bitrate and duration, when the source does
/// not report a file size directly.
int? estimatedBytes(MediaVersion v) {
  final kbps = v.bitrateKbps;
  final secs = v.durationSeconds;
  if (kbps == null || kbps <= 0 || secs == null || secs <= 0) return null;
  return kbps * 1000 ~/ 8 * secs;
}

/// The single "Original" [DownloadOption] offered by sources that download the
/// source file as-is rather than transcoding for offline use.
List<DownloadOption> originalOption(ItemDetail d, String versionId) {
  final v = _version(d, versionId);
  if (v == null) return const [];
  final video = v.streams
      .where((s) => s.kind == MediaStreamKind.video)
      .firstOrNull;
  final height = v.height ?? video?.height;
  final codec = (v.videoCodec ?? video?.codec ?? 'direct').toUpperCase();
  final container = (v.container ?? 'mp4').toUpperCase();
  final exactBytes = v.sizeBytes;
  final fallbackBytes = estimatedBytes(v);
  return [
    DownloadOption(
      id: kOriginalDownloadOptionId,
      name: 'Original',
      description: '$container · $codec',
      type: DownloadType.original,
      resolution: height != null ? '${height}p' : 'Original',
      videoCodec: v.videoCodec ?? video?.codec ?? 'direct',
      estimatedSize: exactBytes ?? fallbackBytes ?? 0,
      actualSize: exactBytes,
      isDirectFile: true,
    ),
  ];
}

/// Builds the [PreparedDownloadFile] for [versionId] once the caller has
/// resolved its direct [url] (and any request [headers]).
PreparedDownloadFile originalFile(
  ItemDetail d,
  String versionId, {
  required String url,
  Map<String, String> headers = const {},
}) {
  final v = _version(d, versionId);
  return PreparedDownloadFile(
    url: url,
    headers: headers,
    container: v?.container ?? 'mp4',
    expectedBytes: v?.sizeBytes ?? (v == null ? null : estimatedBytes(v)),
  );
}

MediaVersion? _version(ItemDetail d, String versionId) =>
    d.versions.where((v) => v.id == versionId).firstOrNull ??
    d.versions.firstOrNull;
```

Update `player/lib/core/sources/files/files_media_source.dart` to import `../../domain/models/download_option.dart` and `../original_download.dart`, implement `Downloadable`, expose `SourceCapability.castable` (always) and `SourceCapability.downloadable` (when `source.account.id != kFilesLocalAccountId`), gate `as<T>()`, and implement `downloadOptions` and `prepareDownload`:

In `player/lib/core/sources/files/files_media_source.dart`:
1. Add imports at the top:
```dart
import '../../../domain/models/download_option.dart';
import '../original_download.dart';
```
2. Change class header:
```dart
class FilesMediaSource
    implements
        MediaSource,
        Searchable,
        ContinueWatchingSource,
        RecentlyAddedSource,
        WatchedState,
        EditableMatch,
        Downloadable {
```
3. Update `capabilities` and `as<T>()`:
```dart
  bool get _isNetworkShare => source.account.id != kFilesLocalAccountId;

  @override
  Set<SourceCapability> get capabilities => {
        SourceCapability.searchable,
        SourceCapability.continueWatching,
        SourceCapability.recentlyAdded,
        SourceCapability.watchedState,
        SourceCapability.editableMatch,
        SourceCapability.castable,
        if (_isNetworkShare) SourceCapability.downloadable,
      };

  @override
  T? as<T extends Object>() {
    if (T == Downloadable && !_isNetworkShare) return null;
    return this is T ? this as T : null;
  }
```
4. Add `downloadOptions` and `prepareDownload` methods before `dispose()`:
```dart
  @override
  Future<List<DownloadOption>> downloadOptions(
    ItemRef item,
    String versionId,
  ) async =>
      originalOption(await this.item(item), versionId);

  @override
  Future<PreparedDownloadFile> prepareDownload(
    ItemRef item,
    String versionId,
    DownloadOption option,
  ) async {
    final detail = await this.item(item);
    final version = detail.versions
            .where((v) => v.id == versionId)
            .firstOrNull ??
        detail.versions.firstOrNull;
    final key = version?.id ?? versionId;
    final playable = await playableForFileKey(key);
    return originalFile(
      detail,
      key,
      url: playable.url,
      headers: playable.headers,
    );
  }
```

- [ ] **Step 4: Run `files_download_test.dart` and `files_media_source_test.dart`**

Run: `devenv shell -- bash -c "cd player && flutter test test/core/sources/files/files_download_test.dart test/core/sources/files/files_media_source_test.dart"`
Expected: All tests in both files PASS.

- [ ] **Step 5: Add a widget test for the download button on `SourceItemScreen`**

In `player/test/presentation/screens/sources/source_item_screen_test.dart`, add a test verifying that a downloadable source shows `source-item-download` on a playable item and hides it when `SourceCapability.downloadable` is absent or when viewing a folder:

Add imports to `player/test/presentation/screens/sources/source_item_screen_test.dart`:
```dart
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:player/domain/models/download_item.dart';
import 'package:player/domain/models/download_option.dart';
```
And add a `_DownloadableFakeSource` helper and widget tests at the bottom of `player/test/presentation/screens/sources/source_item_screen_test.dart`:
```dart
class _DownloadableFakeSource extends FakeMediaSource implements Downloadable {
  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.downloadable};

  @override
  Future<List<DownloadOption>> downloadOptions(
    ItemRef item,
    String versionId,
  ) async =>
      const [
        DownloadOption(
          id: 'original',
          name: 'Original',
          description: 'MKV · H264',
          type: DownloadType.original,
          resolution: '1080p',
          videoCodec: 'h264',
          estimatedSize: 1000,
          actualSize: 1000,
          isDirectFile: true,
        ),
      ];

  @override
  Future<PreparedDownloadFile> prepareDownload(
    ItemRef item,
    String versionId,
    DownloadOption option,
  ) async =>
      const PreparedDownloadFile(
        url: 'https://dav.example/film.mkv',
        container: 'mkv',
        expectedBytes: 1000,
      );
}
```
And in `pumpItem`, add `allDownloadsProvider.overrideWith((ref) => Stream.value(const <DownloadItem>[]))` to `overrides`, then add tests in `main()`:
```dart
  testWidgets('a downloadable source shows the download button on a video',
      (tester) async {
    await pumpItem(tester, _DownloadableFakeSource(), movie);
    expect(find.byKey(const Key('source-item-download')), findsOneWidget);
  });

  testWidgets('a non-downloadable source hides the download button',
      (tester) async {
    await pumpItem(tester, FakeMediaSource(), movie);
    expect(find.byKey(const Key('source-item-download')), findsNothing);
  });
```

- [ ] **Step 6: Run `source_item_screen_test.dart` to see it fail**

Run: `devenv shell -- bash -c "cd player && flutter test test/presentation/screens/sources/source_item_screen_test.dart"`
Expected: Fails because `source-item-download` is not rendered on `SourceItemScreen`.

- [ ] **Step 7: Add `_DownloadButton` to `player/lib/presentation/screens/sources/source_item_screen.dart`**

Modify `player/lib/presentation/screens/sources/source_item_screen.dart`:
1. Add imports:
```dart
import '../../../core/downloads/download_providers.dart';
import '../../../domain/models/download_item.dart';
import '../detail/start_download.dart';
```
2. In `_Body.build(BuildContext context, WidgetRef ref)`, compute `canDownload`:
```dart
    final canDownload = !isFolder &&
        version != null &&
        source != null &&
        source.capabilities.contains(SourceCapability.downloadable);
```
3. In the `Wrap` children list (right after the `_WatchedButton` entry), add:
```dart
                  if (canDownload)
                    _DownloadButton(
                      key: const Key('source-item-download'),
                      detail: detail,
                      versionId: version.id,
                    ),
```
4. Add the `_DownloadButton` widget class in `player/lib/presentation/screens/sources/source_item_screen.dart`:
```dart
class _DownloadButton extends ConsumerWidget {
  const _DownloadButton({
    super.key,
    required this.detail,
    required this.versionId,
  });

  final ItemDetail detail;
  final String versionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final s = detail.summary;
    final mediaType = s.ref.kind == ItemKind.episode ? 'episode' : 'movie';
    final downloads = ref.watch(allDownloadsProvider).valueOrNull ?? const [];
    final existing = downloads
        .where((d) =>
            d.sourceAccountId == s.ref.sourceId.value &&
            d.mediaType == mediaType &&
            d.mediaId == s.ref.externalId)
        .firstOrNull;

    final (IconData icon, String label, bool enabled) = switch (existing?.status) {
      DownloadStatus.completed => (Icons.download_done, l10n.downloaded, false),
      DownloadStatus.downloading ||
      DownloadStatus.queued ||
      DownloadStatus.preparing =>
        (Icons.downloading, l10n.downloading, false),
      _ => (Icons.download_outlined, l10n.download, true),
    };

    return OutlinedButton.icon(
      onPressed: enabled
          ? () => startItemDownload(
                context,
                ref,
                item: s.ref,
                versionId: versionId,
                title: s.title,
                subtitle: s.episode != null
                    ? 'S${s.episode!.seasonNumber} · E${s.episode!.episodeNumber}'
                    : null,
                posterUrl: s.poster?.url,
                year: s.year,
                durationSeconds: s.durationSeconds,
              )
          : null,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}
```

- [ ] **Step 8: Run `source_item_screen_test.dart` to verify it passes**

Run: `devenv shell -- bash -c "cd player && flutter test test/presentation/screens/sources/source_item_screen_test.dart"`
Expected: All tests PASS.

- [ ] **Step 9: Commit Task 1**

Run:
```bash
devenv shell -- git add \
  player/lib/core/sources/original_download.dart \
  player/lib/core/sources/files/files_media_source.dart \
  player/lib/presentation/screens/sources/source_item_screen.dart \
  player/test/core/sources/files/files_download_test.dart \
  player/test/presentation/screens/sources/source_item_screen_test.dart
devenv shell -- git commit -m "feat(player): support offline downloads for network files libraries"
devenv shell -- git show --stat HEAD
```

---

### Task 2: Pure-Dart SRT-to-WebVTT Converter (`subtitle_vtt.dart`)

**Files:**
- Create: `player/lib/core/sources/files/cast/subtitle_vtt.dart`
- Create: `player/test/core/sources/files/cast/subtitle_vtt_test.dart`

- [ ] **Step 1: Write failing unit tests in `player/test/core/sources/files/cast/subtitle_vtt_test.dart`**

Create `player/test/core/sources/files/cast/subtitle_vtt_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/cast/subtitle_vtt.dart';

void main() {
  test('converts SRT cues and timestamps to WebVTT', () {
    const srt = '1\r\n'
        '00:00:01,050 --> 00:00:04,200\r\n'
        'Welcome to Copper Valley.\r\n'
        '\r\n'
        '2\r\n'
        '00:01:12,000 --> 00:01:15,500 line:90%\r\n'
        '<i>Morning</i> by the river.\r\n';

    final vtt = toWebVtt(srt, format: 'srt');
    expect(
      vtt,
      'WEBVTT\n\n'
      '1\n'
      '00:00:01.050 --> 00:00:04.200\n'
      'Welcome to Copper Valley.\n\n'
      '2\n'
      '00:01:12.000 --> 00:01:15.500 line:90%\n'
      '<i>Morning</i> by the river.\n',
    );
  });

  test('strips UTF-8 BOM from SRT and does not touch commas in dialogue', () {
    const srt = '\uFEFF1\n'
        '00:00:05,000 --> 00:00:08,125\n'
        'Wait, wait, wait --> 00:00:09,000 is not a timing line.\n';

    final vtt = toWebVtt(srt, format: 'srt');
    expect(vtt, startsWith('WEBVTT\n\n1\n00:00:05.000 --> 00:00:08.125\n'));
    expect(
      vtt,
      contains('Wait, wait, wait --> 00:00:09,000 is not a timing line.'),
    );
  });

  test('normalizes existing WebVTT and ensures WEBVTT header', () {
    const rawVtt = '\uFEFFWEBVTT - Harbor Lights\r\n\r\n'
        '00:00:01.000 --> 00:00:02.000\r\n'
        'Hello.\r\n';
    expect(
      toWebVtt(rawVtt, format: 'vtt'),
      'WEBVTT - Harbor Lights\n\n'
      '00:00:01.000 --> 00:00:02.000\n'
      'Hello.\n',
    );

    const headerlessVtt = '00:00:01.000 --> 00:00:02.000\nHello.';
    expect(
      toWebVtt(headerlessVtt, format: 'vtt'),
      'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHello.\n',
    );
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `devenv shell -- bash -c "cd player && flutter test test/core/sources/files/cast/subtitle_vtt_test.dart"`
Expected: Fails because `package:player/core/sources/files/cast/subtitle_vtt.dart` does not exist.

- [ ] **Step 3: Implement `player/lib/core/sources/files/cast/subtitle_vtt.dart`**

Create `player/lib/core/sources/files/cast/subtitle_vtt.dart`:

```dart
final _srtTimingLine = RegExp(
  r'^(\d{1,2}:\d{2}:\d{2})[,.](\d{3})(\s*-->\s*)(\d{1,2}:\d{2}:\d{2})[,.](\d{3})(.*)$',
);

/// Converts a `.srt` or `.vtt` subtitle payload into a valid UTF-8 WebVTT
/// document suitable for Chromecast `<track>` elements.
String toWebVtt(String raw, {required String format}) {
  var text = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
  text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();

  if (format.toLowerCase() == 'vtt') {
    if (text.startsWith('WEBVTT')) {
      return '$text\n';
    }
    return 'WEBVTT\n\n$text\n';
  }

  if (text.isEmpty) return 'WEBVTT\n';

  final lines = text.split('\n');
  final buffer = StringBuffer('WEBVTT\n\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final match = _srtTimingLine.firstMatch(line);
    if (match != null) {
      buffer
        ..write(match.group(1))
        ..write('.')
        ..write(match.group(2))
        ..write(match.group(3))
        ..write(match.group(4))
        ..write('.')
        ..write(match.group(5))
        ..writeln(match.group(6));
    } else {
      buffer.writeln(line);
    }
  }
  return buffer.toString();
}
```

- [ ] **Step 4: Run `subtitle_vtt_test.dart` to verify it passes**

Run: `devenv shell -- bash -c "cd player && flutter test test/core/sources/files/cast/subtitle_vtt_test.dart"`
Expected: All tests PASS.

- [ ] **Step 5: Commit Task 2**

Run:
```bash
devenv shell -- git add \
  player/lib/core/sources/files/cast/subtitle_vtt.dart \
  player/test/core/sources/files/cast/subtitle_vtt_test.dart
devenv shell -- git commit -m "feat(player): add SRT to WebVTT converter for files casting"
devenv shell -- git show --stat HEAD
```

---

### Task 3: `FilesCastBridge` LAN HTTP Server

**Files:**
- Create: `player/lib/core/sources/files/cast/files_cast_bridge.dart`
- Modify: `player/lib/core/sources/files/files_providers.dart`
- Create: `player/test/core/sources/files/cast/files_cast_bridge_test.dart`

- [ ] **Step 1: Write failing unit tests in `player/test/core/sources/files/cast/files_cast_bridge_test.dart`**

Create `player/test/core/sources/files/cast/files_cast_bridge_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:player/core/p2p/media_proxy.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/cast/files_cast_bridge.dart';

void main() {
  late Directory tempDir;
  late File localVideo;
  late FilesCastBridge bridge;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('files_cast_bridge_test');
    localVideo = File('${tempDir.path}/copper_valley.mp4');
    await localVideo.writeAsBytes(List<int>.generate(100, (i) => i));
    bridge = FilesCastBridge(
      lanAddressResolver: () async => '127.0.0.1',
    );
  });

  tearDown(() async {
    await bridge.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('serves local file full GET, HEAD, 206 byte ranges, and 416 out-of-range',
      () async {
    final session = await bridge.openSession(
      media: PlayableFile(url: Uri.file(localVideo.path).toString()),
      mime: 'video/mp4',
      subtitles: const {},
    );
    expect(bridge.activePort, isNotNull);
    expect(session.mediaUrl, contains('http://127.0.0.1:${bridge.activePort}/f/'));

    // Full GET
    final full = await http.get(Uri.parse(session.mediaUrl));
    expect(full.statusCode, HttpStatus.ok);
    expect(full.headers['accept-ranges'], 'bytes');
    expect(full.headers['content-type'], startsWith('video/mp4'));
    expect(full.headers['access-control-allow-origin'], '*');
    expect(full.bodyBytes, hasLength(100));
    expect(full.bodyBytes.first, 0);
    expect(full.bodyBytes.last, 99);

    // HEAD
    final head = await http.head(Uri.parse(session.mediaUrl));
    expect(head.statusCode, HttpStatus.ok);
    expect(head.headers['content-length'], '100');
    expect(head.bodyBytes, isEmpty);

    // Partial GET (bytes=10-19)
    final partial = await http.get(
      Uri.parse(session.mediaUrl),
      headers: const {'Range': 'bytes=10-19'},
    );
    expect(partial.statusCode, HttpStatus.partialContent);
    expect(partial.headers['content-range'], 'bytes 10-19/100');
    expect(partial.headers['content-length'], '10');
    expect(partial.bodyBytes, List<int>.generate(10, (i) => i + 10));

    // Open-ended range (bytes=95-)
    final tail = await http.get(
      Uri.parse(session.mediaUrl),
      headers: const {'Range': 'bytes=95-'},
    );
    expect(tail.statusCode, HttpStatus.partialContent);
    expect(tail.headers['content-range'], 'bytes 95-99/100');
    expect(tail.bodyBytes, [95, 96, 97, 98, 99]);

    // Unsatisfiable range (bytes=200-300)
    final badRange = await http.get(
      Uri.parse(session.mediaUrl),
      headers: const {'Range': 'bytes=200-300'},
    );
    expect(badRange.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(badRange.headers['content-range'], 'bytes */100');

    // Wrong token -> 403
    final wrongToken = session.mediaUrl.replaceFirst('/f/', '/f/bad');
    final forbidden = await http.get(Uri.parse(wrongToken));
    expect(forbidden.statusCode, HttpStatus.forbidden);

    await bridge.closeSession(session.sessionId);
    expect(bridge.activePort, isNull);
  });

  test('proxies upstream HTTP/SMB streams with auth and Range headers',
      () async {
    String? seenAuth;
    String? seenRange;
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    upstream.listen((req) async {
      seenAuth = req.headers.value(HttpHeaders.authorizationHeader);
      seenRange = req.headers.value(HttpHeaders.rangeHeader);
      req.response.statusCode =
          seenRange != null ? HttpStatus.partialContent : HttpStatus.ok;
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (seenRange != null) {
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 5-9/20');
        req.response.headers.contentLength = 5;
        req.response.add([5, 6, 7, 8, 9]);
      } else {
        req.response.headers.contentLength = 20;
        req.response.add(List<int>.generate(20, (i) => i));
      }
      await req.response.close();
    });

    final session = await bridge.openSession(
      media: PlayableFile(
        url: 'http://127.0.0.1:${upstream.port}/share/film.mkv',
        headers: const {'Authorization': 'Basic c2VjcmV0'},
      ),
      mime: 'video/x-matroska',
      subtitles: const {},
    );

    final resp = await http.get(
      Uri.parse(session.mediaUrl),
      headers: const {'Range': 'bytes=5-9'},
    );
    expect(resp.statusCode, HttpStatus.partialContent);
    expect(seenAuth, 'Basic c2VjcmV0');
    expect(seenRange, 'bytes=5-9');
    expect(resp.headers['content-range'], 'bytes 5-9/20');
    expect(resp.bodyBytes, [5, 6, 7, 8, 9]);
  });

  test('serves SRT sidecars converted to WebVTT with CORS headers', () async {
    final srtFile = File('${tempDir.path}/copper_valley.en.srt');
    await srtFile.writeAsString(
      '1\r\n00:00:01,250 --> 00:00:03,500\r\nCafé by the harbor\r\n',
      encoding: utf8,
    );

    final session = await bridge.openSession(
      media: PlayableFile(url: Uri.file(localVideo.path).toString()),
      mime: 'video/mp4',
      subtitles: {
        'ext-0': FilesCastSubtitle(
          file: PlayableFile(url: Uri.file(srtFile.path).toString()),
          format: 'srt',
        ),
      },
    );

    final subUrl = session.subtitleUrl('ext-0');
    final resp = await http.get(Uri.parse(subUrl));
    expect(resp.statusCode, HttpStatus.ok);
    expect(resp.headers['content-type'], contains('text/vtt'));
    expect(resp.headers['access-control-allow-origin'], '*');
    final text = utf8.decode(resp.bodyBytes);
    expect(text, startsWith('WEBVTT\n\n'));
    expect(text, contains('00:00:01.250 --> 00:00:03.500'));
    expect(text, contains('Café by the harbor'));
  });

  test('opening a second session replaces the first and closing stale id is a no-op',
      () async {
    final first = await bridge.openSession(
      media: PlayableFile(url: Uri.file(localVideo.path).toString()),
      mime: 'video/mp4',
      subtitles: const {},
    );
    final second = await bridge.openSession(
      media: PlayableFile(url: Uri.file(localVideo.path).toString()),
      mime: 'video/mp4',
      subtitles: const {},
    );

    // First session token is no longer valid
    final oldResp = await http.get(Uri.parse(first.mediaUrl));
    expect(oldResp.statusCode, HttpStatus.forbidden);

    // Closing stale session ID does not tear down the active second session
    await bridge.closeSession(first.sessionId);
    expect(bridge.activePort, isNotNull);

    final newResp = await http.get(Uri.parse(second.mediaUrl));
    expect(newResp.statusCode, HttpStatus.ok);
  });

  test('healListener rebinds on the same port when the socket is dropped',
      () async {
    final session = await bridge.openSession(
      media: PlayableFile(url: Uri.file(localVideo.path).toString()),
      mime: 'video/mp4',
      subtitles: const {},
    );
    final originalPort = bridge.activePort;

    await bridge.debugDropListener();
    final heal = await bridge.healListener();
    expect(heal, anyOf(ProxyHeal.reboundSamePort, ProxyHeal.reboundNewPort));
    if (heal == ProxyHeal.reboundSamePort) {
      expect(bridge.activePort, originalPort);
      final resp = await http.get(Uri.parse(session.mediaUrl));
      expect(resp.statusCode, HttpStatus.ok);
    }
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `devenv shell -- bash -c "cd player && flutter test test/core/sources/files/cast/files_cast_bridge_test.dart"`
Expected: Fails because `package:player/core/sources/files/cast/files_cast_bridge.dart` does not exist.

- [ ] **Step 3: Implement `player/lib/core/sources/files/cast/files_cast_bridge.dart` and register `filesCastBridgeProvider` in `files_providers.dart`**

Create `player/lib/core/sources/files/cast/files_cast_bridge.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../p2p/local_proxy_service.dart';
import '../../../p2p/media_proxy.dart';
import '../backend/file_system_backend.dart';
import 'subtitle_vtt.dart';

/// A sidecar subtitle track registered on a [FilesCastBridge] session.
class FilesCastSubtitle {
  const FilesCastSubtitle({
    required this.file,
    required this.format,
  });

  final PlayableFile file;
  final String format;
}

/// Active session handle returned by [FilesCastBridge.openSession].
class FilesCastSession {
  const FilesCastSession({
    required this.sessionId,
    required this.baseUrl,
    required this.token,
    required this.containerExtension,
  });

  final String sessionId;
  final String baseUrl;
  final String token;
  final String containerExtension;

  String get mediaUrl => '$baseUrl/f/$token/media.$containerExtension';

  String subtitleUrl(String trackId) =>
      '$baseUrl/f/$token/sub/${Uri.encodeComponent(trackId)}.vtt';
}

class _ActiveSession {
  _ActiveSession({
    required this.sessionId,
    required this.token,
    required this.media,
    required this.mime,
    required this.subtitles,
  });

  final String sessionId;
  final String token;
  final PlayableFile media;
  final String mime;
  final Map<String, FilesCastSubtitle> subtitles;
}

/// On-demand LAN HTTP server that bridges `SourceKind.files` media and sidecar
/// subtitles to Chromecast and DLNA receivers on the local network.
///
/// The listener is bound to [InternetAddress.anyIPv4] on an ephemeral port
/// only while a cast session is active, and closed as soon as [closeSession]
/// or [dispose] tears the session down.
class FilesCastBridge {
  FilesCastBridge({
    Future<String?> Function()? lanAddressResolver,
    http.Client? client,
  })  : _lanAddressResolver =
            lanAddressResolver ?? LocalProxyService.resolveLanAddress,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final Future<String?> Function() _lanAddressResolver;
  final http.Client _client;
  final bool _ownsClient;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _listener;
  int? _boundPort;
  _ActiveSession? _session;
  int _sessionCounter = 0;
  Future<ProxyHeal>? _healing;

  /// The LAN port currently bound for an active cast session, or `null` when
  /// no `files` cast is active.
  int? get activePort => _server != null ? _boundPort : null;

  /// Opens (or replaces) the active cast bridge session and returns its LAN
  /// URLs. Throws a [StateError] if no private IPv4 LAN interface is available.
  Future<FilesCastSession> openSession({
    required PlayableFile media,
    required String mime,
    required Map<String, FilesCastSubtitle> subtitles,
  }) async {
    final lanIp = await _lanAddressResolver();
    if (lanIp == null) {
      throw StateError('No LAN network interface available for casting');
    }

    await _ensureBound();
    final port = _boundPort!;
    final sessionId = 'files-cast-${++_sessionCounter}';
    final token = _generateToken();
    _session = _ActiveSession(
      sessionId: sessionId,
      token: token,
      media: media,
      mime: mime,
      subtitles: Map.unmodifiable(subtitles),
    );

    return FilesCastSession(
      sessionId: sessionId,
      baseUrl: 'http://$lanIp:$port',
      token: token,
      containerExtension: _extensionForMime(mime, media.url),
    );
  }

  /// Closes [sessionId] if it is still the active session and shuts down the
  /// LAN listener.
  Future<void> closeSession(String sessionId) async {
    final current = _session;
    if (current == null || current.sessionId != sessionId) return;
    _session = null;
    await _closeServer();
  }

  /// Probes the active listener and rebinds if the OS reclaimed the socket
  /// while the app was backgrounded.
  Future<ProxyHeal> healListener() {
    return _healing ??= _heal().whenComplete(() => _healing = null);
  }

  Future<ProxyHeal> _heal() async {
    final server = _server;
    final port = _boundPort;
    if (server == null || port == null || _session == null) {
      return ProxyHeal.healthy;
    }
    if (await _accepting(port)) {
      return ProxyHeal.healthy;
    }
    if (!identical(_server, server) || _session == null) {
      return ProxyHeal.healthy;
    }

    await _closeServer();
    var samePort = true;
    HttpServer fresh;
    try {
      fresh = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      samePort = false;
      fresh = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    if (_session == null) {
      await fresh.close(force: true);
      return ProxyHeal.healthy;
    }
    _adopt(fresh);
    return samePort ? ProxyHeal.reboundSamePort : ProxyHeal.reboundNewPort;
  }

  @visibleForTesting
  Future<void> debugDropListener() async {
    await _listener?.cancel();
    await _server?.close(force: true);
  }

  Future<void> dispose() async {
    _session = null;
    await _closeServer();
    if (_ownsClient) {
      _client.close();
    }
  }

  Future<void> _ensureBound() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _adopt(server);
  }

  void _adopt(HttpServer server) {
    _server = server;
    _boundPort = server.port;
    _listener = server.listen(
      _handleRequest,
      onError: (Object e) => debugPrint('[FilesCastBridge] Listener error: $e'),
    );
  }

  Future<void> _closeServer() async {
    final listener = _listener;
    final server = _server;
    _listener = null;
    _server = null;
    _boundPort = null;
    await listener?.cancel();
    await server?.close(force: true);
  }

  static Future<bool> _accepting(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 1),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    _setCorsHeaders(response);

    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }

    final session = _session;
    final segments = request.uri.pathSegments;
    // Expected routes:
    //   /f/<token>/media.<ext>
    //   /f/<token>/sub/<trackId>.vtt
    if (session == null ||
        segments.length < 3 ||
        segments[0] != 'f' ||
        segments[1] != session.token) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }

    try {
      if (segments.length == 3 && segments[2].startsWith('media.')) {
        await _serveMedia(request, session);
        return;
      }
      if (segments.length == 4 &&
          segments[2] == 'sub' &&
          segments[3].endsWith('.vtt')) {
        final rawTrack = segments[3].substring(0, segments[3].length - 4);
        final trackId = Uri.decodeComponent(rawTrack);
        await _serveSubtitle(request, session, trackId);
        return;
      }
      response.statusCode = HttpStatus.notFound;
      await response.close();
    } catch (e) {
      debugPrint('[FilesCastBridge] Request error: $e');
      try {
        response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _serveMedia(
    HttpRequest request,
    _ActiveSession session,
  ) async {
    final uri = Uri.parse(session.media.url);
    if (uri.scheme == 'file') {
      await _serveLocalFile(request, File(uri.toFilePath()), session.mime);
    } else {
      await _proxyHttpMedia(request, uri, session.media.headers, session.mime);
    }
  }

  Future<void> _serveLocalFile(
    HttpRequest request,
    File file,
    String mime,
  ) async {
    final response = request.response;
    if (!await file.exists()) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final length = await file.length();
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.contentTypeHeader, mime);

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader == null) {
      response.statusCode = HttpStatus.ok;
      response.headers.contentLength = length;
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      await response.addStream(file.openRead());
      await response.close();
      return;
    }

    final parsed = _parseRange(rangeHeader, length);
    if (parsed == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      response.headers.contentLength = 0;
      await response.close();
      return;
    }

    final (start, endInclusive) = parsed;
    final sliceLength = endInclusive - start + 1;
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$endInclusive/$length',
    );
    response.headers.contentLength = sliceLength;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    await response.addStream(file.openRead(start, endInclusive + 1));
    await response.close();
  }

  Future<void> _proxyHttpMedia(
    HttpRequest request,
    Uri upstreamUri,
    Map<String, String> authHeaders,
    String fallbackMime,
  ) async {
    final response = request.response;
    final upstreamReq = http.Request(request.method, upstreamUri);
    upstreamReq.headers.addAll(authHeaders);
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      upstreamReq.headers[HttpHeaders.rangeHeader] = range;
    }

    final upstreamResp = await _client.send(upstreamReq);
    response.statusCode = upstreamResp.statusCode;
    response.headers.set(
      HttpHeaders.acceptRangesHeader,
      upstreamResp.headers['accept-ranges'] ?? 'bytes',
    );
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      upstreamResp.headers['content-type'] ?? fallbackMime,
    );
    final contentRange = upstreamResp.headers['content-range'];
    if (contentRange != null) {
      response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
    }
    final contentLength = upstreamResp.contentLength;
    if (contentLength != null && contentLength >= 0) {
      response.headers.contentLength = contentLength;
    }

    if (request.method == 'HEAD') {
      await upstreamResp.stream.drain<void>();
      await response.close();
      return;
    }

    await response.addStream(upstreamResp.stream);
    await response.close();
  }

  Future<void> _serveSubtitle(
    HttpRequest request,
    _ActiveSession session,
    String trackId,
  ) async {
    final response = request.response;
    final sub = session.subtitles[trackId];
    if (sub == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final rawText = await _readSubtitleText(sub.file);
    if (rawText == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final vttBytes = utf8.encode(toWebVtt(rawText, format: sub.format));
    response.statusCode = HttpStatus.ok;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/vtt; charset=utf-8',
    );
    response.headers.contentLength = vttBytes.length;
    if (request.method != 'HEAD') {
      response.add(vttBytes);
    }
    await response.close();
  }

  Future<String?> _readSubtitleText(PlayableFile playable) async {
    final uri = Uri.parse(playable.url);
    if (uri.scheme == 'file') {
      final file = File(uri.toFilePath());
      if (!await file.exists()) return null;
      return utf8.decode(await file.readAsBytes(), allowMalformed: true);
    }
    final resp = await _client.get(uri, headers: playable.headers);
    if (resp.statusCode != HttpStatus.ok) return null;
    return utf8.decode(resp.bodyBytes, allowMalformed: true);
  }

  static void _setCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Range, Content-Type');
    response.headers.set(
      'Access-Control-Expose-Headers',
      'Content-Length, Content-Range, Accept-Ranges',
    );
  }

  /// Parses `bytes=start-end` or `bytes=start-` against [totalLength].
  /// Returns `(start, endInclusive)` or `null` when unsatisfiable.
  static (int, int)? _parseRange(String header, int totalLength) {
    if (totalLength <= 0) return null;
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    if (start == null || start < 0 || start >= totalLength) return null;
    final endStr = match.group(2)!;
    final end = endStr.isEmpty ? totalLength - 1 : int.tryParse(endStr);
    if (end == null || end < start) return null;
    final clampedEnd = end >= totalLength ? totalLength - 1 : end;
    return (start, clampedEnd);
  }

  static String _extensionForMime(String mime, String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final ext in ['mp4', 'm4v', 'mkv', 'webm', 'mov', 'avi', 'ts']) {
      if (path.endsWith('.$ext')) return ext;
    }
    return switch (mime.toLowerCase()) {
      'video/x-matroska' => 'mkv',
      'video/webm' => 'webm',
      'video/quicktime' => 'mov',
      'video/mp2t' => 'ts',
      'video/x-msvideo' => 'avi',
      _ => 'mp4',
    };
  }

  static String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
```

In `player/lib/core/sources/files/files_providers.dart`, import `cast/files_cast_bridge.dart` and add `filesCastBridgeProvider`:
```dart
import 'cast/files_cast_bridge.dart';
```
And near `smbNativeProvider`:
```dart
/// LAN HTTP range bridge used when casting a `SourceKind.files` item to a
/// Chromecast or DLNA receiver.
final filesCastBridgeProvider = Provider<FilesCastBridge>((ref) {
  final bridge = FilesCastBridge();
  ref.onDispose(bridge.dispose);
  return bridge;
});
```

- [ ] **Step 4: Run `files_cast_bridge_test.dart` to verify it passes**

Run: `devenv shell -- bash -c "cd player && flutter test test/core/sources/files/cast/files_cast_bridge_test.dart"`
Expected: All tests PASS.

- [ ] **Step 5: Commit Task 3**

Run:
```bash
devenv shell -- git add \
  player/lib/core/sources/files/cast/files_cast_bridge.dart \
  player/lib/core/sources/files/files_providers.dart \
  player/test/core/sources/files/cast/files_cast_bridge_test.dart
devenv shell -- git commit -m "feat(player): add FilesCastBridge LAN HTTP server for files casting"
devenv shell -- git show --stat HEAD
```

---

### Task 4: Wire `FilesPlaybackSession`, `SessionSourceCastBinding`, `CastSessionManager`, `cast_actions.dart`, and `app.dart`

**Files:**
- Modify: `player/lib/core/playback/simple_playback_transport.dart`
- Modify: `player/lib/presentation/screens/player/session/source_playback_session.dart`
- Modify: `player/lib/presentation/screens/player/session/files_playback_session.dart`
- Modify: `player/lib/presentation/screens/player/session/source_playback_sessions.dart`
- Modify: `player/lib/presentation/screens/player/session/source_cast_binding_impl.dart`
- Modify: `player/lib/core/cast/cast_session_manager.dart`
- Modify: `player/lib/presentation/widgets/cast_actions.dart`
- Modify: `player/lib/app.dart`
- Modify: `player/test/presentation/screens/player/session/files_playback_session_test.dart`
- Modify: `player/test/presentation/screens/player/session/source_cast_binding_impl_test.dart`
- Modify: `player/test/core/cast/cast_session_manager_source_test.dart`

- [ ] **Step 1: Write failing tests for `FilesPlaybackSession`, `SessionSourceCastBinding`, and `CastSessionManager`**

1. In `player/test/presentation/screens/player/session/files_playback_session_test.dart`, add imports for `package:player/core/sources/files/cast/files_cast_bridge.dart` and add a test at the bottom of `main()`:

```dart
  test('cast resolution opens a FilesCastBridge session with subtitle URLs and closes it',
      () async {
    final b = await _build(_AuthBackend({_file: 10, _sidecar: 5}));
    final bridge = FilesCastBridge(lanAddressResolver: () async => '127.0.0.1');
    addTearDown(bridge.dispose);

    final session = FilesPlaybackSession(
      source: b.source,
      item: movie(b),
      fileId: key,
      bridge: bridge,
    );
    expect(session.castsAsProgressive, isTrue);

    final resolved = await session.createResolver().resolve(
          const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
          fileId: key,
          startAt: Duration.zero,
          forCast: true,
        );
    expect(bridge.activePort, isNotNull);
    expect(resolved.sessionId, isNotNull);
    expect(
      resolved.url,
      startsWith('http://127.0.0.1:${bridge.activePort}/f/'),
    );
    expect(resolved.url, endsWith('/media.mkv'));
    expect(resolved.subtitleUrl, isNotNull);
    expect(
      resolved.subtitleUrl!('ext-0'),
      endsWith('/sub/ext-0.vtt'),
    );

    await session.endServerSession(resolved.sessionId!);
    expect(bridge.activePort, isNull);
  });
```

2. In `player/test/presentation/screens/player/session/source_cast_binding_impl_test.dart`, add imports:
```dart
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/cast/files_cast_bridge.dart';
import 'package:player/core/sources/files/files_ids.dart';
import 'package:player/core/sources/files/files_media_source.dart';
import 'package:player/core/sources/files/match/file_matcher.dart';
import 'package:player/presentation/screens/player/session/files_playback_session.dart';

import '../../../../core/sources/files/fake_backend.dart';
import '../../../../core/sources/files/fake_media_names.dart';
import '../../../../core/sources/files/files_fixture.dart';
```
And add a `group('Files', ...)` block at the bottom of `main()` in `player/test/presentation/screens/player/session/source_cast_binding_impl_test.dart`:
```dart
  group('Files', () {
    const file = '${FilesFixture.rootPath}/Copper Valley (2018) 1080p.mkv';
    const sidecar =
        '${FilesFixture.rootPath}/Copper Valley (2018) 1080p.en.srt';
    final key =
        fileKeyFor(FilesFixture.rootId, 'Copper Valley (2018) 1080p.mkv');

    Future<(SessionSourceCastBinding, FilesCastBridge, FilesFixture)>
        openFiles() async {
      final f = await FilesFixture.create();
      final relay = FakeFilesRelay();
      final backend = FakeBackend({file: 100, sidecar: 20});
      final source = FilesMediaSource(
        source: filesLocalSource,
        backend: backend,
        index: f.index,
        progress: f.progress,
        matcher: FileMatcher(
          tmdb: relay,
          names: FakeMediaNames(),
          index: f.index,
          progress: f.progress,
          sourceId: f.sourceId,
        ),
        tmdb: relay,
        invalidate: (_) async {},
        l10n: () => filesL10n,
      );
      addTearDown(source.dispose);
      final bridge =
          FilesCastBridge(lanAddressResolver: () async => '127.0.0.1');
      addTearDown(bridge.dispose);
      final session = FilesPlaybackSession(
        source: source,
        item: f.ref(ItemKind.movie, '101'),
        fileId: key,
        bridge: bridge,
      );
      return (SessionSourceCastBinding(session), bridge, f);
    }

    test('Chromecast gets a progressive localBridge route and VTT sidecars',
        () async {
      final (binding, bridge, _) = await openFiles();
      final route = await binding.resolve(
        protocol: CastProtocolKind.chromecast,
        startPosition: Duration.zero,
        subtitleTrackId: null,
        forceTranscode: false,
      );
      expect(route.kind, CastRouteKind.localBridge);
      expect(route.mediaKind, CastMediaKind.progressive);
      expect(route.transcoded, isFalse);
      expect(route.hlsSessionId, isNotNull);
      expect(
        route.mediaUrl,
        startsWith('http://127.0.0.1:${bridge.activePort}/f/'),
      );
      expect(route.subtitles, hasLength(1));
      final sub = route.subtitles.single;
      expect(sub.trackId, 'ext-0');
      expect(sub.burnedIn, isFalse);
      expect(sub.url, endsWith('/sub/ext-0.vtt'));

      await binding.endServerSession(route.hlsSessionId!);
      expect(bridge.activePort, isNull);
    });

    test('DLNA gets a progressive localBridge route and no subtitles',
        () async {
      final (binding, bridge, _) = await openFiles();
      final route = await binding.resolve(
        protocol: CastProtocolKind.dlna,
        startPosition: Duration.zero,
        subtitleTrackId: null,
        forceTranscode: false,
      );
      expect(route.kind, CastRouteKind.localBridge);
      expect(route.mediaKind, CastMediaKind.progressive);
      expect(
        route.mediaUrl,
        startsWith('http://127.0.0.1:${bridge.activePort}/f/'),
      );
      expect(route.subtitles, isEmpty);
    });
  });
```

3. In `player/test/core/cast/cast_session_manager_source_test.dart`, add a `CastRouteKind routeKind = CastRouteKind.directServer;` field and `CastMediaKind mediaKind = CastMediaKind.hls;` field to `_FakeBinding`:
```dart
  CastRouteKind routeKind = CastRouteKind.directServer;
  CastMediaKind mediaKind = CastMediaKind.hls;
```
And use `kind: routeKind, mediaKind: mediaKind` in `_FakeBinding.resolve`, then add a test in `main()`:
```dart
  test('a localBridge source route is not retried with a transcode', () async {
    binding
      ..routeKind = CastRouteKind.localBridge
      ..mediaKind = CastMediaKind.progressive;
    backend.failNextLoad(CastFailureKind.mediaLoadFailed);
    final manager = build();

    await expectLater(
      manager.startCast(device: tv, request: request),
      throwsA(isA<CastBackendException>()),
    );
    expect(binding.resolves, hasLength(1));
  });
```

- [ ] **Step 2: Run the 3 test files to verify they fail**

Run:
```bash
devenv shell -- bash -c "cd player && flutter test \
  test/presentation/screens/player/session/files_playback_session_test.dart \
  test/presentation/screens/player/session/source_cast_binding_impl_test.dart \
  test/core/cast/cast_session_manager_source_test.dart"
```
Expected: Fails because `castsAsProgressive`, `ResolvedStream.subtitleUrl`, `FilesPlaybackSession(bridge: ...)`, and the `localBridge` retry guard do not exist yet.

- [ ] **Step 3: Implement the session, cast binding, manager, error message, and resume heal changes**

1. Update `ResolvedStream` in `player/lib/core/playback/simple_playback_transport.dart`:
```dart
class ResolvedStream {
  const ResolvedStream({
    required this.url,
    this.headers = const {},
    this.sessionId,
    this.subtitleUrl,
  });

  final String url;
  final Map<String, String> headers;

  /// Server transcode or local cast bridge session id, when the stream opened
  /// one that `stop` should end.
  final String? sessionId;

  /// Resolves a sidecar subtitle URL by track id when a cast bridge serves
  /// converted subtitles on its own endpoints.
  final String Function(String trackId)? subtitleUrl;
}
```

2. Update `SourcePlaybackSession` in `player/lib/presentation/screens/player/session/source_playback_session.dart` by adding:
```dart
  /// Whether Chromecast casts from this session use a progressive `DirectPlayPlan`
  /// served through a local LAN bridge rather than a server HLS transcode.
  bool get castsAsProgressive => false;
```

3. Update `player/lib/presentation/screens/player/session/files_playback_session.dart`:
- Import `../../../../core/sources/files/cast/files_cast_bridge.dart`.
- Update `FilesStreamResolver` to accept `FilesCastBridge? bridge`:
```dart
class FilesStreamResolver implements StreamUrlResolver {
  FilesStreamResolver({required this.source, this.bridge});

  final FilesMediaSource source;
  final FilesCastBridge? bridge;

  @override
  Future<ResolvedStream> resolve(
    PlaybackPlan plan, {
    required String fileId,
    required Duration startAt,
    String? audioTrackId,
    String? burnSubtitleTrackId,
    bool forCast = false,
  }) async {
    final file = await source.playableForFileKey(fileId);
    if (forCast && bridge != null) {
      final indexed = source.indexedFile(fileId);
      final root = indexed == null ? null : source.rootFor(indexed);
      final subtitles = <String, FilesCastSubtitle>{};
      if (indexed != null && root != null) {
        final streams = FilesCatalog.sidecarStreams(root, indexed);
        for (var i = 0; i < streams.length; i++) {
          final s = streams[i];
          final codec = (s.codec ?? 'srt').toLowerCase();
          if ((codec == 'srt' || codec == 'vtt') && s.externalPath != null) {
            final playableSub = await source.backend.playable(s.externalPath!);
            subtitles['ext-$i'] = FilesCastSubtitle(
              file: playableSub,
              format: codec,
            );
          }
        }
      }
      final mime =
          indexed == null ? 'video/mp4' : FilesCatalog.mimeOf(indexed.path);
      final session = await bridge!.openSession(
        media: file,
        mime: mime,
        subtitles: subtitles,
      );
      return ResolvedStream(
        url: session.mediaUrl,
        sessionId: session.sessionId,
        subtitleUrl: session.subtitleUrl,
      );
    }
    return ResolvedStream(url: file.url, headers: file.headers);
  }
}
```
- Update `FilesPlaybackSession` constructor and methods:
```dart
class FilesPlaybackSession extends SourcePlaybackSession {
  FilesPlaybackSession({
    required this.source,
    required this.item,
    required this.fileId,
    http.Client? client,
    this.bridge,
  }) : _client = client ?? http.Client();

  final FilesMediaSource source;
  final ItemRef item;
  final String fileId;
  final http.Client _client;
  final FilesCastBridge? bridge;

  @override
  Set<PlaybackFeature> get features => const {};

  @override
  bool get castsAsProgressive => true;

  @override
  bool get reachable => true;

  @override
  StreamUrlResolver createResolver() =>
      FilesStreamResolver(source: source, bridge: bridge);

  @override
  Future<void> endServerSession(String sessionId) async {
    await bridge?.closeSession(sessionId);
  }
```

4. Update `player/lib/presentation/screens/player/session/source_playback_sessions.dart`:
- Import `../../../../core/sources/files/files_providers.dart`.
- In `sourcePlaybackSessionProvider`:
```dart
    FilesMediaSource() => FilesPlaybackSession(
        source: source,
        item: key.item,
        fileId: key.fileId,
        bridge: ref.watch(filesCastBridgeProvider),
      ),
```
- In `openSourceSession`:
```dart
    FilesMediaSource() => FilesPlaybackSession(
        source: source,
        item: item,
        fileId: fileId,
        bridge: ref.read(filesCastBridgeProvider),
      ),
```

5. Update `SessionSourceCastBinding.resolve` in `player/lib/presentation/screens/player/session/source_cast_binding_impl.dart`:
```dart
  @override
  Future<CastRoute> resolve({
    required CastProtocolKind protocol,
    required Duration startPosition,
    required String? subtitleTrackId,
    required bool forceTranscode,
  }) async {
    final bool isDlna = protocol == CastProtocolKind.dlna;
    final bool isProgressiveBridge = _session.castsAsProgressive;
    final detail = await _loadDetail();
    var subtitles =
        isDlna ? const <CastSubtitleTrack>[] : _subtitlesFrom(detail);
    final selected = subtitleTrackId == null
        ? null
        : subtitles.where((t) => t.trackId == subtitleTrackId).firstOrNull;
    final burnId = selected != null && selected.burnedIn ? selected.trackId : null;

    final PlaybackPlan plan;
    if (isDlna || isProgressiveBridge) {
      plan = const DirectPlayPlan(reason: PlanReason.directPlayAccepted);
    } else {
      final copyOk =
          !forceTranscode && burnId == null && await _canCopyVideo();
      plan = TranscodePlan(
        reason: burnId != null
            ? PlanReason.subtitleBurnIn
            : copyOk
                ? PlanReason.remuxOnly
                : PlanReason.codecUnsupported,
        canCopyVideo: copyOk,
        canCopyAudio: false,
      );
    }

    final stream = await _resolveStream(
      plan,
      startAt: startPosition,
      burnSubtitleTrackId: burnId,
    );
    if (stream.subtitleUrl != null && subtitles.isNotEmpty) {
      subtitles = [
        for (final track in subtitles)
          if (!track.burnedIn)
            track.copyWith(url: stream.subtitleUrl!(track.trackId)),
      ];
    }
    return CastRoute(
      mediaUrl: stream.url,
      kind: isProgressiveBridge
          ? CastRouteKind.localBridge
          : CastRouteKind.directServer,
      mediaKind: (isDlna || isProgressiveBridge)
          ? CastMediaKind.progressive
          : CastMediaKind.hls,
      hlsSessionId: stream.sessionId,
      subtitles: subtitles,
      transcoded: !isDlna && !isProgressiveBridge && !(plan as TranscodePlan).canCopyVideo,
    );
  }
```

6. Update `CastSessionManager._retryRouteFor` in `player/lib/core/cast/cast_session_manager.dart`:
```dart
      case SourceCastContent():
        if (binding == null ||
            protocol == CastProtocolKind.dlna ||
            attempted.kind == CastRouteKind.localBridge ||
            attempted.transcoded) {
          return null;
        }
        return binding.resolve(
          protocol: protocol,
          startPosition: request.startPosition,
          subtitleTrackId: request.subtitleTrackId,
          forceTranscode: true,
        );
```

7. Update `castErrorMessage` in `player/lib/presentation/widgets/cast_actions.dart`:
- Import `../../core/sources/files/files_providers.dart`.
- Update the port lookup in `castErrorMessage`:
```dart
      if (ref != null) {
        final proxy = ref.read(localProxyServiceProvider);
        final port = proxy.isLanAccessible
            ? Uri.tryParse(proxy.baseUrl)?.port
            : ref.read(filesCastBridgeProvider).activePort;
        if (port != null) {
          return l10n.castMediaLoadFailedFirewall(port);
        }
      }
```

8. Update `_AppState.didChangeAppLifecycleState` in `player/lib/app.dart`:
```dart
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // iOS and Android can drop a backgrounded app's listening sockets while
      // leaving their Dart/Rust handles looking alive. Probing on resume
      // rebinds any dead listener before the user taps Play.
      unawaited(ref.read(mediaProxyProvider).healListener().catchError((_) =>
          ProxyHeal.healthy));
      unawaited(ref.read(smbNativeProvider).healListener().catchError((_) =>
          ProxyHeal.healthy));
      unawaited(ref.read(filesCastBridgeProvider).healListener().catchError(
          (_) => ProxyHeal.healthy));
    }
  }
```

- [ ] **Step 4: Run the test suite for all touched areas**

Run:
```bash
devenv shell -- bash -c "cd player && flutter test \
  test/core/sources/files/ \
  test/presentation/screens/player/session/files_playback_session_test.dart \
  test/presentation/screens/player/session/source_cast_binding_impl_test.dart \
  test/core/cast/cast_session_manager_source_test.dart \
  test/presentation/screens/sources/source_item_screen_test.dart"
```
Expected: Every test in all 5 targets PASSES.

- [ ] **Step 5: Run `dart analyze` across `player/`**

Run: `devenv shell -- bash -c "cd player && dart analyze"`
Expected: `No issues found!`

- [ ] **Step 6: Commit Task 4**

Run:
```bash
devenv shell -- git add \
  player/lib/core/playback/simple_playback_transport.dart \
  player/lib/presentation/screens/player/session/source_playback_session.dart \
  player/lib/presentation/screens/player/session/files_playback_session.dart \
  player/lib/presentation/screens/player/session/source_playback_sessions.dart \
  player/lib/presentation/screens/player/session/source_cast_binding_impl.dart \
  player/lib/core/cast/cast_session_manager.dart \
  player/lib/presentation/widgets/cast_actions.dart \
  player/lib/app.dart \
  player/test/presentation/screens/player/session/files_playback_session_test.dart \
  player/test/presentation/screens/player/session/source_cast_binding_impl_test.dart \
  player/test/core/cast/cast_session_manager_source_test.dart
devenv shell -- git commit -m "feat(player): wire FilesCastBridge into files playback session and cast manager"
devenv shell -- git show --stat HEAD
```
