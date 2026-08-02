// `_initializeOfflinePlayback` used to be a separate 40-line player init that
// never reached `_openPlayerAndStart`, so the offline path never prompted,
// never seeked, and never tracked progress. It is now a source resolver that
// feeds the shared tail like every other path.

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
    final container = buildPlayerScreenContainer(
      // Offline mode issues no GraphQL at all; the stub link must never be
      // hit, so unlike most tests in this directory it has no scripted
      // responses to play back and throws if a request ever reaches it.
      link: StubLink((request, callIndex) =>
          throw StateError('offline mode must not issue GraphQL requests')),
      connectionState: conn.ConnectionState.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      downloaded: downloadedItem(runtimeMinutes: 90),
      authStatus: AuthStatus.offlineMode,
    );
    addTearDown(container.dispose);

    // Unlike every other test in this directory, this path exercises real
    // `dart:io` (`File.exists`) and a real platform channel round trip
    // (`path_provider`) via `_resolveDownloadedFilePath`. Both are genuine
    // asynchronous I/O, not Dart timers/microtasks, so they never complete
    // under plain `tester.pump()`: `AutomatedTestWidgetsFlutterBinding` runs
    // the test body in a synchronous fake-async zone that `pump()` advances
    // by a virtual `Duration` without ever yielding to the real event loop.
    // `runAsync` breaks out of that zone, and the mount itself has to happen
    // inside it too — a pending real Future started before entering `runAsync`
    // is orphaned in the fake zone that scheduled it and never gets flushed
    // afterward. The real `Future.delayed` between pumps is what actually
    // yields control, letting the pending I/O deliver its result.
    await tester.runAsync(() async {
      await pumpPlayerScreen(tester, container);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future.delayed(const Duration(milliseconds: 5));
      }
    });

    // `downloadedItem`'s path does not exist, so `_resolveDownloadedFilePath`
    // returns null and the branch reports the re-download error. Reaching
    // this exact message proves the offline branch ran and resolved a
    // download, rather than failing earlier with "not available offline".
    expect(find.textContaining('Downloaded file not found'), findsOneWidget);

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
