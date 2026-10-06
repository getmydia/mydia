import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/player/progress_service.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/domain/models/subtitle_candidate.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/player/session/mydia_playback_session.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';
import 'package:player/presentation/screens/player/session/source_playback_sessions.dart';
import 'package:player/presentation/widgets/subtitle_track_selector.dart';

import '../../../../test_utils/mydia_test_source.dart';
import '../../../../test_utils/scripted_mydia_transport.dart';
import '../player_screen_test_harness.dart';

const _movie = ItemRef(
    sourceId: testMydiaSourceId, kind: ItemKind.movie, externalId: 'movie-1');
const _episode = ItemRef(
    sourceId: testMydiaSourceId, kind: ItemKind.episode, externalId: 'ep-1');

const _hls = HlsPlan(
  strategy: HlsStrategy.transcode,
  rung: QualityRung(label: '720p', height: 720, maxBitrateKbps: 4000),
  adaptive: false,
  reason: PlanReason.fallbackFromFailure,
);
const _direct = DirectPlayPlan(reason: PlanReason.directPlayAccepted);

const _httpCreds = MydiaCredentials(
    instanceId: 'inst-a', accessToken: 'access', serverUrl: 'http://a.test');

MydiaCredentials _p2pCreds(String node) => MydiaCredentials(
    instanceId: 'inst-$node', accessToken: 'access', nodeAddr: node);

MydiaPlaybackSession _session(
  ScriptedMydiaTransport server, {
  ItemRef item = _movie,
  String fileId = 'file-1',
  String? showId,
  int? seasonNumber,
  MydiaCredentials creds = _httpCreds,
  LocalProxyService? proxy,
  String accountId = 'macct',
}) {
  final source =
      testMydiaSourceOver(server, creds: creds, accountId: accountId);
  return MydiaPlaybackSession(
    source: source,
    item: item,
    fileId: fileId,
    showId: showId,
    seasonNumber: seasonNumber,
    proxy: () => proxy ?? LocalProxyService.forTesting(),
  );
}

ScriptedMydiaTransport _answering(Object answer) =>
    ScriptedMydiaTransport((_, __) => answer);

Future<StreamingSetup> _setupOf(MydiaPlaybackSession s,
        {Object? owner}) async =>
    ((await s.prepareStreaming(
            owner: owner ?? Object(),
            onProgress: (_) {},
            isCurrent: () => true)) as StreamingReady)
        .setup;

Future<String> _directPlayUrl(MydiaPlaybackSession s, Object owner) async {
  final setup = await _setupOf(s, owner: owner);
  final source = await setup
      .createTransport(relayed: false)
      .open(_direct, fileId: 'file-1', startAt: Duration.zero);
  return source.url;
}

void main() {
  group('candidates', () {
    test('asks about the file and maps the offer', () async {
      final server = _answering(streamingCandidatesResponse(
        duration: 5400.5,
        height: 1080,
        bitrate: 8000000,
        fileId: 'file-1',
        preferredAudioLanguages: ['jpn'],
        directPlay: true,
      ));

      final fetch = await _session(server).candidates(CandidateScope.file);

      expect(server.requests.single.variables,
          {'contentType': 'file', 'id': 'file-1'});
      expect(fetch.serverRejected, isFalse);
      final offer = fetch.offer!;
      expect(offer.fileId, 'file-1');
      expect(offer.durationSeconds, 5400.5);
      expect(offer.height, 1080);
      expect(offer.bitrateBps, 8000000);
      expect(offer.preferredAudioLanguages, ['jpn']);
      expect(offer.candidates.first.strategy, 'DIRECT_PLAY');
    });

    test('asks about the item by media type for the item scope', () async {
      final server = _answering(streamingCandidatesResponse());
      await _session(server).candidates(CandidateScope.item);
      expect(server.requests.single.variables,
          {'contentType': 'movie', 'id': 'movie-1'});
    });

    test('maps any non-movie media type to episode for the item scope',
        () async {
      final server = _answering(streamingCandidatesResponse());
      await _session(server, item: _episode).candidates(CandidateScope.item);
      expect(server.requests.single.variables,
          {'contentType': 'episode', 'id': 'ep-1'});
    });

    test('never answers from the cache', () async {
      final server = _answering(streamingCandidatesResponse());
      final session = _session(server);
      await session.candidates(CandidateScope.file);
      await session.candidates(CandidateScope.file);
      expect(server.requests, hasLength(2));
    });

    test('a GraphQL error is a server rejection', () async {
      final server = _answering(graphqlError('file not found'));
      final fetch = await _session(server).candidates(CandidateScope.file);
      expect(fetch.offer, isNull);
      expect(fetch.serverRejected, isTrue);
    });

    test('a transport failure is not a server rejection', () async {
      final server = _answering(const SourceException.unreachable());
      final fetch = await _session(server).candidates(CandidateScope.file);
      expect(fetch.offer, isNull);
      expect(fetch.serverRejected, isFalse);
    });
  });

  group('detail', () {
    test('maps progress, runtime and the picked file subtitles', () async {
      final server = _answering(movieDetailResponse(
        positionSeconds: 120,
        durationSeconds: 5400,
        files: [mediaFileWithSubtitle(fileId: 'file-1', trackId: '3')],
      ));

      final detail = (await _session(server).detail())!;

      expect(detail.savedPositionSeconds, 120);
      expect(detail.savedDurationSeconds, 5400);
      expect(detail.serverSubtitleTracks!.single.id, '3');
    });

    test('leaves subtitles null when no file matches', () async {
      final server = _answering(movieDetailResponse(
        files: [mediaFileWithSubtitle(fileId: 'other-file')],
      ));
      final detail = (await _session(server).detail())!;
      expect(detail.serverSubtitleTracks, isNull);
    });

    test('is null when the server cannot be reached', () async {
      final server = _answering(const SourceException.unreachable());
      expect(await _session(server).detail(), isNull);
    });
  });

  group('segments', () {
    test('returns the picked file segments', () async {
      final server = _answering(movieSegmentsResponse());
      expect(await _session(server).segments(), isEmpty);
      expect(server.requests, hasLength(1));
    });

    test('is null on a GraphQL error', () async {
      final server = _answering(graphqlError('boom'));
      expect(await _session(server).segments(), isNull);
    });
  });

  group('subtitlePreference', () {
    test('a fetched absence is a non-null result with a null value', () async {
      final server = _answering(subtitlePreferenceResponse());
      final fetched = await _session(server).subtitlePreference();
      expect(fetched, isNotNull);
      expect(fetched!.value, isNull);
    });

    test('maps a stored preference', () async {
      final server = _answering(subtitlePreferenceResponse(
        preferences: {
          'file-1': preferredSubtitleObject(mode: 'OFF'),
        },
      ));
      final fetched = await _session(server).subtitlePreference();
      expect(fetched!.value, isNotNull);
    });

    test('two calls send two requests', () async {
      final server = _answering(subtitlePreferenceResponse());
      final session = _session(server);
      await session.subtitlePreference();
      await session.subtitlePreference();
      expect(server.requests, hasLength(2));
    });

    test('is null on a GraphQL error', () async {
      final server = _answering(graphqlError('boom'));
      expect(await _session(server).subtitlePreference(), isNull);
    });
  });

  group('subtitleOffsets', () {
    test('maps track refs to offsets', () async {
      final server = _answering(subtitleTrackSettingsResponse(
        settings: [
          {
            '__typename': 'SubtitleTrackSetting',
            'trackRef': '3',
            'offsetMs': 250,
          },
        ],
      ));
      expect(await _session(server).subtitleOffsets(), {'3': 250});
      expect(server.requests.single.variables, {'mediaFileId': 'file-1'});
    });

    test('two calls send two requests', () async {
      final server = _answering(subtitleTrackSettingsResponse());
      final session = _session(server);
      await session.subtitleOffsets();
      await session.subtitleOffsets();
      expect(server.requests, hasLength(2));
    });

    test('is null on a GraphQL error', () async {
      final server = _answering(graphqlError('boom'));
      expect(await _session(server).subtitleOffsets(), isNull);
    });
  });

  group('seasonEpisodes', () {
    Map<String, dynamic> episode(int n, {List<Object?>? files}) => {
          '__typename': 'Episode',
          'id': 'ep-$n',
          'seasonNumber': 2,
          'episodeNumber': n,
          'title': n == 2 ? null : 'The Lantern Keeper $n',
          'overview': null,
          'airDate': null,
          'runtime': null,
          'monitored': true,
          'thumbnailUrl': null,
          'hasFile': true,
          'progress': null,
          'files': files,
        };

    test('asks for the given season of the target show', () async {
      final server = _answering({
        'seasonEpisodes': [episode(1, files: const [])],
      });
      await _session(server, item: _episode, showId: 'show-1', seasonNumber: 2)
          .seasonEpisodes(3);
      expect(server.requests.single.variables,
          {'showId': 'show-1', 'seasonNumber': 3});
    });

    test('keeps null titles and the server file list shape', () async {
      final server = _answering({
        'seasonEpisodes': [
          episode(1, files: [
            {'__typename': 'MediaFile', 'id': 'f-1'},
          ]),
          episode(2),
        ],
      });
      final episodes = (await _session(server,
              item: _episode, showId: 'show-1', seasonNumber: 2)
          .seasonEpisodes(2))!;
      expect(episodes[0].title, 'The Lantern Keeper 1');
      expect(episodes[0].fileIds, ['f-1']);
      expect(episodes[1].title, isNull);
      expect(episodes[1].fileIds, isNull);
    });

    test('is null without a show id', () async {
      final server = _answering(<String, dynamic>{});
      expect(await _session(server).seasonEpisodes(1), isNull);
      expect(server.requests, isEmpty);
    });
  });

  group('searchSubtitles', () {
    test('refuses the offline sentinel without a request', () async {
      final server = _answering(<String, dynamic>{});
      final outcome =
          await _session(server, fileId: 'offline').searchSubtitles(['eng']);
      expect(
          outcome.error, 'Subtitle search needs a connection to your server.');
      expect(server.requests, isEmpty);
    });

    test('shows the resolver message on a GraphQL error', () async {
      final server = _answering(graphqlError('These results expired.'));
      final outcome = await _session(server).searchSubtitles(['eng']);
      expect(outcome.error, 'These results expired.');
    });

    test('falls back to generic copy when the server is unreachable', () async {
      final server = _answering(const SourceException.unreachable());
      final outcome = await _session(server).searchSubtitles(['eng']);
      expect(outcome.error, 'Could not reach the server. Try again.');
    });

    test('sends the file and languages', () async {
      final server = _answering(graphqlError('x'));
      await _session(server).searchSubtitles(['eng', 'por']);
      expect(server.requests.single.variables, {
        'mediaFileId': 'file-1',
        'languages': ['eng', 'por']
      });
    });
  });

  group('subtitleContent', () {
    test('returns the body', () async {
      final server = _answering({
        'subtitleContent': 'WEBVTT\n\n00:00.000 --> 00:01.000\nHi',
      });
      expect(await _session(server).subtitleContent('3'), startsWith('WEBVTT'));
      expect(server.requests.single.variables,
          {'mediaFileId': 'file-1', 'trackId': '3'});
    });

    test('waits out a slow extraction, with no client-side timeout', () async {
      final server = ScriptedMydiaTransport((_, __) => Future.delayed(
          const Duration(milliseconds: 300),
          () => {'subtitleContent': 'WEBVTT\n'}));
      expect(await _session(server).subtitleContent('4'), 'WEBVTT\n');
    });

    test('is null for an empty body', () async {
      final server = _answering({'subtitleContent': ''});
      expect(await _session(server).subtitleContent('3'), isNull);
    });

    test('is null on a GraphQL error', () async {
      final server = _answering(graphqlError('boom'));
      expect(await _session(server).subtitleContent('3'), isNull);
    });
  });

  group('saveSubtitleOffset', () {
    test('sends the file, track and offset', () async {
      final server = _answering({
        'setSubtitleOffset': {
          '__typename': 'SubtitleTrackSetting',
          'trackRef': '3',
          'offsetMs': 400,
        },
      });
      final session = _session(server);
      final outcome =
          await session.saveSubtitleOffset(trackRef: '3', offsetMs: 400);
      expect(session.canWrite, isTrue);
      expect(outcome, WriteOutcome.done);
      expect(server.requests.single.variables,
          {'mediaFileId': 'file-1', 'trackRef': '3', 'offsetMs': 400});
    });

    test('fails on a GraphQL error', () async {
      final server = _answering(graphqlError('boom'));
      expect(
        await _session(server).saveSubtitleOffset(trackRef: '3', offsetMs: 1),
        WriteOutcome.failed,
      );
    });
  });

  group('rememberAudioLanguage', () {
    test('returns the updated preference list', () async {
      final server = _answering({
        'setAudioLanguagePreference': {
          '__typename': 'AudioLanguagePreference',
          'mediaItemId': 'movie-1',
          'language': 'jpn',
          'preferredAudioLanguages': ['jpn', 'eng'],
        },
      });
      expect(
          await _session(server).rememberAudioLanguage('jpn'), ['jpn', 'eng']);
      expect(server.requests.single.variables,
          {'fileId': 'file-1', 'language': 'jpn'});
    });

    test('is null on a GraphQL error', () async {
      final server = _answering(graphqlError('old server'));
      expect(await _session(server).rememberAudioLanguage('jpn'), isNull);
    });
  });

  group('writeSubtitlePreference', () {
    test('writes OFF for no track', () async {
      final server = _answering({
        'setSubtitlePreference': {
          '__typename': 'SubtitlePreferenceResult',
          'mediaItemId': 'movie-1',
          'preference': null,
        },
      });
      await _session(server)
          .writeSubtitlePreference(fileId: 'file-7', resolved: null);
      final vars = server.requests.single.variables;
      expect(vars['fileId'], 'file-7');
      expect(vars['mode'], 'OFF');
    });

    test('does not throw on a GraphQL error', () async {
      final server = _answering(graphqlError('boom'));
      await _session(server)
          .writeSubtitlePreference(fileId: 'file-7', resolved: null);
      expect(server.requests, hasLength(1));
    });
  });

  group('downloadSubtitle', () {
    test('refuses the offline sentinel', () async {
      final server = _answering(<String, dynamic>{});
      await expectLater(
        _session(server, fileId: 'offline').downloadSubtitle(_candidate()),
        throwsA(isA<SubtitleActionException>()),
      );
      expect(server.requests, isEmpty);
    });

    test('throws the resolver message on a GraphQL error', () async {
      final server = _answering(graphqlError('Search again.'));
      await expectLater(
        _session(server).downloadSubtitle(_candidate()),
        throwsA(isA<SubtitleActionException>()
            .having((e) => e.message, 'message', 'Search again.')),
      );
    });
  });

  group('streaming', () {
    late LocalProxyService proxy;
    setUp(() => proxy = LocalProxyService.forTesting());
    tearDown(() => proxy.shutdown());

    test('an HTTP instance direct plays with a bearer header', () async {
      final session = _session(_answering(<String, dynamic>{}));
      final setup = await _setupOf(session);
      final source = await setup
          .createTransport(relayed: false)
          .open(_direct, fileId: 'file-1', startAt: Duration.zero);
      expect(setup.viaP2p, isFalse);
      expect(setup.memoryKey, 'http://a.test');
      expect(source.url,
          'http://a.test/api/v1/stream/file/file-1?strategy=DIRECT_PLAY');
      expect(source.headers, {'Authorization': 'Bearer access'});
    });

    test('an HTTP instance direct plays with the media token when it has one',
        () async {
      final session = _session(
        _answering(<String, dynamic>{}),
        creds: MydiaCredentials(
          instanceId: 'inst-a',
          accessToken: 'access',
          serverUrl: 'http://a.test',
          mediaToken: 'media-tok',
          mediaTokenExpiry: DateTime.now().add(const Duration(days: 1)),
        ),
      );
      final setup = await _setupOf(session);
      final source = await setup
          .createTransport(relayed: false)
          .open(_direct, fileId: 'file-1', startAt: Duration.zero);
      expect(
          source.url,
          'http://a.test/api/v1/stream/file/file-1'
          '?strategy=DIRECT_PLAY&token=media-tok');
      expect(source.headers, isEmpty);
    });

    test('an HTTP instance starts a streaming session and plays its playlist',
        () async {
      final playlist = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => playlist.close(force: true));
      playlist.listen((request) {
        request.response
          ..write('#EXTM3U\n#EXTINF:6,\na.ts\n#EXTINF:6,\nb.ts\n'
              '#EXTINF:6,\nc.ts\n#EXT-X-ENDLIST\n')
          ..close();
      });
      final base = 'http://127.0.0.1:${playlist.port}';
      final server = ScriptedMydiaTransport((r, _) => switch (r.operation) {
            'StartStreamingSession' =>
              startStreamingSessionResponse(playlistMode: 'FULL'),
            _ => <String, dynamic>{},
          });
      final session = _session(server,
          creds: MydiaCredentials(
              instanceId: 'inst-a', accessToken: 'access', serverUrl: base));

      final transport =
          (await _setupOf(session)).createTransport(relayed: false);
      final source = await transport.open(_hls,
          fileId: 'file-1', startAt: const Duration(seconds: 90));

      expect(server.of('StartStreamingSession').single.variables, {
        'fileId': 'file-1',
        'strategy': 'TRANSCODE',
        'maxBitrate': 4000,
        'maxHeight': 720,
        'startPosition': 90,
        'playlistMode': 'FULL',
      });
      expect(source.url, '$base/api/v1/hls/sess-1/index.m3u8');
      await transport.endSession();
      expect(server.of('EndStreamingSession').single.variables,
          {'sessionId': 'sess-1'});
    });

    test('a p2p instance direct plays through its own proxy target', () async {
      final session = _session(_answering(<String, dynamic>{}),
          creds: _p2pCreds('node-a'), proxy: proxy);
      final setup = await _setupOf(session);
      final source = await setup
          .createTransport(relayed: false)
          .open(_direct, fileId: 'file-1', startAt: Duration.zero);
      expect(setup.viaP2p, isTrue);
      expect(setup.memoryKey, 'node-a');
      expect(source.url, startsWith(proxy.targetBaseUrl('macct')));
      expect(source.headers, isEmpty);
    });

    test('the proxy hold belongs to the owner and release lets it go',
        () async {
      final owner = Object();
      final session = _session(_answering(<String, dynamic>{}),
          creds: _p2pCreds('node-a'), proxy: proxy);
      await _directPlayUrl(session, owner);
      expect(proxy.isRunning, isTrue);
      await proxy.release(owner);
      expect(proxy.isRunning, isFalse);
    });

    test('two instances each stream through their own proxy target', () async {
      const owner = Object();
      final sa = _session(ScriptedMydiaTransport.responses([{}]),
          creds: _p2pCreds('node-a'), proxy: proxy);
      final sb = _session(ScriptedMydiaTransport.responses([{}]),
          creds: _p2pCreds('node-b'), proxy: proxy, accountId: 'macct-b');

      final urlA = await _directPlayUrl(sa, owner);
      final urlB = await _directPlayUrl(sb, owner);

      expect(urlA, startsWith(proxy.targetBaseUrl('macct')));
      expect(urlB, startsWith(proxy.targetBaseUrl('macct-b')));
      expect(urlA, isNot(startsWith(proxy.targetBaseUrl('macct-b'))));
      expect(proxy.isRunning, isTrue);
      await proxy.release(owner);
      expect(proxy.isRunning, isFalse);
    });

    test('an instance with neither a URL nor a node cannot stream', () async {
      final session = _session(_answering(<String, dynamic>{}),
          creds: const MydiaCredentials(
              instanceId: 'inst-x', accessToken: 'access'));
      final prep = await session.prepareStreaming(
          owner: Object(), onProgress: (_) {}, isCurrent: () => true);
      expect(prep, isA<StreamingUnavailable>());
    });

    test('progress goes to this instance\'s UpdateMovieProgress', () async {
      final server = _answering(<String, dynamic>{});
      final setup = await _setupOf(_session(server));
      final progress = setup.progress as ProgressService;
      expect(
          await progress.syncMoviePosition('movie-1',
              const Duration(seconds: 12), const Duration(seconds: 6000)),
          isTrue);
      expect(server.of('UpdateMovieProgress').single.variables, {
        'movieId': 'movie-1',
        'positionSeconds': 12,
        'durationSeconds': 6000,
      });
    });

    test('openProgress writes through this instance\'s client', () async {
      final server = _answering(<String, dynamic>{});
      final progress = await _session(server).openProgress();
      await (progress as ProgressService).syncEpisodePosition(
          'ep-1', const Duration(seconds: 5), const Duration(seconds: 1440));
      expect(server.of('UpdateEpisodeProgress'), hasLength(1));
    });
  });

  group('session shape', () {
    test('every feature on every instance', () {
      expect(_session(ScriptedMydiaTransport.responses([{}])).features,
          PlaybackFeature.values.toSet());
    });

    test('reachable follows the instance\'s connection status', () async {
      final server = _answering(const SourceException.unreachable());
      final session = _session(server);
      expect(session.reachable, isTrue);
      await session.subtitleOffsets();
      expect(session.reachable, isFalse);
    });

    test('playbackSessionFor returns a MydiaPlaybackSession for a MydiaSource',
        () {
      final source = testMydiaSourceOver(_answering(<String, dynamic>{}));
      final session = playbackSessionFor(source, _movie, 'file-1',
          proxy: LocalProxyService.forTesting);
      expect(session, isA<MydiaPlaybackSession>());
    });
  });
}

SubtitleCandidate _candidate() => const SubtitleCandidate(
      token: 'tok-1',
      language: 'en',
      releaseName: 'Harbor.Lights.2031.WEB',
      format: 'srt',
      hearingImpaired: false,
      hashMatch: false,
      score: 50,
      providerName: 'testprovider',
    );
