import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/sources/mydia/mydia_guest_client.dart';
import 'package:player/core/sources/mydia/mydia_guest_credentials.dart';
import 'package:player/core/sources/mydia/mydia_guest_source.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/player/session/mydia_guest_playback_session.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';
import 'package:player/presentation/screens/player/session/source_playback_sessions.dart';

import '../../../../core/sources/mydia/fake_mydia_transport.dart';
import '../../../../core/sources/mydia/mydia_fixtures.dart' as fx;
import '../../../../core/sources/mydia/mydia_guest_source_test.dart'
    show guest, sid;

const _movie = ItemRef(sourceId: sid, kind: ItemKind.movie, externalId: 'm-1');
const _episode =
    ItemRef(sourceId: sid, kind: ItemKind.episode, externalId: 'e-1');

const _hls = HlsPlan(
  strategy: HlsStrategy.transcode,
  rung: QualityRung(label: '720p', height: 720, maxBitrateKbps: 4000),
  adaptive: false,
  reason: PlanReason.fallbackFromFailure,
);

const _direct = MydiaGuestCredentials(
  instanceId: 'inst-2',
  accessToken: 'access',
  serverUrl: 'https://lake.example',
);
const _p2p = MydiaGuestCredentials(
  instanceId: 'inst-2',
  accessToken: 'access',
  nodeAddr: '{"id":"abc"}',
);

void main() {
  late FakeMydiaTransport t;
  late LocalProxyService proxy;
  late List<http.Request> httpRequests;

  setUp(() {
    proxy = LocalProxyService.forTesting();
    httpRequests = [];
    t = FakeMydiaTransport();
    t.handlers['MovieDetail'] = (v) => {'movie': fx.movie(v['id'] as String)};
    t.handlers['EpisodeDetail'] =
        (v) => {'episode': fx.episode(v['id'] as String)};
    t.handlers['StreamingCandidates'] = (v) => {
          'streamingCandidates': {
            'fileId': 'f-m-1',
            'candidates': [
              {
                'strategy': 'DIRECT_PLAY',
                'mime': 'video/mp4',
                'container': 'mp4',
                'videoCodec': 'h264',
                'audioCodec': 'aac',
              },
              {
                'strategy': 'TRANSCODE',
                'mime': 'application/x-mpegURL',
                'container': 'ts',
                'videoCodec': 'h264',
                'audioCodec': 'aac',
              },
            ],
            'metadata': null,
          }
        };
    t.handlers['StartStreamingSession'] = (_) => {
          'startStreamingSession': {'sessionId': 'sess-1'}
        };
    for (final op in [
      'EndStreamingSession',
      'UpdateMovieProgress',
      'UpdateEpisodeProgress',
      'MarkMovieWatched',
      'MarkEpisodeWatched',
    ]) {
      t.handlers[op] = (_) => <String, dynamic>{};
    }
  });

  tearDown(() => proxy.shutdown());

  MydiaGuestPlaybackSession open(
    MydiaGuestCredentials creds, {
    ItemRef item = _movie,
  }) {
    final client = MydiaGuestClient(
      transport: t,
      load: () async => creds,
      save: (_) async {},
      onUnauthorized: () {},
    );
    return MydiaGuestPlaybackSession(
      source:
          MydiaGuestSource(source: guest, client: client, proxy: () => proxy),
      item: item,
      fileId: item.kind == ItemKind.movie ? 'f-m-1' : 'f-e-1',
      proxy: () => proxy,
      http: SourceHttp(client: MockClient((request) async {
        httpRequests.add(request);
        return http.Response('1\n00:00:01,000 --> 00:00:02,000\nHola\n', 200);
      })),
    );
  }

  Future<StreamingSetup> setupOf(MydiaGuestPlaybackSession s,
          {Object? owner}) async =>
      ((await s.prepareStreaming(
              owner: owner ?? Object(),
              onProgress: (_) {},
              isCurrent: () => true)) as StreamingReady)
          .setup;

  int count(String op) => t.calls.where((c) => c.operation == op).length;

  Map<String, dynamic> varsOf(String op) =>
      t.calls.firstWhere((c) => c.operation == op).vars;

  test('candidates come from StreamingCandidates and are fetched once',
      () async {
    final s = open(_direct);
    final offer = (await s.candidates(CandidateScope.file)).offer!;
    expect(
        offer.candidates.map((c) => c.strategy), ['DIRECT_PLAY', 'TRANSCODE']);
    expect(offer.candidates.first.mime, 'video/mp4');
    expect(offer.candidates.first.videoCodec, 'h264');
    await s.candidates(CandidateScope.file);
    await setupOf(s);
    expect(count('StreamingCandidates'), 1);
    expect(
        varsOf('StreamingCandidates'), {'contentType': 'movie', 'id': 'm-1'});
  });

  test('an episode asks for episode candidates', () async {
    final s = open(_direct, item: _episode);
    await s.candidates(CandidateScope.file);
    expect(
        varsOf('StreamingCandidates'), {'contentType': 'episode', 'id': 'e-1'});
  });

  test('a failed candidates fetch is retried, not cached', () async {
    final s = open(_direct);
    t.unreachable = true;
    expect((await s.candidates(CandidateScope.file)).offer, isNull);
    t.unreachable = false;
    expect((await s.candidates(CandidateScope.file)).offer, isNotNull);
  });

  test('an HTTP guest direct plays with a bearer header', () async {
    final setup = await setupOf(open(_direct));
    final source = await setup.createTransport(relayed: false).open(
          const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
          fileId: 'f-m-1',
          startAt: Duration.zero,
        );
    expect(source.url,
        'https://lake.example/api/v1/stream/file/f-m-1?strategy=DIRECT_PLAY');
    expect(source.headers, {'Authorization': 'Bearer access'});
  });

  test('an HTTP guest starts a streaming session and plays its playlist',
      () async {
    final setup = await setupOf(open(_direct));
    final transport = setup.createTransport(relayed: false);
    final source = await transport.open(
      _hls,
      fileId: 'f-m-1',
      startAt: const Duration(seconds: 90),
    );
    expect(varsOf('StartStreamingSession'), {
      'fileId': 'f-m-1',
      'strategy': 'TRANSCODE',
      'maxBitrate': 4000,
      'maxHeight': 720,
      'startPosition': 90,
      'playlistMode': 'FULL',
    });
    expect(source.url, 'https://lake.example/api/v1/hls/sess-1/index.m3u8');
    expect(source.headers, {'Authorization': 'Bearer access'});
    await transport.endSession();
    expect(varsOf('EndStreamingSession'), {'sessionId': 'sess-1'});
  });

  test('copy starts an HLS_COPY session with no start position at zero',
      () async {
    final setup = await setupOf(open(_direct));
    await setup.createTransport(relayed: false).open(
          const HlsPlan(
            strategy: HlsStrategy.copy,
            rung: QualityRung.original,
            adaptive: false,
            reason: PlanReason.fallbackFromFailure,
          ),
          fileId: 'f-m-1',
          startAt: Duration.zero,
        );
    final vars = varsOf('StartStreamingSession');
    expect(vars['strategy'], 'HLS_COPY');
    expect(vars['startPosition'], isNull);
  });

  test('a p2p guest plays through its own proxy target', () async {
    final setup = await setupOf(open(_p2p));
    final source = await setup
        .createTransport(relayed: false)
        .open(_hls, fileId: 'f-m-1', startAt: Duration.zero);
    expect(
        source.url, '${proxy.targetBaseUrl('mguest')}/hls/sess-1/index.m3u8');
    expect(source.url, contains('/t/mguest/hls/'));
    expect(source.headers, isEmpty);
    expect(proxy.isRunning, isTrue);
  });

  test('a p2p guest direct plays through the proxy', () async {
    final setup = await setupOf(open(_p2p));
    final source = await setup.createTransport(relayed: false).open(
          const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
          fileId: 'f-m-1',
          startAt: Duration.zero,
        );
    expect(source.url, '${proxy.targetBaseUrl('mguest')}/direct/f-m-1/stream');
    expect(source.headers, isEmpty);
  });

  test('the proxy hold belongs to the owner and release lets it go', () async {
    final owner = Object();
    final setup = await setupOf(open(_p2p), owner: owner);
    await setup.createTransport(relayed: false).open(
          const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
          fileId: 'f-m-1',
          startAt: Duration.zero,
        );
    expect(proxy.isRunning, isTrue);
    await proxy.release(owner);
    expect(proxy.isRunning, isFalse);
  });

  test('progress for a movie and an episode', () async {
    final movie =
        (await setupOf(open(_direct))).progress as MydiaGuestProgressReporter;
    await movie.sendProgress(
        positionSeconds: 12, durationSeconds: 6000, paused: false);
    await movie.sendWatched();
    await movie.sendStopped(positionSeconds: 30, durationSeconds: 6000);
    expect(
        t.calls
            .where((c) => c.operation == 'UpdateMovieProgress')
            .map((c) => c.vars),
        [
          {'movieId': 'm-1', 'positionSeconds': 12, 'durationSeconds': 6000},
          {'movieId': 'm-1', 'positionSeconds': 30, 'durationSeconds': 6000},
        ]);
    expect(varsOf('MarkMovieWatched'), {'movieId': 'm-1'});

    final ep = (await setupOf(open(_direct, item: _episode))).progress
        as MydiaGuestProgressReporter;
    await ep.sendProgress(
        positionSeconds: 5, durationSeconds: 1440, paused: true);
    await ep.sendWatched();
    expect(varsOf('UpdateEpisodeProgress'),
        {'episodeId': 'e-1', 'positionSeconds': 5, 'durationSeconds': 1440});
    expect(varsOf('MarkEpisodeWatched'), {'episodeId': 'e-1'});
  });

  test('ending a session swallows a server error', () async {
    t.handlers['EndStreamingSession'] =
        (_) => throw const SourceException.server('nope');
    final setup = await setupOf(open(_direct));
    final transport = setup.createTransport(relayed: false);
    await transport.open(_hls, fileId: 'f-m-1', startAt: Duration.zero);
    await transport.endSession();
    expect(count('EndStreamingSession'), 1);
  });

  test('an HTTP guest fetches a subtitle with the bearer header', () async {
    final s = open(_direct);
    expect(await s.fetchText('/api/v1/subtitles/sub-1.vtt'), contains('Hola'));
    expect(httpRequests.single.url.toString(),
        'https://lake.example/api/v1/subtitles/sub-1.vtt');
    expect(httpRequests.single.headers['Authorization'], 'Bearer access');
  });

  test('an HTTP guest lists its sidecar subtitle tracks', () async {
    final detail = await open(_direct).detail();
    expect(detail!.serverSubtitleTracks!.map((t) => t.id), ['sub-1']);
  });

  test('a p2p guest lists no sidecar tracks it cannot fetch', () async {
    final detail = await open(_p2p).detail();
    expect(detail, isNotNull);
    expect(detail!.serverSubtitleTracks, isNull);
    expect(detail.savedDurationSeconds, isNotNull);
  });

  test('a p2p guest has no subtitle files yet', () async {
    final s = open(_p2p);
    await expectLater(s.fetchText('/api/v1/subtitles/sub-1.vtt'),
        throwsA(isA<SourceException>()));
    expect(await s.subtitleContent('sub-1'), isNull);
    expect(httpRequests, isEmpty);
  });

  test('a resolver built before prepareStreaming refuses to take the proxy',
      () async {
    final s = open(_p2p);
    final detail = await s.loadDetail();
    final resolver = s.createResolver(detail, detail.versions.first);
    await expectLater(
        resolver.resolve(
            const DirectPlayPlan(reason: PlanReason.directPlayAccepted),
            fileId: 'f-m-1',
            startAt: Duration.zero),
        throwsStateError);
    expect(proxy.isRunning, isFalse);
  });

  test('playbackSessionFor builds a guest session only with a proxy', () {
    final client = MydiaGuestClient(
      transport: t,
      load: () async => _direct,
      save: (_) async {},
      onUnauthorized: () {},
    );
    final source =
        MydiaGuestSource(source: guest, client: client, proxy: () => proxy);
    expect(playbackSessionFor(source, _movie, 'f-m-1', proxy: () => proxy),
        isA<MydiaGuestPlaybackSession>());
    expect(playbackSessionFor(source, _movie, 'f-m-1'), isNull);
  });

  test('a guest session cannot cast', () {
    expect(open(_direct).features, isNot(contains(PlaybackFeature.cast)));
  });
}
