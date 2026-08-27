// Regression coverage for the next-episode handoff killing the shared proxy.
//
// One loopback proxy serves every call site that needs p2p media bytes.
// `_terminateHlsSession` used to stop it outright from `dispose()`, which on
// an Up Next navigation closed the server the episode that had just started
// was streaming from: mpv reported
// `Failed to open http://127.0.0.1:<port>/direct/<file>/stream`, the screen
// detected zero audio and subtitle tracks, and playback sat at position 0.
//
// The captured log of that failure has the incoming screen's
// `Media proxy serving at http://127.0.0.1:45273` at 22:37:25 and the
// outgoing screen's `Media proxy stopped` at 22:41:59 — the new screen took
// the proxy first and the old one closed it afterwards. That ordering is what
// makes an unconditional stop wrong, and it is what the first test drives.
//
// It stands a plain object in for the incoming screen rather than mounting a
// second `PlayerScreen`: `_initializePlayer` reaches `proxy.start` only after
// several awaits, while `dispose()` runs at the end of the frame, so a keyed
// swap of two real screens lands the release *before* the second acquire —
// the harmless order, which would leave the regression unpinned. What
// `PlayerScreen` owns here is the release, and that is what this asserts.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

/// Whether [request] carries the named operation.
///
/// `request.operation.operationName` is null for everything this screen
/// issues, because `QueryOptions` never sets it. The printed query text names
/// the operation on its first line, which is what is left to match on.
bool _isOperation(Request request, String name) =>
    request.operation.toString().contains(name);

/// Answers per operation rather than per call index, so the script does not
/// depend on the order the screen happens to issue its queries in.
StubLink _link() {
  return StubLink((request, _) {
    if (_isOperation(request, 'query MovieSegments')) {
      return movieSegmentsResponse();
    }
    if (_isOperation(request, 'query MovieDetail')) {
      return movieDetailResponse();
    }
    if (_isOperation(request, 'query SubtitleTrackSettings')) {
      return subtitleTrackSettingsResponse();
    }
    if (_isOperation(request, 'endStreamingSession')) {
      return endStreamingSessionResponse();
    }
    return streamingCandidatesResponse(duration: 5400, directPlay: true);
  });
}

void main() {
  testWidgets(
      'dispose() releases only this screen\'s hold, leaving the proxy up for '
      'the screen that replaced it', (tester) async {
    final proxyService = TrackingLocalProxyService();

    final container = buildPlayerScreenContainer(
      link: _link(),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
      castManager: CapturingCastSessionManager(),
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => proxyService.directStreamFileIds.isNotEmpty);
    expect(proxyService.directStreamFileIds, isNotEmpty,
        reason: 'sanity check: this screen must actually have taken the '
            'proxy, or its release below proves nothing');

    // The episode Up Next moved to, which has already started the proxy and
    // built its stream URL against it by the time the outgoing screen is
    // disposed.
    final incoming = Object();
    await proxyService.start(owner: incoming, targetPeer: 'node-addr');
    addTearDown(proxyService.shutdown);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(proxyService.isRunning, isTrue,
        reason: 'the outgoing screen released its own hold, not the proxy: '
            'the episode now playing is still streaming from it');
    expect(proxyService.stopped, isFalse,
        reason: 'nothing tore the proxy down while a call site still needed '
            'it');
  });

  // `_isP2PMode` tracks the *current* connection mode, not the one this
  // screen took the proxy under, and a reconnect can move a viewer between
  // the two mid-episode. Gating the release on it means a screen that started
  // the proxy over p2p and ended up on a direct connection never lets go —
  // and because the hold is keyed on a State that is now gone, nothing can
  // ever release it and the proxy is stuck up for the rest of the session.
  testWidgets('dispose() releases its hold even if the mode changed since',
      (tester) async {
    final proxyService = TrackingLocalProxyService();

    final container = buildPlayerScreenContainer(
      link: _link(),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
      castManager: CapturingCastSessionManager(),
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => proxyService.directStreamFileIds.isNotEmpty);
    expect(proxyService.isRunning, isTrue,
        reason: 'sanity check: the screen took the proxy while on p2p');

    // The viewer reconnects onto a direct connection mid-playback.
    (container.read(conn.connectionProvider.notifier)
            as FixedConnectionNotifier)
        .switchTo(conn.ConnectionState.direct());
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(proxyService.isRunning, isFalse,
        reason: 'the hold is keyed on a State that no longer exists, so a '
            'release skipped here can never happen at all');
    expect(proxyService.stopped, isTrue);
  });

  testWidgets('dispose() stops the proxy when nothing else holds it',
      (tester) async {
    final proxyService = TrackingLocalProxyService();

    final container = buildPlayerScreenContainer(
      link: _link(),
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
      castManager: CapturingCastSessionManager(),
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => proxyService.directStreamFileIds.isNotEmpty);

    // Leaving the player altogether rather than moving between episodes.
    // Holding the proxy open past the last screen would leak a bound socket
    // and the auth token it serves with, so the release still has to happen.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(proxyService.isRunning, isFalse);
    expect(proxyService.stopped, isTrue,
        reason: 'the last holder let go, so the proxy is torn down rather '
            'than left bound for the rest of the session');
  });
}
