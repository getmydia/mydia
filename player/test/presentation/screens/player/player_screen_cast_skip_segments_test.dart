// Skip Intro / Skip Credits while the media is on a receiver.
//
// The local path drives the button from `Player.stream.position` and seeks
// with `seekToReal`, both of which need a local `Player` that casting never
// builds — `_castToTargetIfSet` returns before one is constructed, on purpose,
// so a chosen device never pays for local streaming infrastructure. That left
// the whole feature silently absent on the one surface where an intro is most
// annoying to sit through, since a remote is further away than a keyboard.
//
// The cast path substitutes the two coordinates it lacks. Position comes from
// `CastSession.mediaInfo`, which `CastSessionManager` already publishes in
// real media coordinates (it maps the receiver's own position through
// `_timeline.toReal` before publishing), and the seek goes to
// `CastSessionManager.seek`, which is specified in those same coordinates and
// internally restarts the session when the target is out of the receiver's
// reach. Both were already there; nothing about segment handling needed to
// move for this.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/video_controls/skip_segment_button.dart';

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

/// A credits segment covering 40:00 to 45:00 of the 90 minute test movie.
const _creditsStartMs = 2400000;
const _creditsEndMs = 2700000;

const _insideCredits = Duration(milliseconds: 2450000);
const _outsideCredits = Duration(minutes: 10);

/// The `MediaSegment` shape the server sends.
///
/// `__typename` matters as much as the three selected fields: the normalized
/// cache refuses a partial write, and a refused write surfaces as
/// `result.hasException`, which `_fetchSegments` treats as "no segments" —
/// indistinguishable from the bug this file is guarding against.
Map<String, dynamic> _creditsSegment() => {
      '__typename': 'MediaSegment',
      'type': 'CREDITS',
      'startMs': _creditsStartMs,
      'endMs': _creditsEndMs,
    };

/// Whether [request] carries the named query. See
/// `player_screen_segments_isolation_test.dart` for why the operation name is
/// read out of the printed document rather than `operationName`.
bool _isQuery(Request request, String name) =>
    request.operation.toString().contains('query $name');

/// Answers per operation rather than by index, so this script does not break
/// the moment the screen reorders its startup queries.
StubLink _link({List<Map<String, dynamic>> segments = const []}) {
  return StubLink((request, index) {
    if (_isQuery(request, 'MovieSegments')) {
      return movieSegmentsResponse(segments: segments);
    }
    if (_isQuery(request, 'MovieDetail')) return movieDetailResponse();
    return streamingCandidatesResponse(duration: 5400);
  });
}

CastSession _sessionAt(
  Duration position, {
  CastConnectionState connectionState = CastConnectionState.connected,
}) =>
    CastSession(
      device: testDevice,
      mediaInfo: CastMediaInfo(
        title: 'Arrival',
        duration: const Duration(seconds: 5400),
        position: position,
      ),
      playbackState: CastPlaybackState.playing,
      connectionState: connectionState,
    );

/// Pumps while republishing the receiver's position until [condition] holds.
///
/// Republishing is what makes this work: `_fetchSegments` assigns `_segments`
/// without a `setState` (the local path relies on its position `StreamBuilder`
/// to rebuild), so on the cast path a session event is the only thing that
/// repaints the placeholder once the segments actually arrive.
Future<void> pumpCastUntil(
  WidgetTester tester,
  StreamController<CastSession?> session,
  Duration position,
  bool Function() condition, {
  CastConnectionState connectionState = CastConnectionState.connected,
  int maxTries = 100,
}) async {
  for (var i = 0; i < maxTries && !condition(); i++) {
    session.add(_sessionAt(position, connectionState: connectionState));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

bool get _buttonShowing =>
    find.byKey(SkipSegmentButton.buttonKey).evaluate().isNotEmpty;

void main() {
  late StreamController<CastSession?> session;

  setUp(() => session = StreamController<CastSession?>.broadcast());
  tearDown(() => session.close());

  testWidgets('offers a skip on the cast placeholder and seeks the receiver',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final container = buildPlayerScreenContainer(
      link: _link(segments: [_creditsSegment()]),
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
      castSessionStream: session.stream,
    );
    addTearDown(container.dispose);

    // Chosen before playback, exactly like `CastButton` on a detail screen, so
    // `_castToTargetIfSet` short-circuits and no local `Player` is ever built.
    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpCastUntil(tester, session, _insideCredits, () => _buttonShowing);

    expect(
      find.text('Skip Credits'),
      findsOneWidget,
      reason: 'The receiver is sitting inside a detected credits segment, so '
          'the placeholder has to offer the same affordance local playback '
          'would.',
    );

    await tester.tap(find.text('Skip Credits'));
    await tester.pump();

    expect(
      castManager.seekTargets,
      [const Duration(milliseconds: _creditsEndMs)],
      reason: 'A skip while casting must move the receiver to the end of the '
          'segment, in real media coordinates — the space '
          'CastSessionManager.seek is specified in.',
    );
  });

  testWidgets('withdraws the skip once the receiver leaves the segment',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final container = buildPlayerScreenContainer(
      link: _link(segments: [_creditsSegment()]),
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
      castSessionStream: session.stream,
    );
    addTearDown(container.dispose);

    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpCastUntil(tester, session, _insideCredits, () => _buttonShowing);

    // Proves the absence below is position-driven rather than a screen that
    // simply never renders the button.
    expect(_buttonShowing, isTrue);

    session.add(_sessionAt(_outsideCredits));
    await tester.pump();

    expect(find.byKey(SkipSegmentButton.buttonKey), findsNothing);
  });

  testWidgets('offers no skip over a receiver that has dropped off',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final container = buildPlayerScreenContainer(
      link: _link(segments: [_creditsSegment()]),
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
      castSessionStream: session.stream,
    );
    addTearDown(container.dispose);

    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);

    // A stale session keeps its `mediaInfo`, so position alone would still put
    // the receiver inside the credits. The placeholder already refuses to
    // claim "connected" here; a skip button that silently does nothing would
    // be the same false claim in another form.
    await pumpCastUntil(
      tester,
      session,
      _insideCredits,
      () => castManager.capturedRequest != null,
      connectionState: CastConnectionState.lost,
    );

    expect(find.byKey(SkipSegmentButton.buttonKey), findsNothing);
  });

  testWidgets('auto-skips the receiver exactly once when the setting is on',
      (tester) async {
    final castManager = CapturingCastSessionManager();
    final proxyService = TrackingLocalProxyService();

    final container = buildPlayerScreenContainer(
      link: _link(segments: [_creditsSegment()]),
      connectionState: conn.ConnectionState.direct(),
      castManager: castManager,
      proxyService: proxyService,
      castSessionStream: session.stream,
      settingsService: FakeSettingsService(autoSkipSegments: true),
    );
    addTearDown(container.dispose);

    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpCastUntil(
      tester,
      session,
      _insideCredits,
      () => castManager.seekTargets.isNotEmpty,
    );

    expect(
      castManager.seekTargets,
      [const Duration(milliseconds: _creditsEndMs)],
      reason: 'Auto-skip has to reach the receiver without the viewer '
          'touching anything.',
    );

    // The receiver keeps reporting positions inside the segment until its seek
    // lands, and a viewer may deliberately seek back in afterwards. Neither
    // may produce a second automatic skip.
    for (var i = 0; i < 5; i++) {
      session.add(_sessionAt(_insideCredits));
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(
      castManager.seekTargets,
      hasLength(1),
      reason: 'SegmentSkipTracker spends a segment on first use, so later '
          'positions inside it must not re-fire.',
    );
  });
}
