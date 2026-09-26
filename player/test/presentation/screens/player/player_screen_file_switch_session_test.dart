// A file switch on a reused PlayerScreen State ends the old file's HLS
// session on the server and keeps everything scoped to the screen: the
// window sizer is attached once and never detached, and the media proxy
// hold is not released. Companion to `player_screen_file_change_test.dart`,
// which covers the direct-play path.

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/core/window/player_window_sizer.dart';
import 'package:player/graphql/mutations/end_streaming_session.graphql.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

class _RecordingSizer implements PlayerWindowSizer {
  int attaches = 0;
  int detaches = 0;

  @override
  Future<void> attach() async => attaches++;

  @override
  void bindVideoParams(Stream<VideoParams> params) {}

  @override
  Future<void> detach() async => detaches++;
}

/// Waits for whatever a file switch on a reused State is doing, the way
/// `player_screen_file_change_test.dart`'s `_pumpUntilSwitched` does.
///
/// A switch re-runs the same real asynchronous I/O the first load does (see
/// `player_screen_test_harness.dart`'s `pumpUntilReal` doc comment), so a
/// plain fake-clock `pumpUntil` can leave [condition] stuck forever even
/// though the switch itself is not stuck at all.
Future<void> _pumpUntilSwitched(
  WidgetTester tester,
  bool Function() condition,
) =>
    tester.runAsync(() => pumpUntilReal(tester, condition));

void main() {
  testWidgets('a file switch ends the old session and keeps the screen',
      (tester) async {
    var sessions = 0;
    final link = StubLink((request, index) {
      if (isOperation(request, 'MovieDetail')) return movieDetailResponse();
      if (isOperation(request, 'MovieSegments')) return movieSegmentsResponse();
      if (isOperation(request, 'SubtitleTrackSettings')) {
        return subtitleTrackSettingsResponse();
      }
      if (isOperation(request, 'MovieSubtitlePreference')) {
        return subtitlePreferenceResponse();
      }
      if (request.variables.containsKey('strategy')) {
        sessions++;
        return startStreamingSessionResponse(sessionId: 'sess-$sessions');
      }
      if (request.variables.containsKey('sessionId')) {
        return endStreamingSessionResponse();
      }
      // No direct-play candidate, so every load takes the HLS/transcode
      // branch and requests its own session. `fileId` is echoed from the
      // request rather than hard-coded so file-a and file-b's candidates
      // are never mistaken for the same cached answer.
      final id = request.variables['id'] as String? ?? 'file-1';
      return streamingCandidatesResponse(
        duration: 5400,
        directPlay: false,
        fileId: id,
      );
    });
    final proxyService = TrackingLocalProxyService();
    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
      castManager: CapturingCastSessionManager(),
      proxyService: proxyService,
    );
    addTearDown(container.dispose);
    final sizer = _RecordingSizer();

    Iterable<Object?> endedIds() => link.requests
        .where((r) =>
            r.operation.document == documentNodeMutationEndStreamingSession)
        .map((r) => r.variables['sessionId']);

    await mockHttpResponse(
      () async {
        await pumpPlayerScreen(tester, container,
            fileId: 'file-a', createWindowSizer: () => sizer);
        await pumpUntil(tester, () => sessions == 1);
        await tester.pump(const Duration(seconds: 1));

        await pumpPlayerScreen(tester, container,
            fileId: 'file-b', createWindowSizer: () => sizer);
        await _pumpUntilSwitched(tester, () => sessions == 2);
        await tester.pump(const Duration(seconds: 1));

        expect(endedIds(), contains('sess-1'),
            reason: 'the old file\'s session must be ended on the server');
        expect(endedIds(), isNot(contains('sess-2')),
            reason: 'the new file\'s session must still be live');
        expect(sizer.attaches, 1);
        expect(sizer.detaches, 0,
            reason: 'a file switch must not hand the window back');
        expect(proxyService.stopped, isFalse,
            reason: 'the switch must not release the proxy hold');
      },
      responseBody: 'a.ts\nb.ts\nc.ts\n'.codeUnits,
    );
  });
}
