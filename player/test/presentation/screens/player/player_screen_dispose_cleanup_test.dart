// Regression coverage for the dispose()-time `ref.read` bug in
// `_terminateHlsSession`. Before the fix, calling it from `dispose()` threw
// `StateError` on its very first line — before doing any of its real work —
// because `BuildContext.mounted` is `false` throughout `State.dispose()` by
// core Flutter design, not a Riverpod quirk. Because `_terminateHlsSession`
// is `async` and called without `await` from `dispose()`, that throw never
// surfaced as a visible crash in production; it just meant cleanup silently
// never ran. A test that only proves the method no longer throws would not
// catch a regression that reintroduced a *different* dispose()-time `ref`
// use — this test instead proves the actual cleanup work runs.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

void main() {
  testWidgets(
      'dispose() stops the local P2P proxy when the connection is in P2P '
      'mode, with no ref-safety error', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // The target is pre-set, like `CastButton` on a detail screen, so
    // `_castToTargetIfSet` short-circuits `_initializePlayer` before it ever
    // reaches HLS negotiation. `_isP2PMode` is unaffected by that: it's
    // populated by a `ref.listenManual` set up in `initState`, unconditionally,
    // before `_initializePlayer` even runs — this test only needs that
    // listener and the P2P connection state, nothing about the streaming
    // candidates or progress queries this scenario never reaches.
    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      streamingCandidatesResponse(duration: 5400),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'peer-1'),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => castManager.capturedRequest != null);
    expect(castManager.capturedRequest, isNotNull,
        reason: 'sanity check: the cast short-circuit must actually have '
            'run before dispose, or this test proves nothing about the P2P '
            'mode captured at that point');
    expect(proxyService.stopped, isFalse,
        reason: 'stop() must not fire until dispose — otherwise this test '
            'could pass even if dispose() never called it');

    // Unmount. Before the fix, `_PlayerScreenState.dispose()` throws here
    // (see this file's header) — that exception is reported through
    // Flutter's own error-reporting zone rather than at this `await`, which
    // is why `tester.takeException()`, not a try/catch, is what would
    // surface it. It's asserted null explicitly below rather than merely
    // relying on the test framework to fail on an unconsumed error, so a
    // regression here reads as a clear assertion failure instead of a wall
    // of framework stack trace.
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);

    expect(proxyService.stopped, isTrue,
        reason: '_terminateHlsSession must have called proxy.stop() during '
            'dispose(), since the connection was in P2P mode throughout');
  });
}
