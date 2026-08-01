// Regression coverage for the resume prompt on the NON-HLS playback paths.
//
// `_openPlayerAndStart` is the shared tail of three branches of
// `_initializePlayer`: HLS, native direct play, and "already downloaded but
// still online". The resume prompt used to live there, covering all three.
// When it moved up into the HLS branch — so the answer could be baked into
// FFmpeg's `-ss` start offset, which is the only way to resume a live-style
// playlist — the other two silently lost it, and playback on the preferred
// desktop/mobile path always started at zero.
//
// This test mounts the real screen down the direct-play branch and asserts
// the dialog appears. Removing `promptResume: canDirect` from the streaming
// call site, or the prompt from `_openPlayerAndStart`, fails it.
//
// The tree is torn down while the dialog is still open rather than answering
// it: answering would let `_openPlayerAndStart` continue on to construct a
// real media_kit `Player`, which throws `MediaKit.ensureInitialized must be
// called` under `flutter test` (see `seek_restart_decision_test.dart`'s
// header for the related native-mpv constraint). That throw is caught and
// turned into an error state, so it is harmless — the second test below
// walks straight into it — but there is nothing past it worth asserting on.
// Tearing down instead also exercises the `!mounted` guard placed after the
// dialog's unbounded await.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

void main() {
  testWidgets('direct play still asks whether to resume', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // 45 minutes into a 90 minute movie: comfortably inside every bound
    // `shouldOfferResume` checks, so the only thing that can suppress the
    // dialog is the call site being gone.
    final link = StubLink.responses([
      movieDetailResponse(positionSeconds: 2700),
      streamingCandidatesResponse(duration: 5400, directPlay: true),
    ]);

    // P2P, so the direct-play URL comes from the stub proxy rather than the
    // real media-token service.
    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => find.text('Resume').evaluate().isNotEmpty);

    expect(
      find.text('Resume'),
      findsOneWidget,
      reason: 'direct play holds the whole file locally and resumes with a '
          'plain seek — but it still has to ask',
    );
    expect(find.text('Start Over'), findsOneWidget);

    // Replace the route while the dialog is open: `_openPlayerAndStart` must
    // not go on to build a `Player` for a dead screen.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('direct play does not ask when there is nothing to resume',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // 12 seconds in — below `kMinResumeThresholdSeconds`. The prompt must be
    // gated by `shouldOfferResume`, not shown unconditionally.
    final link = StubLink.responses([
      movieDetailResponse(positionSeconds: 12),
      streamingCandidatesResponse(duration: 5400, directPlay: true),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    // Deliberately not `pumpUntil` on an absence — pump a fixed number of
    // frames covering more than enough microtask turns for both stubbed
    // GraphQL calls to land and the branch to be taken.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.text('Resume'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
