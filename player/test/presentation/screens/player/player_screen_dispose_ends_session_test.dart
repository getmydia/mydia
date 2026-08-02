// Companion to `player_screen_dispose_cleanup_test.dart`: that file proves
// dispose() stops the local P2P proxy; this proves the *other* half of
// `_terminateHlsSession`'s cleanup — actually ending the HLS session on the
// server via the `EndStreamingSession` mutation — genuinely runs, using the
// captured `_graphqlClient` rather than the dispose()-time `ref.read` that
// used to throw before any of this could happen.
//
// Reaching a real, non-null `_hlsSessionId` means going through the whole
// HLS negotiation path, including `_waitForPlaylist`'s (unstubbed) HTTP
// polling. `flutter_test`'s own `HttpOverrides` turns every such call into
// an instant 400 response (never touching the network), and `FakeAsync`
// governs the retry backoff, so `pumpAndSettle` drains the retry loop to
// exhaustion quickly and deterministically — `_initializePlayer`'s own
// try/catch then absorbs the resulting "playlist not ready" failure exactly
// as it would absorb a real one, leaving `_hlsSessionId` set from before.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/graphql/mutations/end_streaming_session.graphql.dart';

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

void main() {
  testWidgets(
      'dispose() ends the HLS session on the server, with no ref-safety '
      'error', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final link = StubLink.responses([
      movieDetailResponse(),
      streamingCandidatesResponse(duration: 5400),
      startStreamingSessionResponse(sessionId: 'sess-42'),
      endStreamingSessionResponse(),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);

    // Let `_initializePlayer` run to completion: the mutation resolves
    // (setting `_hlsSessionId`), then `_waitForPlaylist` exhausts its
    // retries against the framework's synthetic 400s and the outer
    // try/catch absorbs the resulting exception.
    await tester.pumpAndSettle();

    expect(
      link.requests
          .where((r) =>
              r.operation.document == documentNodeMutationEndStreamingSession)
          .toList(),
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

    final endSessionRequests = link.requests
        .where((r) =>
            r.operation.document == documentNodeMutationEndStreamingSession)
        .toList();
    expect(endSessionRequests, hasLength(1),
        reason: '_terminateHlsSession must have sent the EndStreamingSession '
            'mutation during dispose()');
    expect(endSessionRequests.single.variables['sessionId'], 'sess-42',
        reason: 'must end the session this screen actually started, using '
            'the sessionId captured from the startStreamingSession response');
  });
}
