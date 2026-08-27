// Regression coverage for `_castToTargetIfSet`'s failure branch.
//
// Every existing test that mounts `PlayerScreen` with a `CastLaunchRequest`
// captured by `CapturingCastSessionManager` only ever exercises the success
// path — `startCast` always resolves. That leaves the `catch` branch in
// `_castToTargetIfSet` (player_screen.dart) completely unpinned: nothing
// proves a failed cast still lets the user watch locally, and nothing proves
// the chosen device survives the failure so the cast bar can offer a
// reconnect. A `castTargetProvider.notifier.clear()` deliberately does NOT
// belong in that catch block (see the method's own doc comment), but nothing
// stopped a future edit from reintroducing it — this test is what would
// catch that.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

void main() {
  testWidgets(
      'a failed cast keeps the chosen device and falls through to local '
      'playback', (tester) async {
    final castManager = CapturingCastSessionManager()
      ..startCastError = const CastBackendException(
        'fake unreachable receiver',
        CastFailureKind.unreachable,
      );
    final proxyService = TrackingLocalProxyService();

    // Direct play, and 12s in — below `kMinResumeThresholdSeconds` — so no
    // resume dialog to answer and no HLS session mutation to stub for the
    // local fallback.
    final link = StubLink.responses([
      movieDetailResponse(positionSeconds: 12),
      movieSegmentsResponse(),
      subtitleTrackSettingsResponse(),
      streamingCandidatesResponse(duration: 5400, directPlay: true),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    // Chosen before the screen mounts, exactly like `CastButton` on a detail
    // screen.
    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => castManager.capturedRequest != null);

    // Confirms the cast really was attempted (and therefore really failed),
    // rather than this test passing because startCast was never reached.
    expect(castManager.capturedRequest, isNotNull);

    // Local playback was attempted after the cast failed: it fails too,
    // under `flutter test`, because building a real media_kit `Player`
    // requires `MediaKit.ensureInitialized` (see
    // `direct_play_resume_prompt_test.dart`'s header) — but that failure is
    // caught and turned into this error state. Reaching it at all is the
    // proof that `_castToTargetIfSet` returned false and execution fell
    // through, rather than the screen going blank on the failed cast.
    await pumpUntil(tester, () => castManager.capturedRequest != null);
    await pumpUntil(
      tester,
      () => find.text('Failed to load video').evaluate().isNotEmpty,
    );
    expect(find.text('Failed to load video'), findsOneWidget,
        reason: 'a failed cast must fall through to a local playback '
            'attempt, not strand the user on a dead screen');

    expect(container.read(castTargetProvider), testDevice,
        reason: 'the chosen device must survive a failed cast so the cast '
            'bar can still offer a reconnect — clearing it here would be '
            'the regression this test exists to catch');
  });
}
