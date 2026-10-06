import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/domain/models/subtitle_candidate.dart';
import 'package:player/presentation/screens/player/session/mydia_playback_session.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';
import 'package:player/presentation/widgets/subtitle_track_selector.dart';

import '../../../../test_utils/stub_graphql_client.dart';
import '../player_screen_test_harness.dart';
import '../../../../test_utils/mydia_test_source.dart';

const _movieTarget = PlaybackTarget(
  mediaType: 'movie',
  mediaId: 'movie-1',
  fileId: 'file-1',
);

MydiaPlaybackSession _session(
  StubLink link, {
  PlaybackTarget target = _movieTarget,
  bool hasClient = true,
}) {
  final client = stubClient(link);
  return MydiaPlaybackSession(
    client: () => hasClient ? client : null,
    awaitClient: () async => client,
    target: () => target,
    offline: () => false,
    sourceId: () => testMydiaSourceId,
  );
}

void main() {
  group('candidates', () {
    test('asks about the file and maps the offer', () async {
      final link = StubLink((_, __) => streamingCandidatesResponse(
            duration: 5400.5,
            height: 1080,
            bitrate: 8000000,
            fileId: 'file-1',
            preferredAudioLanguages: ['jpn'],
            directPlay: true,
          ));

      final fetch = await _session(link).candidates(CandidateScope.file);

      expect(link.requests.single.variables,
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
      final link = StubLink((_, __) => streamingCandidatesResponse());
      await _session(link).candidates(CandidateScope.item);
      expect(link.requests.single.variables,
          {'contentType': 'movie', 'id': 'movie-1'});
    });

    test('maps any non-movie media type to episode for the item scope',
        () async {
      final link = StubLink((_, __) => streamingCandidatesResponse());
      await _session(
        link,
        target: const PlaybackTarget(
          mediaType: 'episode',
          mediaId: 'ep-1',
          fileId: 'file-1',
        ),
      ).candidates(CandidateScope.item);
      expect(link.requests.single.variables,
          {'contentType': 'episode', 'id': 'ep-1'});
    });

    test('never answers from the cache', () async {
      final link = StubLink((_, __) => streamingCandidatesResponse());
      final session = _session(link);
      await session.candidates(CandidateScope.file);
      await session.candidates(CandidateScope.file);
      expect(link.requests, hasLength(2));
    });

    test('a GraphQL error is a server rejection', () async {
      final link = StubLink((_, __) => graphqlErrorResponse('file not found'));
      final fetch = await _session(link).candidates(CandidateScope.file);
      expect(fetch.offer, isNull);
      expect(fetch.serverRejected, isTrue);
    });

    test('a transport failure is not a server rejection', () async {
      final link = StubLink((_, __) => ServerException(
            originalException: Exception('socket closed'),
            parsedResponse: null,
          ));
      final fetch = await _session(link).candidates(CandidateScope.file);
      expect(fetch.offer, isNull);
      expect(fetch.serverRejected, isFalse);
    });
  });

  group('detail', () {
    test('maps progress, runtime and the picked file subtitles', () async {
      final link = StubLink((_, __) => movieDetailResponse(
            positionSeconds: 120,
            durationSeconds: 5400,
            files: [mediaFileWithSubtitle(fileId: 'file-1', trackId: '3')],
          ));

      final detail = (await _session(link).detail())!;

      expect(detail.savedPositionSeconds, 120);
      expect(detail.savedDurationSeconds, 5400);
      expect(detail.serverSubtitleTracks!.single.id, '3');
    });

    test('leaves subtitles null when no file matches', () async {
      final link = StubLink((_, __) => movieDetailResponse(
            files: [mediaFileWithSubtitle(fileId: 'other-file')],
          ));
      final detail = (await _session(link).detail())!;
      expect(detail.serverSubtitleTracks, isNull);
    });

    test('is null for a media type that is neither movie nor episode',
        () async {
      final link = StubLink((_, __) => movieDetailResponse());
      final detail = await _session(
        link,
        target: const PlaybackTarget(
            mediaType: 'other', mediaId: 'x', fileId: 'file-1'),
      ).detail();
      expect(detail, isNull);
      expect(link.requests, isEmpty);
    });
  });

  group('segments', () {
    test('returns the picked file segments', () async {
      final link = StubLink((_, __) => movieSegmentsResponse());
      expect(await _session(link).segments(), isEmpty);
      expect(link.requests, hasLength(1));
    });

    test('is null on a GraphQL error', () async {
      final link = StubLink((_, __) => graphqlErrorResponse('boom'));
      expect(await _session(link).segments(), isNull);
    });
  });

  group('subtitlePreference', () {
    test('a fetched absence is a non-null result with a null value', () async {
      final link = StubLink((_, __) => subtitlePreferenceResponse());
      final fetched = await _session(link).subtitlePreference();
      expect(fetched, isNotNull);
      expect(fetched!.value, isNull);
    });

    test('maps a stored preference', () async {
      final link = StubLink((_, __) => subtitlePreferenceResponse(
            preferences: {
              'file-1': preferredSubtitleObject(mode: 'OFF'),
            },
          ));
      final fetched = await _session(link).subtitlePreference();
      expect(fetched!.value, isNotNull);
    });

    test('never answers from the cache', () async {
      final link = StubLink((_, __) => subtitlePreferenceResponse());
      final session = _session(link);
      await session.subtitlePreference();
      await session.subtitlePreference();
      expect(link.requests, hasLength(2));
    });

    test('is null on a GraphQL error', () async {
      final link = StubLink((_, __) => graphqlErrorResponse('boom'));
      expect(await _session(link).subtitlePreference(), isNull);
    });
  });

  group('subtitleOffsets', () {
    test('maps track refs to offsets', () async {
      final link = StubLink((_, __) => subtitleTrackSettingsResponse(
            settings: [
              {
                '__typename': 'SubtitleTrackSetting',
                'trackRef': '3',
                'offsetMs': 250,
              },
            ],
          ));
      expect(await _session(link).subtitleOffsets(), {'3': 250});
      expect(link.requests.single.variables, {'mediaFileId': 'file-1'});
    });

    test('never answers from the cache', () async {
      final link = StubLink((_, __) => subtitleTrackSettingsResponse());
      final session = _session(link);
      await session.subtitleOffsets();
      await session.subtitleOffsets();
      expect(link.requests, hasLength(2));
    });

    test('is null on a GraphQL error', () async {
      final link = StubLink((_, __) => graphqlErrorResponse('boom'));
      expect(await _session(link).subtitleOffsets(), isNull);
    });
  });

  group('seasonEpisodes', () {
    const episodeTarget = PlaybackTarget(
      mediaType: 'episode',
      mediaId: 'ep-1',
      fileId: 'file-1',
      showId: 'show-1',
      seasonNumber: 2,
    );

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
      final link = StubLink((_, __) => {
            '__typename': 'Query',
            'seasonEpisodes': [episode(1, files: const [])],
          });
      await _session(link, target: episodeTarget).seasonEpisodes(3);
      expect(link.requests.single.variables,
          {'showId': 'show-1', 'seasonNumber': 3});
    });

    test('keeps null titles and the server file list shape', () async {
      final link = StubLink((_, __) => {
            '__typename': 'Query',
            'seasonEpisodes': [
              episode(1, files: [
                {'__typename': 'MediaFile', 'id': 'f-1'},
              ]),
              episode(2),
            ],
          });
      final episodes =
          (await _session(link, target: episodeTarget).seasonEpisodes(2))!;
      expect(episodes[0].title, 'The Lantern Keeper 1');
      expect(episodes[0].fileIds, ['f-1']);
      expect(episodes[1].title, isNull);
      expect(episodes[1].fileIds, isNull);
    });

    test('is null without a show id', () async {
      final link = StubLink((_, __) => {'__typename': 'Query'});
      expect(await _session(link).seasonEpisodes(1), isNull);
      expect(link.requests, isEmpty);
    });
  });

  group('searchSubtitles', () {
    test('refuses the offline sentinel without a request', () async {
      final link = StubLink((_, __) => {'__typename': 'Query'});
      final outcome = await _session(
        link,
        target: const PlaybackTarget(
            mediaType: 'movie', mediaId: 'movie-1', fileId: 'offline'),
      ).searchSubtitles(['eng']);
      expect(
          outcome.error, 'Subtitle search needs a connection to your server.');
      expect(link.requests, isEmpty);
    });

    test('shows the resolver message on a GraphQL error', () async {
      final link =
          StubLink((_, __) => graphqlErrorResponse('These results expired.'));
      final outcome = await _session(link).searchSubtitles(['eng']);
      expect(outcome.error, 'These results expired.');
    });

    test('sends the file and languages', () async {
      final link = StubLink((_, __) => graphqlErrorResponse('x'));
      await _session(link).searchSubtitles(['eng', 'por']);
      expect(link.requests.single.variables, {
        'mediaFileId': 'file-1',
        'languages': ['eng', 'por']
      });
    });
  });

  group('subtitleContent', () {
    test('returns the body', () async {
      final link = StubLink((_, __) => {
            '__typename': 'Query',
            'subtitleContent': 'WEBVTT\n\n00:00.000 --> 00:01.000\nHi',
          });
      expect(await _session(link).subtitleContent('3'), startsWith('WEBVTT'));
      expect(link.requests.single.variables,
          {'mediaFileId': 'file-1', 'trackId': '3'});
    });

    test('is null for an empty body', () async {
      final link =
          StubLink((_, __) => {'__typename': 'Query', 'subtitleContent': ''});
      expect(await _session(link).subtitleContent('3'), isNull);
    });

    test('is null on a GraphQL error', () async {
      final link = StubLink((_, __) => graphqlErrorResponse('boom'));
      expect(await _session(link).subtitleContent('3'), isNull);
    });
  });

  group('saveSubtitleOffset', () {
    test('sends the file, track and offset', () async {
      final link = StubLink((_, __) => {
            '__typename': 'Mutation',
            'setSubtitleOffset': {
              '__typename': 'SubtitleTrackSetting',
              'trackRef': '3',
              'offsetMs': 400,
            },
          });
      final outcome =
          await _session(link).saveSubtitleOffset(trackRef: '3', offsetMs: 400);
      expect(outcome, WriteOutcome.done);
      expect(link.requests.single.variables,
          {'mediaFileId': 'file-1', 'trackRef': '3', 'offsetMs': 400});
    });

    test('fails on a GraphQL error', () async {
      final link = StubLink((_, __) => graphqlErrorResponse('boom'));
      expect(
        await _session(link).saveSubtitleOffset(trackRef: '3', offsetMs: 1),
        WriteOutcome.failed,
      );
    });

    test('is unavailable without a client', () async {
      final link = StubLink((_, __) => {'__typename': 'Mutation'});
      final session = _session(link, hasClient: false);
      expect(session.canWrite, isFalse);
      expect(
        await session.saveSubtitleOffset(trackRef: '3', offsetMs: 1),
        WriteOutcome.unavailable,
      );
      expect(link.requests, isEmpty);
    });
  });

  group('rememberAudioLanguage', () {
    test('returns the updated preference list', () async {
      final link = StubLink((_, __) => {
            '__typename': 'Mutation',
            'setAudioLanguagePreference': {
              '__typename': 'AudioLanguagePreference',
              'mediaItemId': 'movie-1',
              'language': 'jpn',
              'preferredAudioLanguages': ['jpn', 'eng'],
            },
          });
      expect(await _session(link).rememberAudioLanguage('jpn'), ['jpn', 'eng']);
      expect(link.requests.single.variables,
          {'fileId': 'file-1', 'language': 'jpn'});
    });

    test('is null on a GraphQL error', () async {
      final link = StubLink((_, __) => graphqlErrorResponse('old server'));
      expect(await _session(link).rememberAudioLanguage('jpn'), isNull);
    });

    test('is null without a client', () async {
      final link = StubLink((_, __) => {'__typename': 'Mutation'});
      expect(
        await _session(link, hasClient: false).rememberAudioLanguage('jpn'),
        isNull,
      );
      expect(link.requests, isEmpty);
    });
  });

  group('writeSubtitlePreference', () {
    test('writes OFF for no track', () async {
      final link = StubLink((_, __) => {
            '__typename': 'Mutation',
            'setSubtitlePreference': {
              '__typename': 'SubtitlePreferenceResult',
              'mediaItemId': 'movie-1',
              'preference': null,
            },
          });
      await _session(link)
          .writeSubtitlePreference(fileId: 'file-7', resolved: null);
      final vars = link.requests.single.variables;
      expect(vars['fileId'], 'file-7');
      expect(vars['mode'], 'OFF');
    });

    test('does not throw on a GraphQL error', () async {
      final link = StubLink((_, __) => graphqlErrorResponse('boom'));
      await _session(link)
          .writeSubtitlePreference(fileId: 'file-7', resolved: null);
      expect(link.requests, hasLength(1));
    });
  });

  group('downloadSubtitle', () {
    test('refuses the offline sentinel', () async {
      final link = StubLink((_, __) => {'__typename': 'Mutation'});
      final session = _session(
        link,
        target: const PlaybackTarget(
            mediaType: 'movie', mediaId: 'movie-1', fileId: 'offline'),
      );
      await expectLater(
        session.downloadSubtitle(_candidate()),
        throwsA(isA<SubtitleActionException>()),
      );
      expect(link.requests, isEmpty);
    });

    test('throws the resolver message on a GraphQL error', () async {
      final link = StubLink((_, __) => graphqlErrorResponse('Search again.'));
      await expectLater(
        _session(link).downloadSubtitle(_candidate()),
        throwsA(isA<SubtitleActionException>()
            .having((e) => e.message, 'message', 'Search again.')),
      );
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
