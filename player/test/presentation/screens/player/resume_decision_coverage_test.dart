// This bug has now been introduced three times: the resume decision lives
// inside one branch, another branch is added or changed, and that branch
// silently starts at zero. This test asserts every source reaches the
// decision, so a seventh path cannot repeat it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/core/playback/playback_progress_store.dart';

import '../../../test_utils/scripted_mydia_transport.dart';
import 'player_screen_test_harness.dart';

void main() {
  setUp(mockPathProviderDocumentsDirectory);

  // The pre-play queries now fire concurrently (see `runIsolated`), so an
  // ordered `ScriptedMydiaTransport.responses` list can no longer script them
  // -- dispatch on the operation instead.
  ScriptedMydiaTransport serverFor(Object candidates) {
    return ScriptedMydiaTransport((request, index) {
      if (request.operation == 'MovieDetail') {
        return movieDetailResponse(positionSeconds: 2700);
      }
      if (request.operation == 'MovieSegments') return movieSegmentsResponse();
      if (request.operation == 'SubtitleTrackSettings') {
        return subtitleTrackSettingsResponse();
      }
      if (request.operation == 'MovieSubtitlePreference') {
        return subtitlePreferenceResponse();
      }
      return candidates;
    });
  }

  // Each case sets up one source and asserts the resume dialog appears with a
  // position that comfortably clears every bound in `shouldOfferResume`. Each
  // case is responsible for pumping the screen and waiting for its own
  // outcome — the offline case has to poll real `dart:io` inside
  // `tester.runAsync`, so a single generic wait after the fact would not
  // work for every case uniformly.
  //
  // The "downloaded, online" source is deliberately absent here: reaching it
  // genuinely needs the same real-temp-file/runAsync machinery
  // `offline_resume_test.dart` already exercises for it end to end, and
  // duplicating that setup here would not add coverage.
  final cases = <String, Future<void> Function(WidgetTester)>{
    'streaming, HLS': (tester) async {
      final container = buildPlayerScreenContainer(
        server: serverFor(streamingCandidatesResponse(duration: 5400)),
        connectionState: conn.ConnectionState.direct(),
        castManager: CapturingCastSessionManager(),
        proxyService: TrackingLocalProxyService(),
      );
      addTearDown(container.dispose);
      await pumpPlayerScreen(tester, container);
      await pumpUntil(tester, () => find.text('Resume').evaluate().isNotEmpty);
    },
    'streaming, direct play': (tester) async {
      final container = buildPlayerScreenContainer(
        server: serverFor(
            streamingCandidatesResponse(duration: 5400, directPlay: true)),
        connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
        castManager: CapturingCastSessionManager(),
        proxyService: TrackingLocalProxyService(),
      );
      addTearDown(container.dispose);
      await pumpPlayerScreen(tester, container);
      await pumpUntil(tester, () => find.text('Resume').evaluate().isNotEmpty);
    },
    'cast target chosen before playback': (tester) async {
      final container = buildPlayerScreenContainer(
        server: serverFor(streamingCandidatesResponse(duration: 5400)),
        connectionState: conn.ConnectionState.direct(),
        castManager: CapturingCastSessionManager(),
        proxyService: TrackingLocalProxyService(),
      );
      addTearDown(container.dispose);
      container.read(castTargetProvider.notifier).set(testDevice);
      await pumpPlayerScreen(tester, container);
      await pumpUntil(tester, () => find.text('Resume').evaluate().isNotEmpty);
    },
    'downloaded, offline': (tester) async {
      // The bound instance reports `unreachable`, which is what the player
      // reads as offline.
      final tempDir =
          Directory.systemTemp.createTempSync('mydia_resume_coverage_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final tempFile = File('${tempDir.path}/arrival.mkv')
        ..writeAsBytesSync(const [0]);

      final store = InMemoryPlaybackProgressStore();
      final container = buildPlayerScreenContainer(
        // Offline mode issues no GraphQL at all.
        server: ScriptedMydiaTransport((request, callIndex) =>
            throw StateError('offline mode must not issue GraphQL requests')),
        connectionState: conn.ConnectionState.direct(),
        castManager: CapturingCastSessionManager(),
        proxyService: TrackingLocalProxyService(),
        downloaded: downloadedItem(filePath: tempFile.path, runtimeMinutes: 90),
        offline: true,
        progressStore: store,
      );
      addTearDown(container.dispose);
      await seedLocalProgress(container, positionSeconds: 2700);

      // Real file, real `dart:io` I/O via `_resolveDownloadedFilePath`: has
      // to run inside `runAsync` and poll for the real outcome, same as
      // `offline_resume_test.dart`.
      await tester.runAsync(() async {
        await pumpPlayerScreen(tester, container);
        await pumpUntilReal(
          tester,
          () => find.text('Resume').evaluate().isNotEmpty,
        );
      });
    },
  };

  cases.forEach((name, setUpCase) {
    testWidgets('$name asks about resuming', (tester) async {
      await setUpCase(tester);

      expect(find.text('Resume'), findsOneWidget,
          reason: '$name must reach the single resume decision');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });
}
