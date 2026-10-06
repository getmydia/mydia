// Companion to `player_screen_dispose_cleanup_test.dart`: that file proves
// dispose() stops the local P2P proxy; this proves the *other* half of
// `_terminateHlsSession`'s cleanup — actually ending the HLS session on the
// server via the `EndStreamingSession` mutation — genuinely runs, using the
// controller's own client rather than the dispose()-time `ref.read` that
// used to throw before any of this could happen.
//
// The controller owns every session it starts and immediately cleans one up
// when its playlist never becomes ready. This test must therefore give it a
// ready in-memory playlist, so its pre-dispose assertion reaches the source
// that is still live and its post-dispose assertion exercises screen cleanup.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/scripted_mydia_transport.dart';
import 'player_screen_test_harness.dart';

void main() {
  testWidgets(
      'dispose() ends the HLS session on the server, with no ref-safety '
      'error', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // The pre-play queries now fire concurrently (see `runIsolated`), so an
    // ordered `StubLink.responses` list can no longer script them -- dispatch
    // on the operation instead. `startStreamingSession` and
    // `endStreamingSession` still fire well after those, so they are told
    // apart by the variables only they carry.
    final server = ScriptedMydiaTransport((request, index) {
      if (request.operation == 'MovieDetail') return movieDetailResponse();
      if (request.operation == 'MovieSegments') return movieSegmentsResponse();
      if (request.operation == 'SubtitleTrackSettings') {
        return subtitleTrackSettingsResponse();
      }
      if (request.operation == 'MovieSubtitlePreference') {
        return subtitlePreferenceResponse();
      }
      if (request.variables.containsKey('strategy')) {
        return startStreamingSessionResponse(sessionId: 'sess-42');
      }
      if (request.variables.containsKey('sessionId')) {
        return endStreamingSessionResponse();
      }
      return streamingCandidatesResponse(duration: 5400);
    });

    final container = buildPlayerScreenContainer(
      server: server,
      connectionState: HarnessLink.direct(),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await mockHttpResponse(
      () async {
        await pumpPlayerScreen(tester, container);
        await tester.pumpAndSettle();

        expect(
          server.of('EndStreamingSession'),
          isEmpty,
          reason: 'sanity check: the session must not already be ended before '
              'dispose, or this test proves nothing about dispose() specifically',
        );

        // Unmount. Before the fix, this throws `StateError` on the very first
        // line of `_terminateHlsSession` (see `player_screen_dispose_cleanup_
        // test.dart`'s header for why); the exception is asserted null
        // explicitly for the same reason it is there.
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);

        final endSessionRequests = server.of('EndStreamingSession');
        expect(endSessionRequests, hasLength(1),
            reason: '_terminateHlsSession must have sent the '
                'EndStreamingSession mutation during dispose()');
        expect(endSessionRequests.single.variables['sessionId'], 'sess-42',
            reason: 'must end the session this screen actually started, using '
                'the sessionId captured from the startStreamingSession response');
      },
      responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits,
    );
  });
}
