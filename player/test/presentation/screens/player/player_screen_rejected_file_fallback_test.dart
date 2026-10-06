// Regression coverage for playback pinned to a file that no longer exists.
//
// A quality upgrade, or a manual delete-and-redownload, replaces a movie's
// file: a new `media_files` row is written and the old one is deleted. The
// screen asks the server about the file the route names, so a route built
// before that swap still carries the deleted file's id. The server answers
// an id it does not recognize with a GraphQL error, which the session
// reports as `serverRejected`, and `_initializePlayer` then re-asks by media
// item and plays the file the server ranks. Without that fallback a p2p
// direct stream for the deleted file answers "media file not found", no
// bytes arrive and the screen sits on a black frame.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../test_utils/scripted_mydia_transport.dart';
import 'player_screen_test_harness.dart';

void main() {
  testWidgets(
      'a file the server has rejected falls back to the server-ranked file '
      'for the media item', (tester) async {
    final proxyService = TrackingLocalProxyService();

    // `file-old` is what the route still names; the server has dropped it
    // and says so with a GraphQL error. The re-ask by media item is what the
    // server ranks highest today. The two `StreamingCandidates` calls share
    // an operation name, so they are told apart by the id they ask about.
    final server = ScriptedMydiaTransport((request, index) {
      switch (request.operation) {
        case 'MovieDetail':
          return movieDetailResponse();
        case 'MovieSegments':
          return movieSegmentsResponse();
        case 'SubtitleTrackSettings':
          return subtitleTrackSettingsResponse();
        case 'MovieSubtitlePreference':
          return subtitlePreferenceResponse();
      }
      if (request.variables['id'] == 'file-old') {
        return graphqlError('file not found');
      }
      return streamingCandidatesResponse(
        duration: 5400,
        directPlay: true,
        fileId: 'file-new',
      );
    });

    final container = buildPlayerScreenContainer(
      server: server,
      connectionState: HarnessLink.p2p(serverNodeAddr: 'node-addr'),
      castManager: CapturingCastSessionManager(),
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container, fileId: 'file-old');
    await pumpUntil(
      tester,
      () => proxyService.directStreamFileIds.isNotEmpty,
    );

    expect(
      proxyService.directStreamFileIds,
      contains('file-new'),
      reason: 'once the server rejects the route\'s file id, the file to '
          'play has to come from the server\'s re-ranked answer for the '
          'media item, not the id the route still carries',
    );
    expect(
      proxyService.directStreamFileIds,
      isNot(contains('file-old')),
      reason: 'file-old no longer exists; streaming it is the black screen '
          'this fallback exists to avoid',
    );

    // Pins the mechanism too: the first call asks about the rejected file,
    // and only the retry asks by media item. The pre-play queries run
    // concurrently, so only the two candidates calls' own order is fixed.
    final candidates = server.of('StreamingCandidates');
    expect(candidates, hasLength(2));
    expect(candidates[0].variables['contentType'], 'file');
    expect(candidates[0].variables['id'], 'file-old');
    expect(candidates[1].variables['contentType'], 'movie');
    expect(candidates[1].variables['id'], 'movie-1');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
