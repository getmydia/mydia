import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/player/local_progress_reporter.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_media_source.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/match/file_matcher.dart';
import 'package:player/core/sources/cache/source_rules.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/player/session/files_playback_session.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';

import '../../../../core/sources/files/fake_backend.dart';
import '../../../../core/sources/files/fake_media_names.dart';
import '../../../../core/sources/files/files_fixture.dart';

class _AuthBackend extends FakeBackend {
  _AuthBackend(super.files);
  @override
  Future<PlayableFile> playable(String path) async => PlayableFile(
      url: 'https://dav.example$path', headers: {'Authorization': 'Basic x'});
}

class _Built {
  _Built(this.fixture, this.source, this.invalidated);
  final FilesFixture fixture;
  final FilesMediaSource source;
  final List<Object> invalidated;
}

const _file = '${FilesFixture.rootPath}/Copper Valley (2018) 1080p.mkv';
const _sidecar = '${FilesFixture.rootPath}/Copper Valley (2018) 1080p.en.srt';

Future<_Built> _build(FakeBackend backend) async {
  final f = await FilesFixture.create();
  final relay = FakeFilesRelay();
  final invalidated = <Object>[];
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
    invalidate: (targets) async => invalidated.addAll(targets),
    l10n: () => filesL10n,
  );
  addTearDown(source.dispose);
  return _Built(f, source, invalidated);
}

void main() {
  final key = fileKeyFor(FilesFixture.rootId, 'Copper Valley (2018) 1080p.mkv');
  ItemRef movie(_Built b) => b.fixture.ref(ItemKind.movie, '101');

  test('offers direct play only', () async {
    final b = await _build(FakeBackend({_file: 10}));
    final session =
        FilesPlaybackSession(source: b.source, item: movie(b), fileId: key);
    final offer = (await session.candidates(CandidateScope.file)).offer!;
    expect(offer.candidates.map((c) => c.strategy), ['DIRECT_PLAY']);
    expect(offer.candidates.single.mime, 'video/x-matroska');
    expect(session.features, isEmpty);
  });

  test('resolver returns the backend url and headers', () async {
    final b = await _build(_AuthBackend({_file: 10}));
    final resolver = FilesStreamResolver(source: b.source);
    final s = await resolver.resolve(
        const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
        fileId: key,
        startAt: Duration.zero);
    expect(s.url, 'https://dav.example$_file');
    expect(s.headers['Authorization'], 'Basic x');
  });

  test('missing file surfaces folder unavailable', () async {
    final b = await _build(FakeBackend(const {}));
    final session =
        FilesPlaybackSession(source: b.source, item: movie(b), fileId: key);
    final prep = await session.prepareStreaming(
        owner: Object(), onProgress: (_) {}, isCurrent: () => true);
    expect(prep, isA<StreamingUnavailable>());
    expect((prep as StreamingUnavailable).problem.text,
        filesL10n.filesFolderUnavailable);
  });

  test('present file prepares streaming', () async {
    final b = await _build(FakeBackend({_file: 10}));
    final session =
        FilesPlaybackSession(source: b.source, item: movie(b), fileId: key);
    final prep = await session.prepareStreaming(
        owner: Object(), onProgress: (_) {}, isCurrent: () => true);
    expect(prep, isA<StreamingReady>());
  });

  test('sidecars become subtitle tracks and their text is fetched with auth',
      () async {
    final b = await _build(_AuthBackend({_file: 10, _sidecar: 5}));
    String? auth;
    final client = MockClient((http.Request r) async {
      auth = r.headers['Authorization'];
      expect(Uri.decodeFull(r.url.toString()), 'https://dav.example$_sidecar');
      return http.Response('1\n00:00:01,000 --> 00:00:02,000\nHi\n', 200);
    });
    final session = FilesPlaybackSession(
        source: b.source, item: movie(b), fileId: key, client: client);
    final detail = (await session.detail())!;
    final track = detail.serverSubtitleTracks!.single;
    expect(track.language, 'en');
    expect(track.format, 'srt');
    final text = await session.subtitleContent(track.id);
    expect(text, contains('Hi'));
    expect(auth, 'Basic x');
  });

  test('progress is saved under the item key into the source store', () async {
    final b = await _build(FakeBackend({_file: 10}));
    final item = movie(b);
    final session =
        FilesPlaybackSession(source: b.source, item: item, fileId: key);
    final reporter = session.createProgress() as LocalProgressReporter;
    await reporter.sendProgress(
        positionSeconds: 60, durationSeconds: 6000, paused: false);
    expect(b.fixture.progress.get(progressKey(item))!.positionSeconds, 60);
    expect(b.invalidated,
        containsAll(SourceRules.watchedChanged(b.fixture.sourceId)));
    reporter.dispose();
  });

  test('lists are told only on a threshold crossing and on stop', () async {
    final b = await _build(FakeBackend({_file: 10}));
    final session =
        FilesPlaybackSession(source: b.source, item: movie(b), fileId: key);
    final reporter = session.createProgress() as LocalProgressReporter;
    final perCall = SourceRules.watchedChanged(b.fixture.sourceId).length;
    int told() => b.invalidated.length ~/ perCall;
    Future<void> tick(int position) => reporter.sendProgress(
        positionSeconds: position, durationSeconds: 6000, paused: false);

    await tick(10);
    expect(told(), 0, reason: 'under 30s is not in progress yet');
    await tick(20);
    expect(told(), 0);
    await tick(40);
    expect(told(), 1, reason: 'now in Continue Watching');
    await tick(50);
    await tick(60);
    await tick(4000);
    expect(told(), 1, reason: 'still in progress');
    await tick(5400);
    expect(told(), 2, reason: 'crossed the watched line');
    await tick(5500);
    expect(told(), 2);
    await reporter.sendStopped(positionSeconds: 5510, durationSeconds: 6000);
    expect(told(), 3, reason: 'stopping always tells');
    reporter.dispose();
  });
}
