// `_initializeOfflinePlayback` used to be a separate 40-line player init that
// never reached `_openPlayerAndStart`, so the offline path never prompted,
// never seeked, and never tracked progress. It is now a source resolver that
// feeds the shared tail like every other path.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

void main() {
  setUp(mockPathProviderDocumentsDirectory);

  testWidgets('offline playback resolves a download and starts',
      (tester) async {
    // A real file, not a path that merely looks plausible: `downloadedItem`
    // feeds this straight to `_resolveDownloadedFilePath`, whose *first*
    // check is `file_utils.fileExists`. A nonexistent path answers that
    // check `false` and the offline branch bails out at the pre-existing
    // "downloaded file not found" `setState` — before any code this task
    // added ever runs. That bail-out sits upstream of the resume decision,
    // the cast check, and `_openPlayerAndStart`, so a nonexistent path here
    // would make this test pass identically against the deleted
    // `_initializeOfflinePlayback` and against today's routing, proving
    // nothing about which one actually ran.
    final tempDir =
        Directory.systemTemp.createTempSync('mydia_offline_resume_test_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final tempFile = File('${tempDir.path}/arrival.mkv')
      ..writeAsBytesSync(const [0]);

    final container = buildPlayerScreenContainer(
      // Offline mode issues no GraphQL at all; the stub link must never be
      // hit, so unlike most tests in this directory it has no scripted
      // responses to play back and throws if a request ever reaches it.
      link: StubLink((request, callIndex) =>
          throw StateError('offline mode must not issue GraphQL requests')),
      connectionState: conn.ConnectionState.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      downloaded: downloadedItem(filePath: tempFile.path, runtimeMinutes: 90),
      authStatus: AuthStatus.offlineMode,
    );
    addTearDown(container.dispose);

    // Unlike every other test in this directory, this path exercises real
    // `dart:io` (`File.exists`) via `_resolveDownloadedFilePath`, genuine
    // asynchronous I/O rather than a Dart timer/microtask, so it never
    // completes under plain `tester.pump()`: `AutomatedTestWidgetsFlutterBinding`
    // runs the test body in a synchronous fake-async zone that `pump()`
    // advances by a virtual `Duration` without ever yielding to the real
    // event loop. `runAsync` breaks out of that zone, and the mount itself
    // has to happen inside it too — a pending real Future started before
    // entering `runAsync` is orphaned in the fake zone that scheduled it and
    // never gets flushed afterward. `pumpUntilReal`'s real `Future.delayed`
    // between pumps is what actually yields control, letting the pending I/O
    // deliver its result — and it polls for the outcome rather than pumping
    // a fixed number of times, so this doesn't race a loaded machine.
    await tester.runAsync(() async {
      await pumpPlayerScreen(tester, container);
      await pumpUntilReal(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
    });

    // The real file makes `_resolveDownloadedFilePath` return it on the
    // *first* check, past the "downloaded file not found" bail-out, so
    // execution reaches `resolveResumePlan`, `_castToTargetIfSet`, and
    // `_openPlayerAndStart` — which constructs a real media_kit `Player()`.
    // `flutter test` has no native mpv/FFI available, so that construction
    // throws, and `_initializePlayer`'s outer `catch` sets `_error` to the
    // raw `e.toString()`, with no prefix.
    //
    // That absence of a prefix is the discriminator: the deleted
    // `_initializeOfflinePlayback` had its own inner `try`/`catch` that
    // wrapped the same failure as `'Failed to play downloaded content: $e'`.
    // Seeing the raw text instead of that prefix proves this run went
    // through `_openPlayerAndStart`, not the old parallel init — verified by
    // running this test against the pre-fix `player_screen.dart` (see the
    // task report's "Fix round 1" section), where it fails on this exact
    // assertion.
    expect(
      find.textContaining('Failed to play downloaded content'),
      findsNothing,
    );
    expect(
      find.textContaining('MediaKit.ensureInitialized'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('offline playback without a download says so', (tester) async {
    final container = buildPlayerScreenContainer(
      link: StubLink((request, callIndex) =>
          throw StateError('offline mode must not issue GraphQL requests')),
      connectionState: conn.ConnectionState.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      authStatus: AuthStatus.offlineMode,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(find.textContaining('not available offline'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
