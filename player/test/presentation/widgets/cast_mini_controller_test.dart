import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_route_resolver.dart';
import 'package:player/core/cast/cast_seek.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/cast/cast_session_store.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/player/progress_service.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/presentation/widgets/cast_mini_controller.dart';

import '../../test_utils/fake_cast_backend.dart';
import '../../test_utils/fake_streaming_session_service.dart';
import '../../test_utils/stub_graphql_client.dart';

class _FakeAuthNotifier extends AuthStateNotifier {
  _FakeAuthNotifier(this._initial);
  final AsyncValue<AuthStatus> _initial;
  @override
  AsyncValue<AuthStatus> build() => _initial;
}

const _device = CastDevice(
  id: 'd1',
  name: 'Cottage Chromecast',
  protocol: CastProtocolKind.chromecast,
);

CastSession _session({
  required Duration duration,
  Duration position = const Duration(seconds: 29),
  bool isStale = false,
}) {
  return CastSession(
    device: _device,
    playbackState: CastPlaybackState.playing,
    isStale: isStale,
    mediaInfo: CastMediaInfo(
      title: 'Silo - S02E01',
      duration: duration,
      position: position,
    ),
  );
}

/// Returns the container so a test can set a cast target after pumping.
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  CastSession? session,
}) async {
  final container = ProviderContainer(overrides: [
    castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
    authStateProvider.overrideWith(() =>
        _FakeAuthNotifier(const AsyncValue.data(AuthStatus.authenticated))),
    asyncGraphqlClientProvider
        .overrideWith((ref) => Completer<GraphQLClient>().future),
    castSessionProvider.overrideWith((ref) => Stream.value(session)),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: Scaffold(body: CastMiniController())),
  ));
  await tester.pump();
  return container;
}

/// A real [CastSessionManager] wired to a [FakeCastBackend], so seeks the
/// widget issues can be observed on `backend.seeks` without a network.
///
/// `seek` on the manager just forwards to `backend.seek` (see
/// `CastSessionManager.seek`), so nothing here needs a live `startCast` —
/// the manager's other dependencies (store, GraphQL client, route resolver)
/// only matter for casting/reconnecting, which this test never exercises.
class _ManagerHarness {
  _ManagerHarness(this.manager, this.backend);

  final CastSessionManager manager;
  final FakeCastBackend backend;
}

_ManagerHarness _buildManagerHarness() {
  final backend = FakeCastBackend();
  final sessions = FakeStreamingSessionService();
  final client = stubClient(
    StubLink((request, callIndex) => const {'__typename': 'Query'}),
  );

  final manager = CastSessionManager(
    backend: backend,
    store: InMemoryCastSessionStore(),
    progressService: ProgressService(client),
    resolverFactory: () => CastRouteResolver(
      isP2pMode: false,
      serverUrl: 'https://mydia.test',
      mediaToken: () async => null,
      lanBaseUrl: () => null,
      streamingSessions: sessions,
    ),
    streamingSessions: sessions,
    setLanAccess: (enabled) async {},
  );

  return _ManagerHarness(manager, backend);
}

/// Like [_pump], but backs `castSessionManagerProvider` with a real manager
/// over a [FakeCastBackend] and lets the caller push more than one session
/// onto `castSessionProvider` (a plain `Stream.value` can only ever emit
/// one), which the mid-drag-update assertion needs.
Future<ProviderContainer> _pumpWithManager(
  WidgetTester tester, {
  required _ManagerHarness harness,
  required Stream<CastSession?> sessionStream,
}) async {
  final container = ProviderContainer(overrides: [
    castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
    authStateProvider.overrideWith(() =>
        _FakeAuthNotifier(const AsyncValue.data(AuthStatus.authenticated))),
    asyncGraphqlClientProvider
        .overrideWith((ref) => Completer<GraphQLClient>().future),
    castSessionManagerProvider.overrideWith((ref) async {
      ref.onDispose(harness.manager.dispose);
      return harness.manager;
    }),
    castSessionProvider.overrideWith((ref) => sessionStream),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: Scaffold(body: CastMiniController())),
  ));
  await tester.pump();
  return container;
}

/// Pumps [CastBarLayer] the way `app.dart` does: over a route, with no
/// Navigator or Overlay of its own above the bar.
Future<bool Function()> _pumpLayer(
  WidgetTester tester, {
  required CastDevice target,
}) async {
  var tappedBelow = false;

  final container = ProviderContainer(overrides: [
    castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
    authStateProvider.overrideWith(() =>
        _FakeAuthNotifier(const AsyncValue.data(AuthStatus.authenticated))),
    asyncGraphqlClientProvider
        .overrideWith((ref) => Completer<GraphQLClient>().future),
    castSessionProvider.overrideWith((ref) => Stream.value(null)),
  ]);
  addTearDown(container.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: CastBarLayer(
        child: Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('below-the-bar'),
              onPressed: () => tappedBelow = true,
              child: const Text('Underneath'),
            ),
          ),
        ),
      ),
    ),
  ));
  container.read(castTargetProvider.notifier).set(target);
  await tester.pump();

  return () => tappedBelow;
}

void main() {
  group('CastBarLayer', () {
    testWidgets('gives the bar an Overlay, so its tooltips render',
        (tester) async {
      await _pumpLayer(tester, target: _device);

      final clear = find.byKey(const Key('cast-bar-idle-clear'));
      expect(clear, findsOneWidget);

      await tester.longPress(clear);
      await tester.pump(const Duration(seconds: 1));

      expect(tester.takeException(), isNull);
      expect(find.text('Cancel casting to Cottage Chromecast'), findsOneWidget,
          reason: 'without an Overlay in the layer the tooltip asserts and '
              'renders as an error box instead');
    });

    testWidgets('keeps the bar full-width against the bottom edge',
        (tester) async {
      await _pumpLayer(tester, target: _device);

      final bar = tester.getRect(find.byType(CastMiniController));
      final layer = tester.getRect(find.byType(CastBarLayer));

      expect(bar.width, layer.width);
      expect(bar.bottom, layer.bottom);
    });

    testWidgets('does not swallow taps meant for the screen below',
        (tester) async {
      final tappedBelow = await _pumpLayer(tester, target: _device);

      await tester.tap(find.byKey(const Key('below-the-bar')));
      await tester.pump();

      expect(tappedBelow(), isTrue,
          reason: 'the bar is a full-screen layer; only the bar itself may '
              'take pointer events');
    });
  });

  testWidgets('shows title and device while casting', (tester) async {
    await _pump(tester,
        session: _session(duration: const Duration(minutes: 44)));

    expect(find.text('Silo - S02E01'), findsOneWidget);
    expect(find.textContaining('Cottage Chromecast'), findsOneWidget);
  });

  testWidgets(
      'renders --:-- and disables the scrubber when duration is unknown',
      (tester) async {
    await _pump(tester, session: _session(duration: Duration.zero));

    expect(
      find.byKey(const Key('cast-bar-duration')),
      findsOneWidget,
    );
    expect(
      (tester.widget<Text>(find.byKey(const Key('cast-bar-duration')))).data,
      '--:--',
    );

    final slider =
        tester.widget<Slider>(find.byKey(const Key('cast-bar-scrubber')));
    expect(slider.onChanged, isNull,
        reason: 'an unknown duration must make the scrubber inert rather than '
            'seeking to fraction * -1s');
  });

  testWidgets('renders the stale state with reconnect and stop',
      (tester) async {
    await _pump(
      tester,
      session: _session(duration: const Duration(minutes: 44), isStale: true),
    );

    expect(find.byKey(const Key('cast-stale-reconnect')), findsOneWidget);
    expect(find.byKey(const Key('cast-stale-stop')), findsOneWidget);
    expect(find.byKey(const Key('cast-bar-scrubber')), findsNothing);
  });

  testWidgets('renders nothing when there is no session and no target',
      (tester) async {
    await _pump(tester);

    expect(find.byKey(const Key('cast-bar-scrubber')), findsNothing);
    expect(find.textContaining('Cottage Chromecast'), findsNothing);
  });

  testWidgets('renders the idle state for a target with no session',
      (tester) async {
    final container = await _pump(tester);

    container.read(castTargetProvider.notifier).set(_device);
    await tester.pump();

    expect(find.textContaining('Will play on'), findsOneWidget);
    expect(find.textContaining('Cottage Chromecast'), findsOneWidget);
    expect(find.byKey(const Key('cast-bar-scrubber')), findsNothing);
  });

  testWidgets('the idle clear button drops the target', (tester) async {
    final container = await _pump(tester);

    container.read(castTargetProvider.notifier).set(_device);
    await tester.pump();

    await tester.tap(find.byKey(const Key('cast-bar-idle-clear')));
    await tester.pump();

    expect(container.read(castTargetProvider), isNull);
    expect(find.textContaining('Will play on'), findsNothing);
  });

  testWidgets(
      'seeks once on release, not during the drag, and the thumb holds the '
      'dragged position against a stale mid-drag update', (tester) async {
    final harness = _buildManagerHarness();
    addTearDown(harness.manager.dispose);

    final sessionController = StreamController<CastSession?>();
    addTearDown(sessionController.close);

    final initialSession = _session(
      duration: const Duration(minutes: 44),
      position: const Duration(seconds: 60),
    );

    await _pumpWithManager(
      tester,
      harness: harness,
      sessionStream: sessionController.stream,
    );
    sessionController.add(initialSession);
    await tester.pump();
    await tester.pump();

    final sliderFinder = find.byKey(const Key('cast-bar-scrubber'));
    expect(sliderFinder, findsOneWidget);
    final startValue = tester.widget<Slider>(sliderFinder).value;

    // Press down and drag right, but do not release yet.
    final gesture = await tester.startGesture(tester.getCenter(sliderFinder));
    await tester.pump();
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump();

    final draggedValue = tester.widget<Slider>(sliderFinder).value;
    expect(draggedValue, isNot(closeTo(startValue, 0.01)),
        reason: 'the thumb must follow the drag');
    expect(harness.backend.seeks, isEmpty,
        reason: 'dragging must not seek on every frame, only on release');

    // The receiver's own position stream keeps ticking during a drag; a new
    // session update carrying the pre-drag position must not snap the thumb
    // back to it.
    sessionController.add(initialSession);
    await tester.pump();

    final midDragValue = tester.widget<Slider>(sliderFinder).value;
    expect(midDragValue, draggedValue,
        reason: 'a position event mid-drag must not override the local '
            'drag position');
    expect(harness.backend.seeks, isEmpty);

    await gesture.up();
    await tester.pump();

    expect(harness.backend.seeks, hasLength(1),
        reason: 'release must seek exactly once');
    final expectedTarget =
        seekTargetForFraction(draggedValue, initialSession.mediaInfo!.duration);
    expect(harness.backend.seeks.single, expectedTarget);
  });

  testWidgets(
      'confirming stop clears a target set while the session was already '
      'live', (tester) async {
    final harness = _buildManagerHarness();
    addTearDown(harness.manager.dispose);

    final sessionController = StreamController<CastSession?>();
    addTearDown(sessionController.close);

    final container = await _pumpWithManager(
      tester,
      harness: harness,
      sessionStream: sessionController.stream,
    );
    sessionController.add(_session(duration: const Duration(minutes: 44)));
    await tester.pump();
    await tester.pump();

    // Mirrors cast_actions.dart's re-target fallback: a target can be set
    // while a session is already live, when nothing is persisted behind it
    // to re-cast. The idle "x" does not render in that state, so stopping
    // the session must be the path that clears it.
    container.read(castTargetProvider.notifier).set(_device);

    await tester.tap(find.byKey(const Key('cast-bar-stop')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Stop'));
    await tester.pumpAndSettle();

    expect(container.read(castTargetProvider), isNull,
        reason: 'stopping a cast must clear castTargetProvider, or the '
            'next playback would silently cast again');
  });

  testWidgets('the stale-session stop button clears the target',
      (tester) async {
    final harness = _buildManagerHarness();
    addTearDown(harness.manager.dispose);

    final sessionController = StreamController<CastSession?>();
    addTearDown(sessionController.close);

    final container = await _pumpWithManager(
      tester,
      harness: harness,
      sessionStream: sessionController.stream,
    );
    sessionController.add(_session(
      duration: const Duration(minutes: 44),
      isStale: true,
    ));
    await tester.pump();
    await tester.pump();

    container.read(castTargetProvider.notifier).set(_device);

    await tester.tap(find.byKey(const Key('cast-stale-stop')));
    await tester.pumpAndSettle();

    expect(container.read(castTargetProvider), isNull);
  });
}
