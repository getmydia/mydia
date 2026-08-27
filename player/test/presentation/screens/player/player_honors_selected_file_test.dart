// Regression coverage for the quality selector being ignored on desktop.
//
// `PlayerScreen` receives the file the user picked as `widget.fileId`, but the
// direct-play branch used to stream `candidatesResult.fileId` instead — the
// server's answer to a question keyed on the *media item*, not the file. With
// a 1080p and a 4K file on one movie, picking 1080p still played the 4K.
//
// The first two tests script the server to name a file that is deliberately
// NOT the one the screen was mounted with. Reintroducing either half of the
// bug — keying the candidates query on `widget.mediaId`, or shadowing
// `widget.fileId` with `candidatesResult.fileId` — fails them.
//
// The third proves the fix's edge: `player_screen_stale_candidates_test.dart`
// covers the case where the server *rejects* the selected file (deleted by a
// quality upgrade) and the screen falls back to whatever the server ranks for
// the media item instead. That fallback must not fire on a transport failure
// — a socket error or an unreachable server says nothing about whether the
// selected file still exists, and firing anyway would silently swap the
// user's choice for the server's pick over a network blip.
//
// P2P connection state so the direct-play URL comes from the stub proxy rather
// than the real media-token service.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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
      subtitleTrackSettingsResponse(),
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
      () => proxyService.directStreamFileIds.isNotEmpty,
    );

    expect(
      proxyService.directStreamFileIds,
      ['file-2'],
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
      subtitleTrackSettingsResponse(),
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
    await pumpUntil(tester, () => link.requests.length >= 4);

    // Fourth scripted call, matching the response order above: detail,
    // segments, subtitle offsets, candidates. `StubLink` is index-based, so
    // this ordering is the same one every other PlayerScreen test relies on.
    final candidatesVariables = link.requests[3].variables;

    expect(
      candidatesVariables['contentType'],
      'file',
      reason: 'asking by movie id forces the server to guess which file',
    );
    expect(candidatesVariables['id'], 'file-2');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
      'a transport failure fetching candidates still honors the selected '
      'file, with no server-ranked fallback', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    // The candidates call for the selected file never reaches the server at
    // all. `http.ClientException` is not special here — `package:graphql`'s
    // `translateFailure` wraps *any* unrecognized thrown object in an
    // `UnknownException`, so any exception thrown from the link would give a
    // non-null `linkException` just the same. It is simply a realistic
    // stand-in for a real socket error or unreachable server, the shape a
    // transport failure takes, as opposed to the server answering with a
    // GraphQL error (see `player_screen_stale_candidates_test.dart`, the
    // case this one exists to be told apart from).
    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      subtitleTrackSettingsResponse(),
      http.ClientException('Connection refused'),
      startStreamingSessionResponse(duration: 5400),
      endStreamingSessionResponse(),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container, fileId: 'file-2');
    // With no candidates response, `_canDirectPlay` has nothing to say yes
    // to, so this falls to the HLS path instead of direct play — a real,
    // if incidental, degradation from the network blip. What must not
    // degrade is *which file* streams, so wait on the session-start
    // mutation rather than on `directStreamFileIds`, which this path never
    // populates.
    await pumpUntil(
      tester,
      () => link.requests.any((r) => r.variables.containsKey('strategy')),
    );

    final sessionRequest =
        link.requests.firstWhere((r) => r.variables.containsKey('strategy'));
    expect(
      sessionRequest.variables['fileId'],
      'file-2',
      reason: 'a transport failure must not trigger the deleted-file '
          'fallback — that would silently swap the file the user picked for '
          'whatever the server ranks for the whole media item',
    );

    expect(
      link.requests.where((r) => r.variables.containsKey('contentType')).length,
      1,
      reason: 'the fallback must only re-ask the server when it has '
          'actually answered and rejected the id, never on a transport '
          'failure',
    );

    // Drains `_waitForPlaylist`'s background retry loop (real HTTP calls,
    // but `flutter_test`'s `HttpOverrides` makes every one an instant 400,
    // and `FakeAsync` governs the retry backoff timers) so no pending timer
    // survives into the framework's own end-of-test check — see
    // `player_screen_resume_offset_test.dart` for the full explanation.
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
