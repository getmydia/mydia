import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/player/mpv_probe_mapping.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_ids.dart';
import 'package:player/core/sources/files/files_media_source.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/match/file_matcher.dart';
import 'package:player/core/sources/files/media_info/files_media_info_cache.dart';
import 'package:player/core/sources/files/peer_files_sources.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/media_stream.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/source_error.dart';

import 'fake_backend.dart';
import 'fake_media_names.dart';
import 'files_fixture.dart';
import 'peer_files_harness.dart';

const _probed = ProbeResult(
  container: 'matroska',
  durationSeconds: 5400,
  bitrate: 8000000,
  streams: [
    MediaStream(
      type: MediaStreamType.video,
      codec: 'hevc',
      height: 2160,
      width: 3840,
      isDefault: true,
    ),
    MediaStream(type: MediaStreamType.audio, codec: 'eac3', channels: 6),
  ],
);

/// A cache whose writes fail.
class _ThrowingCache extends FilesMediaInfoCache {
  _ThrowingCache(super.box);

  @override
  Future<void> put(String accountId, IndexedFile file, ProbeResult result) =>
      throw StateError('disk full');
}

class _Built {
  _Built(this.fixture, this.source, this.probe, this.cache);
  final FilesFixture fixture;
  final FilesMediaSource source;
  final FakeMediaProbe probe;
  final FilesMediaInfoCache cache;
}

Future<_Built> _build({ProbeResult? result, bool throwingCache = false}) async {
  final f = await FilesFixture.create();
  final relay = FakeFilesRelay();
  final probe = FakeMediaProbe(result);
  final cache = throwingCache
      ? _ThrowingCache(
          await Hive.openBox<Map<dynamic, dynamic>>('files_media_info_throw'))
      : await f.mediaInfoCache();
  final source = FilesMediaSource(
    source: filesLocalSource,
    backend: FakeBackend(const {}),
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
    l10n: () => filesL10n,
    probe: probe,
    mediaInfoCache: cache,
  );
  addTearDown(source.dispose);
  return _Built(f, source, probe, cache);
}

final _hdKey =
    fileKeyFor(FilesFixture.rootId, 'Copper Valley (2018) 1080p.mkv');

/// A backend whose play fails the way the test says.
class _FailingPlayBackend extends FakeBackend {
  _FailingPlayBackend(this.failure) : super({});

  final BackendFailure failure;

  @override
  Future<PlayableFile> playable(String path) async => throw failure;
}

Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('lists mediaInfo and answers from the index before any probe', () async {
    final b = await _build();
    expect(b.source.capabilities, contains(SourceCapability.mediaInfo));
    final info = b.source.as<MediaInfo>();
    expect(info, isNotNull);

    final ref = b.fixture.ref(
        ItemKind.video,
        unmatchedFileId(
            fileKeyFor(FilesFixture.rootId, 'loose/home video.mkv')));
    final files = await info?.mediaInfo(ref) ?? const [];
    expect(files, hasLength(1));
    final file = files.single;
    expect(file.id, fileKeyFor(FilesFixture.rootId, 'loose/home video.mkv'));
    expect(file.fileName, 'home video.mkv');
    expect(file.directory, '/media/mix/loose');
    expect(file.sizeBytes, 10);
    expect(file.container, 'mkv');
    expect(file.streams, isNull);
    expect(file.resolution, isNull);
    expect(file.codec, isNull);
  });

  test('probe fields override and are cached', () async {
    final b = await _build(result: _probed);
    final ref = b.fixture.ref(ItemKind.movie, '101');

    final first = await b.source.mediaInfo(ref);
    final hd = first.firstWhere((m) => m.id == _hdKey);
    expect(hd.container, 'matroska');
    expect(hd.durationSeconds, 5400);
    expect(hd.bitrate, 8000000);
    expect(hd.resolution, '2160p');
    expect(hd.codec, 'hevc');
    expect(hd.streams, hasLength(2));
    expect(b.probe.probed, hasLength(2));

    final hdFile = b.fixture.index.files()[_hdKey];
    expect(hdFile, isNotNull);
    if (hdFile != null) {
      expect(b.cache.get(filesLocalSource.account.id, hdFile)?.container,
          'matroska');
    }

    final again = await b.source.mediaInfo(ref);
    expect(b.probe.probed, hasLength(2));
    expect(again.firstWhere((m) => m.id == _hdKey).codec, 'hevc');
  });

  test('a cache write failure still returns the probe result', () async {
    final b = await _build(result: _probed, throwingCache: true);
    final files =
        await b.source.mediaInfo(b.fixture.ref(ItemKind.movie, '101'));
    final hd = files.firstWhere((m) => m.id == _hdKey);
    expect(hd.streams, hasLength(2));
    expect(hd.codec, 'hevc');
  });

  test('a failed probe gives streams null and is not cached', () async {
    final b = await _build();
    final ref = b.fixture.ref(ItemKind.movie, '102');

    final first = await b.source.mediaInfo(ref);
    expect(first.single.streams, isNull);
    expect(first.single.container, 'mkv');
    await b.source.mediaInfo(ref);
    expect(b.probe.probed, hasLength(2));
  });

  test('a movie with two versions gives two entries in version order',
      () async {
    final b = await _build();
    final ref = b.fixture.ref(ItemKind.movie, '101');
    final detail = await b.source.item(ref);
    final files = await b.source.mediaInfo(ref);
    expect(files.map((m) => m.id), detail.versions.map((v) => v.id));
    expect(files, hasLength(2));
  });

  test('a show gives an empty list; an unknown ref throws notFound', () async {
    final b = await _build(result: _probed);
    expect(
        await b.source.mediaInfo(b.fixture.ref(ItemKind.show, '201')), isEmpty);
    expect(b.probe.probed, isEmpty);
    await expectLater(
      b.source.mediaInfo(b.fixture.ref(ItemKind.movie, '999')),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.notFound)),
    );
  });

  test('two concurrent calls for the same file probe once', () async {
    final b = await _build(result: _probed);
    final gate = Completer<void>();
    b.probe.gate = gate;
    final ref = b.fixture.ref(ItemKind.movie, '102');

    final one = b.source.mediaInfo(ref);
    final two = b.source.mediaInfo(ref);
    await _settle();
    gate.complete();
    final results = await Future.wait([one, two]);
    expect(b.probe.probed, hasLength(1));
    expect(results.every((r) => r.single.codec == 'hevc'), isTrue);
  });

  test('a lent library whose host is unreachable throws the peer fault',
      () async {
    final h = PeerHarness(await FilesFixture.create());
    await h.seed();
    final lent = lentFlocal();
    h.backends[peerFilesSource(lent)] =
        _FailingPlayBackend(const BackendUnreachable('gone'));
    h.client.list.value = [lent];
    final c = await h.container();
    addTearDown(c.dispose);
    final id = c.read(sourcesProvider).last.id;
    final media = c.read(mediaSourceProvider(id));
    expect(media, isA<FilesMediaSource>());
    if (media is! FilesMediaSource) return;
    await _settle();

    final ref = ItemRef(sourceId: id, kind: ItemKind.movie, externalId: '301');
    await expectLater(
      media.mediaInfo(ref),
      throwsA(isA<SourceException>().having(
          (e) => e.fault, 'fault', SourceFault.peerFilesHostUnreachable)),
    );
  });

  test('external subtitles come from sidecars', () async {
    final b = await _build();
    final files =
        await b.source.mediaInfo(b.fixture.ref(ItemKind.movie, '101'));
    final hd = files.firstWhere((m) => m.id == _hdKey);
    final sub = hd.externalSubtitles.single;
    expect(sub.language, 'en');
    expect(sub.format, 'srt');
    expect(sub.embedded, isFalse);
    expect(sub.title, 'Copper Valley (2018) 1080p.en.srt');
  });
}
