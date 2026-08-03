// A cast target chosen before playback (CastButton on a detail screen) used
// to short-circuit straight into `startCast` from three call sites inside
// `_initializePlayer`, every one of them upstream of the resume prompt. The
// receiver therefore always started at zero, and `CastLaunchRequest` was
// built with no `startPosition` at all.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

void main() {
  testWidgets('asks before casting, and carries the answer to the receiver',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // 45 minutes into a 90 minute movie.
    final link = StubLink.responses([
      movieDetailResponse(positionSeconds: 2700),
      streamingCandidatesResponse(duration: 5400),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => find.text('Resume').evaluate().isNotEmpty);

    expect(
      find.text('Resume'),
      findsOneWidget,
      reason: 'choosing a cast device must not skip the resume question',
    );

    await tester.tap(find.text('Resume'));
    await pumpUntil(tester, () => castManager.capturedRequest != null);

    expect(
      castManager.capturedRequest!.startPosition,
      const Duration(seconds: 2700),
      reason: 'the answer must reach the receiver, not be discarded',
    );
  });

  testWidgets('start over sends the receiver to the beginning', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final link = StubLink.responses([
      movieDetailResponse(positionSeconds: 2700),
      streamingCandidatesResponse(duration: 5400),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(
        tester, () => find.text('Start Over').evaluate().isNotEmpty);
    await tester.tap(find.text('Start Over'));
    await pumpUntil(tester, () => castManager.capturedRequest != null);

    expect(castManager.capturedRequest!.startPosition, Duration.zero);
  });

  testWidgets('does not ask when there is nothing to resume', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // 12 seconds in, below kMinResumeThresholdSeconds.
    final link = StubLink.responses([
      movieDetailResponse(positionSeconds: 12),
      streamingCandidatesResponse(duration: 5400),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => castManager.capturedRequest != null);

    expect(find.text('Resume'), findsNothing);
    expect(castManager.capturedRequest!.startPosition, Duration.zero);
  });
}
