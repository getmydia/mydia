import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/presentation/screens/player/session/mydia_playback_session.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';

import '../../../../test_utils/stub_graphql_client.dart';
import '../player_screen_test_harness.dart';

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
}
