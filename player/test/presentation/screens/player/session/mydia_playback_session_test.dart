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
}
