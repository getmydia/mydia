// The wiring between `FullscreenController` and the screen, which is where the
// reported bug survives even after the backend is fixed: the route can go
// unusable at any moment on web, and a screen that reads availability once and
// never listens draws a button over a request that cannot succeed.
//
// `PlayerScreen.debugFullscreenBackendFactory` exists because a `flutter test`
// host always resolves the native backend, which is unconditionally ready, so
// "a route exists but cannot be used right now" is otherwise unreachable.
//
// These stop at the seam rather than asserting on the rendered chrome.
// `PlayerScreen` does not reach `SecondaryCluster` under `flutter test`: it
// polls the HLS playlist over an `HttpClient` it constructs itself, and
// `TestWidgetsFlutterBinding` answers every request 400, so the screen stays in
// its retry state forever. Making the chrome mount needs an injectable client,
// which is a change to streaming, not to fullscreen. The two halves either side
// of this seam are covered where they live: that `available` notifies, in
// `fullscreen_controller_test.dart`, and that a null `onFullscreenTap` omits
// the button, in `panel_controls_test.dart`.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/cast/cast_target.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;
import 'package:player/core/player/fullscreen/fullscreen_backend.dart';
import 'package:player/core/player/fullscreen/fullscreen_failure.dart';
import 'package:player/core/player/fullscreen/fullscreen_mode.dart';
import 'package:player/core/player/fullscreen/fullscreen_report.dart';
import 'package:player/core/player/fullscreen/fullscreen_report_signal.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

void main() {
  late _TestBackend backend;

  setUp(() {
    backend = _TestBackend();
    PlayerScreen.debugFullscreenBackendFactory = (onChange, onFailure) {
      backend.onChange = onChange;
      backend.onFailure = onFailure;
      return backend;
    };
  });

  tearDown(() {
    PlayerScreen.debugFullscreenBackendFactory = null;
    fullscreenReportSignal.value = null;
  });

  /// Mounts the screen with a cast target already set, so `_initializePlayer`
  /// short-circuits before HLS negotiation.
  ///
  /// The same trick `player_screen_dispose_cleanup_test.dart` uses, and for a
  /// related reason: left to run, the playlist poll retries on a timer that is
  /// still pending when the tree is torn down, and the binding fails the test
  /// on it. Nothing here needs playback, only `initState` and the failure
  /// handler.
  Future<void> mount(WidgetTester tester) async {
    mockPathProviderDocumentsDirectory();
    final castManager = CapturingCastSessionManager();
    final container = buildPlayerScreenContainer(
      link: StubLink.responses([
        movieDetailResponse(),
        movieSegmentsResponse(),
        subtitleTrackSettingsResponse(),
        streamingCandidatesResponse(duration: 5400),
      ]),
      connectionState:
          const conn.ConnectionState(type: conn.ConnectionType.direct),
      castManager: castManager,
      proxyService: TrackingLocalProxyService(),
    );
    addTearDown(container.dispose);

    container.read(castTargetProvider.notifier).set(testDevice);

    await pumpPlayerScreen(tester, container);
    await pumpUntil(tester, () => castManager.capturedRequest != null);
  }

  testWidgets('the screen follows availability, not just fullscreen state',
      (tester) async {
    await mount(tester);

    // The defect this guards: reading `available` once at build time leaves the
    // button drawn after the route dies, and hidden after it comes back.
    expect(backend.readyNotifier.listenerCount, greaterThan(0));
  });

  testWidgets('the availability listener is released on dispose',
      (tester) async {
    await mount(tester);
    expect(backend.readyNotifier.listenerCount, greaterThan(0));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(backend.readyNotifier.listenerCount, 0);
  });

  testWidgets('a refused request tells the viewer', (tester) async {
    await mount(tester);

    backend.fail(const FullscreenFailure(
      FullscreenFailureCause.documentRequestRejected,
      requestInitiated: true,
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not enter fullscreen'), findsOneWidget);
  });

  testWidgets('a refused exit says exit, not enter', (tester) async {
    await mount(tester);

    backend.fail(const FullscreenFailure(
      FullscreenFailureCause.documentExitRejected,
      requestInitiated: true,
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not exit fullscreen'), findsOneWidget);
    expect(find.text('Could not enter fullscreen'), findsNothing);
  });

  testWidgets('a failure nobody asked for stays out of the way',
      (tester) async {
    await mount(tester);

    backend.fail(const FullscreenFailure(
      FullscreenFailureCause.documentEnabledProbeFailed,
    ));
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not enter fullscreen'), findsNothing);
  });

  testWidgets('the report reaches the diagnostics signal', (tester) async {
    await mount(tester);

    backend.fail(const FullscreenFailure(
      FullscreenFailureCause.documentRequestRejected,
      requestInitiated: true,
    ));
    await tester.pump();

    expect(fullscreenReportSignal.value, isNotNull);
    expect(fullscreenReportSignal.value!.mode, backend.mode);
  });
}

/// Exposes `hasListeners`, which `ChangeNotifier` keeps `@protected`, so a test
/// can assert that the screen actually subscribed.
class _ObservableFlag extends ValueNotifier<bool> {
  _ObservableFlag(super.value);

  int listenerCount = 0;

  @override
  void addListener(VoidCallback listener) {
    listenerCount++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listenerCount--;
    super.removeListener(listener);
  }
}

/// A backend whose readiness and failures a test drives directly.
class _TestBackend implements FullscreenBackend {
  ValueChanged<bool>? onChange;
  FullscreenFailureSink? onFailure;

  final _ObservableFlag readyNotifier = _ObservableFlag(true);
  bool _disposed = false;

  @override
  FullscreenMode get mode => FullscreenMode.documentElement;

  @override
  ValueListenable<bool> get ready => readyNotifier;

  @override
  FullscreenReport get report =>
      FullscreenReport(mode: mode, ready: readyNotifier.value);

  void fail(FullscreenFailure failure) => onFailure?.call(failure);

  @override
  void attach(Player player) {}

  @override
  void enter() {}

  @override
  void exit() {}

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Not disposed: the screen removes its listener after this runs, and the
    // assertions read the count afterwards.
  }
}
