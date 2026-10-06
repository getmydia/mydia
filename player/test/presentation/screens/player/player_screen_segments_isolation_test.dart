// Pins that the skippable-segments query is isolated from the detail query.
//
// `segments` lives in its own document rather than in `MediaFileFragment`
// because an unknown field is a *document* validation error in GraphQL, not a
// field-level one: a server predating the segments schema rejects the entire
// query the selection appears in and returns no data at all. Inside the shared
// fragment that would silently cost the resume position and the external
// subtitle list on every episode and movie detail view.
//
// This is the common path for a self-hosted app, not an edge case. The player
// auto-updates from an app store; the operator upgrades the server by hand,
// sometimes months later.
//
// The test drives that exact scenario: the segments query fails the way an
// older server fails it, while the detail query succeeds. The resume prompt is
// the observable proof that the detail response was still consumed, since it
// only appears when `progress.positionSeconds` made it through. Folding
// `segments` back into `MediaFileFragment` cannot fail this test directly (the
// stub answers per operation), so the second test pins the request shape
// instead: exactly one segments document, separate from the detail one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/sources/source_error.dart';

import '../../../test_utils/scripted_mydia_transport.dart';
import 'player_screen_test_harness.dart';

/// Answers per operation, so the response script does not depend on the order
/// the screen happens to issue its queries in.
ScriptedMydiaTransport _serverAnsweringSegmentsWith(Object segmentsOutcome) {
  return ScriptedMydiaTransport((request, index) {
    if (request.operation == 'MovieSegments') return segmentsOutcome;
    if (request.operation == 'MovieDetail') {
      // 45 minutes into a 90 minute movie, comfortably inside every bound
      // `shouldOfferResume` checks.
      return movieDetailResponse(positionSeconds: 2700);
    }
    if (request.operation == 'SubtitleTrackSettings') {
      return subtitleTrackSettingsResponse();
    }
    if (request.operation == 'MovieSubtitlePreference') {
      return subtitlePreferenceResponse();
    }
    return streamingCandidatesResponse(duration: 5400, directPlay: true);
  });
}

void main() {
  testWidgets('a segments failure leaves the rest of the detail data intact',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // The exact shape an older server answers with: the field does not exist,
    // so validation rejects the document.
    final server = _serverAnsweringSegmentsWith(
      graphqlError(
        'Cannot query field "segments" on type "MediaFile".',
      ),
    );

    final container = buildPlayerScreenContainer(
      server: server,
      connectionState: HarnessLink.p2p(serverNodeAddr: 'node-addr'),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => find.text('Resume').evaluate().isNotEmpty);

    expect(
      find.text('Resume'),
      findsOneWidget,
      reason: 'the segments query failed the way an older server fails it, '
          'and the resume position still came through',
    );
    expect(find.text('Start Over'), findsOneWidget);

    expect(
      server.of('MovieSegments'),
      hasLength(1),
      reason: 'the failing path has to have actually been exercised',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('a thrown transport error on segments is swallowed too',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // Not every failure arrives as a well-formed GraphQL error response; a
    // transport that throws has to land on the same answer.
    final server =
        _serverAnsweringSegmentsWith(const SourceException.unreachable());

    final container = buildPlayerScreenContainer(
      server: server,
      connectionState: HarnessLink.p2p(serverNodeAddr: 'node-addr'),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => find.text('Resume').evaluate().isNotEmpty);

    expect(find.text('Resume'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('segments travel in their own document, not the detail one',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final server = _serverAnsweringSegmentsWith(const {
      '__typename': 'Query',
      'movie': {
        '__typename': 'Movie',
        'id': 'movie-1',
        'files': [
          {
            '__typename': 'MediaFile',
            'id': 'file-1',
            'segments': [
              {
                '__typename': 'MediaSegment',
                'type': 'INTRO',
                'startMs': 30000,
                'endMs': 90000,
              },
            ],
          },
        ],
      },
    });

    final container = buildPlayerScreenContainer(
      server: server,
      connectionState: HarnessLink.p2p(serverNodeAddr: 'node-addr'),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(
      tester,
      () => server.requests.any((r) => r.operation == 'MovieSegments'),
    );

    expect(
      server.of('MovieSegments'),
      hasLength(1),
      reason: 'one segments query per playback, not one per detail selection',
    );
    expect(
      server.of('MovieDetail'),
      hasLength(1),
      reason: 'the detail query is still its own separate request, and the '
          'segments selection did not ride along inside it',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
