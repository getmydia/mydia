// Backfilled coverage for the branch's headline behaviour: resume answered,
// the `startStreamingSession` mutation sent with a requested `startPosition`,
// and `_timeline` built from the *echoed* `sessionResult.startPosition ?? 0`
// — never the requested value. `player_screen.dart`'s own comment at the
// build site explains why: the server clamps the value and FFmpeg's `-ss`
// lands on the nearest keyframe, so the stream can legitimately start
// earlier than asked; an older server that omits the field must fall back to
// offset zero, not the request.
//
// `_timeline` is private state with no public getter, so these tests read it
// through the `debugPrint('[PlayerScreen] Stream timeline: $_timeline')` line
// immediately after it's built — genuine production log output, not a
// reflection hack, and it fires before `_waitForPlaylist`'s real (unstubbed)
// HTTP polling would otherwise need to be reached.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

void main() {
  // Restored inside each test body (try/finally), not via `tearDown`:
  // `TestWidgetsFlutterBinding._verifyInvariants` checks that `debugPrint`
  // is back to the binding's own expected value *before* `package:test`'s
  // `tearDown` callbacks run, so restoring there is one step too late and
  // trips "The value of a foundation debug variable was changed by the
  // test" even though the value genuinely does get put back.
  Future<T> withCapturedDebugPrint<T>(
    List<String> into,
    Future<T> Function() body,
  ) async {
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) into.add(message);
    };
    try {
      return await body();
    } finally {
      debugPrint = original;
    }
  }

  Future<void> answerResumeDialog(WidgetTester tester) async {
    await pumpUntil(tester, () => find.text('Resume').evaluate().isNotEmpty);
    expect(find.text('Resume'), findsOneWidget,
        reason: 'sanity check: the resume dialog must actually appear, or '
            'the rest of this test exercises the start-over path instead');
    await tester.tap(find.text('Resume'));
    await tester.pump();
  }

  testWidgets(
      'builds the timeline from the echoed startPosition, not the requested '
      'one', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // Requested: 2700s (the saved position). Echoed: 2695s — deliberately
    // different, simulating the server clamping to the nearest keyframe.
    // If a regression fed the *requested* value into the timeline instead,
    // the assertion below (looking for the 2695 offset) would fail.
    final link = StubLink.responses([
      movieDetailResponse(positionSeconds: 2700),
      movieSegmentsResponse(),
      streamingCandidatesResponse(duration: 5400),
      startStreamingSessionResponse(startPosition: 2695),
      endStreamingSessionResponse(),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    final loggedLines = <String>[];
    await withCapturedDebugPrint(loggedLines, () async {
      await pumpPlayerScreen(tester, container);
      await answerResumeDialog(tester);

      await pumpUntil(
        tester,
        () => loggedLines.any((l) => l.contains('Stream timeline:')),
      );
    });

    // The timeline assertion this test cares about has already been
    // captured above; this just drains `_waitForPlaylist`'s background
    // retry loop (real HTTP calls, but `flutter_test`'s `HttpOverrides`
    // makes every one an instant 400, and `FakeAsync` governs the retry
    // backoff timers) so no pending timer survives into the framework's
    // own end-of-test check. `_waitForPlaylist` has no `mounted` guard on
    // the loop itself — only around the `setState` calls inside it — so it
    // keeps running to exhaustion regardless of widget disposal.
    await tester.pumpAndSettle();

    final timelineLine = loggedLines.firstWhere(
      (l) => l.contains('Stream timeline:'),
      orElse: () => '',
    );
    expect(timelineLine, contains('startOffset: 0:44:55.000000'),
        reason: '2695 seconds is 0:44:55 — the echoed offset, not the '
            'requested 2700s (0:45:00)');
    expect(timelineLine, isNot(contains('0:45:00.000000')),
        reason: 'must not carry the requested offset');
  });

  testWidgets(
      'falls back to offset zero when an older server omits startPosition '
      'entirely', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final link = StubLink.responses([
      movieDetailResponse(positionSeconds: 2700),
      movieSegmentsResponse(),
      streamingCandidatesResponse(duration: 5400),
      // No `startPosition` key at all — the older-server case.
      startStreamingSessionResponse(startPosition: null),
      endStreamingSessionResponse(),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    final loggedLines = <String>[];
    await withCapturedDebugPrint(loggedLines, () async {
      await pumpPlayerScreen(tester, container);
      await answerResumeDialog(tester);

      await pumpUntil(
        tester,
        () => loggedLines.any((l) => l.contains('Stream timeline:')),
      );
    });

    await tester.pumpAndSettle();

    final timelineLine = loggedLines.firstWhere(
      (l) => l.contains('Stream timeline:'),
      orElse: () => '',
    );
    expect(timelineLine, contains('startOffset: 0:00:00.000000'),
        reason: 'sessionResult.startPosition ?? 0 must yield zero when the '
            'field is entirely absent, not throw or carry the request');
  });
}
