// Coverage for the quality control's server-facing half: which caps reach
// `startStreamingSession`, and what happens against a server whose schema
// predates them.
//
// These assert on `StubLink.requests` rather than on the chrome. The rung a
// viewer picks only matters if it reaches the mutation, and the request is
// where that is decidable — the control's own visibility is a function of
// `_qualityLadder.length`, which `quality_rung_test.dart` already pins.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

void main() {
  /// Collects `debugPrint` output for the duration of [body], restoring it
  /// inside the body's own scope rather than via `tearDown` — see
  /// `player_screen_resume_offset_test.dart` for why that timing matters.
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

  /// Every `startStreamingSession` request the screen made, old document or
  /// legacy one. `strategy` is the variable only these two carry.
  List<Request> sessionRequests(StubLink link) => link.requests
      .where((r) => r.variables.containsKey('strategy'))
      .toList(growable: false);

  /// True when [request] carries the named GraphQL operation. Lets a stub
  /// answer by document rather than by call index, which is what a test with
  /// more than one `_initializePlayer` pass needs.
  ///
  /// Reads the document off `Operation.toString()`, which prints the query
  /// source. `DocumentNode.toString()` does not — it is the default
  /// `Instance of 'DocumentNode'`, so matching on it silently matches
  /// nothing and every request falls through to the stub's default.
  bool isOperation(Request request, String name) =>
      request.operation.toString().contains(name);

  Future<void> pumpUntilSessionStarted(WidgetTester tester, StubLink link,
      {int count = 1}) async {
    await pumpUntil(tester, () => sessionRequests(link).length >= count);
    // Drains `_waitForPlaylist`'s retry loop so no timer outlives the test;
    // see `player_screen_resume_offset_test.dart` for the full explanation.
    await tester.pumpAndSettle();
  }

  testWidgets('sends the stored rung as a bitrate and height cap',
      (tester) async {
    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      subtitleTrackSettingsResponse(),
      streamingCandidatesResponse(duration: 5400, height: 2160),
      startStreamingSessionResponse(maxBitrate: 4000, maxHeight: 720),
      endStreamingSessionResponse(),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      settingsService: FakeSettingsService(defaultQuality: '720p'),
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntilSessionStarted(tester, link);

    final variables = sessionRequests(link).single.variables;
    expect(variables['maxBitrate'], 4000);
    expect(variables['maxHeight'], 720,
        reason: 'the rung is a pair; sending the bitrate alone leaves the '
            'server free to spend it on a resolution nobody asked for');
  });

  testWidgets(
      'falls back to Original when the source cannot offer the '
      'stored rung', (tester) async {
    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      subtitleTrackSettingsResponse(),
      // A 720p source: the 1080p rung would upscale, so it is not on this
      // file's ladder at all.
      streamingCandidatesResponse(duration: 5400, height: 720),
      startStreamingSessionResponse(),
      endStreamingSessionResponse(),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      settingsService: FakeSettingsService(defaultQuality: '1080p'),
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntilSessionStarted(tester, link);

    final variables = sessionRequests(link).single.variables;
    expect(variables.containsKey('maxBitrate'), isFalse);
    expect(variables.containsKey('maxHeight'), isFalse,
        reason: 'Original asks for no caps, which is what keeps the '
            'copy-when-compatible path available');
  });

  testWidgets('a chosen rung takes precedence over direct play',
      (tester) async {
    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      subtitleTrackSettingsResponse(),
      // Direct play is on offer and would normally win on native, handing the
      // file over untouched — with no encoder to apply the cap to.
      streamingCandidatesResponse(
          duration: 5400, height: 2160, directPlay: true),
      startStreamingSessionResponse(maxBitrate: 1500, maxHeight: 480),
      endStreamingSessionResponse(),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      settingsService: FakeSettingsService(defaultQuality: '480p'),
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntilSessionStarted(tester, link);

    expect(sessionRequests(link).single.variables['maxHeight'], 480,
        reason: 'a streaming session must be negotiated at all: taking the '
            'direct-play shortcut would silently ignore the rung');
  });

  testWidgets(
      'retries through the legacy document when the server does not '
      'know maxHeight', (tester) async {
    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      subtitleTrackSettingsResponse(),
      streamingCandidatesResponse(duration: 5400, height: 2160),
      // Absinthe's verbatim text for an argument the schema does not declare.
      graphqlErrorResponse(
        'Unknown argument "maxHeight" on field "startStreamingSession" of '
        'type "RootMutationType".',
      ),
      // The retry must survive a reply with no echoed caps at all, which is
      // the only kind an old server can send.
      legacyStartStreamingSessionResponse(),
      endStreamingSessionResponse(),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      settingsService: FakeSettingsService(defaultQuality: '720p'),
    );
    addTearDown(container.dispose);

    final logged = <String>[];
    await withCapturedDebugPrint(logged, () async {
      await pumpPlayerScreen(tester, container);
      await pumpUntilSessionStarted(tester, link, count: 2);
    });

    final attempts = sessionRequests(link);
    expect(attempts.length, 2, reason: 'exactly one retry, not a loop');
    expect(attempts.first.variables['maxHeight'], 720);
    expect(attempts.last.variables.containsKey('maxHeight'), isFalse);
    expect(attempts.last.variables['maxBitrate'], 4000,
        reason: 'the bitrate cap predates the height cap, so it survives the '
            'fallback — the rung still means something on an old server');
    expect(
      logged.any((l) => l.contains('HLS session started: sess-1')),
      isTrue,
      reason: 'the reply with no echoed caps must parse into a real session; '
          'without this the test proves only that a retry was sent, not that '
          'an old server response is usable',
    );
  });

  testWidgets(
      'reads the stored default once and carries the rung across a '
      're-initialization', (tester) async {
    // The rung the viewer is watching at must not round-trip through secure
    // storage to survive a restart. It used to: `_resolveQualityForFile`
    // re-read the stored key on every re-initialization, so a write that
    // failed — deliberately swallowed, and `flutter_secure_storage` needs a
    // keyring on Linux desktop — silently put the session back at the rung
    // they had just replaced.
    //
    // Driven through the error screen's Retry button, which is the only way
    // to reach a second `_initializePlayer` under `flutter_test`: the chrome
    // that owns the quality picker is never built here (see
    // `quality_choice_test.dart` for why).
    //
    // Answered by operation rather than by call index. A second pass does not
    // re-issue every query — the client's default cache-and-network policy
    // serves some of them from the cache — so a positional script silently
    // hands the wrong payload to the wrong document.
    var sessionAttempts = 0;
    final link = StubLink((request, _) {
      if (isOperation(request, 'MovieDetail')) return movieDetailResponse();
      if (isOperation(request, 'MovieSegments')) return movieSegmentsResponse();
      if (isOperation(request, 'SubtitleTrackSettings')) {
        return subtitleTrackSettingsResponse();
      }
      if (isOperation(request, 'StreamingCandidates')) {
        return streamingCandidatesResponse(duration: 5400, height: 2160);
      }
      if (isOperation(request, 'StartStreamingSession')) {
        sessionAttempts++;
        return sessionAttempts == 1
            ? graphqlErrorResponse('Failed to start streaming session')
            : startStreamingSessionResponse(maxBitrate: 4000, maxHeight: 720);
      }
      return endStreamingSessionResponse();
    });

    final settings = FakeSettingsService(defaultQuality: '720p');

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      settingsService: settings,
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => find.text('Retry').evaluate().isNotEmpty);

    // Storage now disagrees with what is in effect — exactly the state a
    // failed or stale write leaves behind.
    settings.defaultQuality = '360p';

    await tester.tap(find.text('Retry'));
    await pumpUntilSessionStarted(tester, link, count: 2);

    final attempts = sessionRequests(link);
    expect(attempts, hasLength(2),
        reason: 'without a second pass this test proves nothing; the whole '
            'point is what the re-initialization requests');
    expect(settings.getDefaultQualityCalls, 1,
        reason: 'storage seeds the rung, it does not carry it');
    expect(attempts.last.variables['maxHeight'], 720,
        reason: 'the rung in effect wins over whatever storage now holds');
  });

  testWidgets('an unreadable preference plays at Original rather than failing',
      (tester) async {
    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      subtitleTrackSettingsResponse(),
      streamingCandidatesResponse(duration: 5400, height: 2160),
      startStreamingSessionResponse(),
      endStreamingSessionResponse(),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      settingsService: FakeSettingsService(
        defaultQuality: '720p',
        readError: StateError('secure storage is unavailable'),
      ),
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntilSessionStarted(tester, link);

    final variables = sessionRequests(link).single.variables;
    expect(variables.containsKey('maxHeight'), isFalse,
        reason: 'a locked keyring costs the preference, not the playback, and '
            'the safe answer is the cheapest one for the server');
  });

  testWidgets('does not retry a genuine failure', (tester) async {
    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      subtitleTrackSettingsResponse(),
      streamingCandidatesResponse(duration: 5400, height: 2160),
      graphqlErrorResponse('Failed to start streaming session'),
      endStreamingSessionResponse(),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      settingsService: FakeSettingsService(defaultQuality: '720p'),
    );
    addTearDown(container.dispose);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(
      tester,
      () => find
          .textContaining('Failed to start streaming session')
          .evaluate()
          .isNotEmpty,
    );

    expect(sessionRequests(link).length, 1,
        reason: 'a resolver failure is not version skew; retrying it would '
            'double every real error');
  });
}
