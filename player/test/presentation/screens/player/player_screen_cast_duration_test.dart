// Regression guard for a cast-duration bug found while reviewing Task 7
// (asking to resume before an HLS session starts), fixed in commit
// dea523a3 ("publish cast duration at the source, not a fallback read").
//
// `PlayerScreen` can short-circuit playback into `CastSessionManager.
// startCast` — via `_castToTargetIfSet`, at the "network streaming branch"
// call site — before any local `Player` or HLS session exists, whenever the
// user picked a cast target before opening a title (`CastButton` on a detail
// screen, not the in-player picker). `_knownCastDuration()` falls back to
// `_timeline.totalDuration` in that no-player case, and a Mydia HLS session
// never reports its own duration (no `EXT-X-ENDLIST` until FFmpeg
// finishes), so if `_timeline` is not populated by that point the receiver
// gets `duration: null` and is stranded with no scrub bar length. The fix
// publishes the resolved duration into `_timeline` immediately after
// `_resolveRealDuration` runs, before the cast short-circuit, rather than
// only after an HLS session's mutation returns.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

void main() {
  testWidgets(
      'hands the receiver the resolved runtime when casting short-circuits '
      'playback before any HLS session exists', (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final link = StubLink.responses([
      movieDetailResponse(files: [mediaFileWithSubtitle()]),
      movieSegmentsResponse(),
      subtitleTrackSettingsResponse(),
      streamingCandidatesResponse(duration: 5400),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    // The target is chosen before playback, exactly like `CastButton` on a
    // detail screen: `castTargetProvider` already carries a device by the
    // time `PlayerScreen` mounts and reads it.
    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => castManager.capturedRequest != null);

    final captured = castManager.capturedRequest;
    expect(captured, isNotNull);
    expect(
      captured!.duration,
      const Duration(seconds: 5400),
      reason: 'The receiver must get the server-known runtime even though '
          'casting short-circuits before any local Player or HLS session '
          'exists.',
    );
    // `_castToTargetIfSet` — the "network streaming branch" call site — is
    // the entry point the corrected premise names as never having sent
    // subtitles at all, because it runs on the plain cast-before-play path
    // with no GraphQL change of its own. `_fetchProgressAndEpisodes` (movie
    // detail + segments, both already answered above) is awaited before this
    // call site is reached, so `_subtitleTracks` is populated by the time
    // `_castSubtitleTracks()` builds the request's `subtitles` list — proving
    // the wiring, not just that `CastLaunchRequest.subtitles` defaults to
    // non-empty.
    expect(
      captured.subtitles,
      hasLength(1),
      reason: '_castToTargetIfSet must carry the file\'s subtitle tracks; '
          'before Step 7 this call site built no `subtitles:` argument at '
          'all, so this list was always empty regardless of what GraphQL '
          'returned.',
    );
    expect(captured.subtitles.single.trackId, '3');
    expect(captured.subtitles.single.language, 'eng');
    expect(
      captured.subtitles.single.url,
      '/api/player/v1/subtitles/file/file-1/3?format=vtt',
      reason: '_castToTargetIfSet hands the route resolver the raw '
          'media-file URL; CastRouteResolver, not this call site, is what '
          'rewrites it to a session path.',
    );
  });

  testWidgets(
      'a subtitle with no url (a just-downloaded sidecar) still reaches the '
      'cast request', (tester) async {
    // `SubtitleTrack.fromDownload` deliberately leaves `url` null -- the
    // body is fetched lazily by trackId, not by URL. `_castSubtitleTracks()`
    // must not use a blanket `url != null` filter to decide what's castable:
    // the HLS/session routes never read this field at all, only the
    // progressive (DLNA) route does, so dropping the track here would wrongly
    // exclude it from a Chromecast too.
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final link = StubLink.responses([
      movieDetailResponse(
        files: [mediaFileWithSubtitle(url: null, deliverable: true)],
      ),
      movieSegmentsResponse(),
      subtitleTrackSettingsResponse(),
      streamingCandidatesResponse(duration: 5400),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => castManager.capturedRequest != null);

    final captured = castManager.capturedRequest;
    expect(captured, isNotNull);
    expect(
      captured!.subtitles,
      hasLength(1),
      reason: 'a deliverable track with no media-file url must still be '
          'offered to the receiver; only the deliverable filter should '
          'exclude tracks.',
    );
    expect(captured.subtitles.single.trackId, '3');
  });

  testWidgets('a media_kit-shaped track id never reaches the cast request',
      (tester) async {
    // Regression test for the bug fixed alongside this test: `_detectTracks`
    // builds synthetic ids like `mk_0` for a direct-play session's embedded
    // tracks (see the comment on `_castSubtitleTracks`). This scenario
    // stands in for that without needing a real media_kit player — the
    // filter in `_castSubtitleTracks` only looks at the id's shape, so a
    // GraphQL-sourced track carrying an `mk_`-shaped id exercises exactly
    // the same code path. `CastRouteResolver._sessionSubtitles` builds
    // `subs_mk_0.vtt` from whatever id it is handed with no validation of
    // its own, and the server's anchored filename regex rejects it, so
    // letting this through would 404 on the receiver.
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final link = StubLink.responses([
      movieDetailResponse(files: [mediaFileWithSubtitle(trackId: 'mk_0')]),
      movieSegmentsResponse(),
      subtitleTrackSettingsResponse(),
      streamingCandidatesResponse(duration: 5400),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => castManager.capturedRequest != null);

    final captured = castManager.capturedRequest;
    expect(captured, isNotNull);
    expect(
      captured!.subtitles,
      isEmpty,
      reason: 'an mk_-prefixed id is not a shape the server can serve; '
          '_castSubtitleTracks must drop it rather than send a track id '
          'that will 404 on the receiver.',
    );
  });

  testWidgets('a sidecar uuid track id reaches the cast request',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    const uuid = '0f8fad5b-d9cb-469f-a165-70867728950e';
    final link = StubLink.responses([
      movieDetailResponse(files: [mediaFileWithSubtitle(trackId: uuid)]),
      movieSegmentsResponse(),
      subtitleTrackSettingsResponse(),
      streamingCandidatesResponse(duration: 5400),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => castManager.capturedRequest != null);

    final captured = castManager.capturedRequest;
    expect(captured, isNotNull);
    expect(
      captured!.subtitles,
      hasLength(1),
      reason: 'a uuid is a shape the server can serve (a sidecar track id), '
          'so it must still reach the cast request.',
    );
    expect(captured.subtitles.single.trackId, uuid);
  });

  testWidgets('a successful cast leaves the chosen device set', (tester) async {
    // Clearing it here would drop the cast icon to white while the cast is
    // running — the reported bug, inverted. Opting out is the bar's ✕ or
    // Stop, both of which disconnect.
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      subtitleTrackSettingsResponse(),
      streamingCandidatesResponse(duration: 5400),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
    );
    addTearDown(container.dispose);

    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => castManager.capturedRequest != null);

    expect(container.read(castTargetProvider), testDevice);
  });
}
