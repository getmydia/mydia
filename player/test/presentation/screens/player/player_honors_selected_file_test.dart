// Regression coverage for the quality selector being ignored on desktop.
//
// `PlayerScreen` receives the file the user picked as `widget.fileId`, but the
// direct-play branch used to stream `candidatesResult.fileId` instead — the
// server's answer to a question keyed on the *media item*, not the file. With
// a 1080p and a 4K file on one movie, picking 1080p still played the 4K.
//
// Both tests script the server to name a file that is deliberately NOT the one
// the screen was mounted with. Reintroducing either half of the bug — keying
// the candidates query on `widget.mediaId`, or shadowing `widget.fileId` with
// `candidatesResult.fileId` — fails them.
//
// P2P connection state so the direct-play URL comes from the stub proxy rather
// than the real media-token service.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

void main() {
  testWidgets('direct play streams the file the user selected', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // `streamingCandidatesResponse` hardcodes fileId 'file-1'. Mounting with
    // 'file-2' makes the two disagree, which is exactly the production case:
    // the user picked one file, the server named another.
    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      streamingCandidatesResponse(duration: 5400, directPlay: true),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container, fileId: 'file-2');
    await pumpUntil(
      tester,
      () => proxyService.capturedDirectStreamFileId != null,
    );

    expect(
      proxyService.capturedDirectStreamFileId,
      'file-2',
      reason: 'the direct-play branch must stream widget.fileId, not whatever '
          'the candidates response named',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('the candidates query asks about the file, not the media item',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      streamingCandidatesResponse(duration: 5400, directPlay: true),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container, fileId: 'file-2');
    await pumpUntil(tester, () => link.requests.length >= 3);

    // Third scripted call, matching the response order above. `StubLink` is
    // index-based, so this ordering is the same one every other PlayerScreen
    // test relies on.
    final candidatesVariables = link.requests[2].variables;

    expect(
      candidatesVariables['contentType'],
      'file',
      reason: 'asking by movie id forces the server to guess which file',
    );
    expect(candidatesVariables['id'], 'file-2');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
