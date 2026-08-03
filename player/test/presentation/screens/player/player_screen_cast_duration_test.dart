// Regression guard for a cast-duration bug found while reviewing Task 7
// (asking to resume before an HLS session starts), fixed in commit
// dea523a3 ("publish cast duration at the source, not a fallback read").
//
// `PlayerScreen` can short-circuit playback into `CastSessionManager.
// startCast` — via `_castToTargetIfSet`, at the "network streaming branch"
// call site — before any local `Player` or HLS session exists, whenever the
// user picked a cast target before opening a title (`CastButton` on a detail
// screen, not the in-player picker). `_knownCastDuration()` falls back to
// `_timeline.totalDuration` in that no-player case, and a Mydia HLS session
// never reports its own duration (no `EXT-X-ENDLIST` until FFmpeg
// finishes), so if `_timeline` is not populated by that point the receiver
// gets `duration: null` and is stranded with no scrub bar length. The fix
// publishes the resolved duration into `_timeline` immediately after
// `_resolveRealDuration` runs, before the cast short-circuit, rather than
// only after an HLS session's mutation returns.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

void main() {
  testWidgets(
      'hands the receiver the resolved runtime when casting short-circuits '
      'playback before any HLS session exists', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      streamingCandidatesResponse(duration: 5400),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    // The target is chosen before playback, exactly like `CastButton` on a
    // detail screen: `castTargetProvider` already carries a device by the
    // time `PlayerScreen` mounts and reads it.
    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => castManager.capturedRequest != null);

    final captured = castManager.capturedRequest;
    expect(captured, isNotNull);
    expect(
      captured!.duration,
      const Duration(seconds: 5400),
      reason: 'The receiver must get the server-known runtime even though '
          'casting short-circuits before any local Player or HLS session '
          'exists.',
    );
  });

  testWidgets('a successful cast leaves the chosen device set', (tester) async {
    // Clearing it here would drop the cast icon to white while the cast is
    // running — the reported bug, inverted. Opting out is the bar's ✕ or
    // Stop, both of which disconnect.
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final link = StubLink.responses([
      movieDetailResponse(),
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

    expect(container.read(castTargetProvider), testDevice);
  });
}
