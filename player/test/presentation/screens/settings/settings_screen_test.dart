// material.dart exports its own ConnectionState (the async-widget one), which
// clashes with the app's. Tasks 2 and 7 hit this too.
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/connection/connection_provider.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/domain/models/user_settings.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';
import 'package:player/presentation/screens/settings/settings_screen.dart';
import 'package:player/presentation/screens/settings/widgets/settings_hero.dart';

class _FakeConnectionNotifier extends ConnectionNotifier {
  _FakeConnectionNotifier(this._state);

  final ConnectionState _state;

  @override
  ConnectionState build() => _state;
}

class _FakeP2pStatusNotifier extends P2pStatusNotifier {
  _FakeP2pStatusNotifier(this._status);

  final P2pStatus _status;

  @override
  P2pStatus build() => _status;
}

/// Serves a fixed settings value, or fails, without touching secure storage.
class _FakeSettingsController extends SettingsController {
  _FakeSettingsController({this.value, this.fail = false});

  final UserSettings? value;
  final bool fail;

  /// Records what the screen asked us to change.
  static final skipCalls = <bool>[];

  @override
  Future<UserSettings> build() async {
    if (fail) throw Exception('storage unavailable');
    return value!;
  }

  @override
  Future<void> setAutoSkipSegments(bool enabled) async {
    skipCalls.add(enabled);
  }
}

const _settings = UserSettings(
  serverUrl: 'mydia.local:4000',
  username: 'admin',
  defaultQuality: '1080p',
);

const _status = P2pStatus(
  isInitialized: true,
  isRelayConnected: false,
  connectedPeersCount: 0,
);

Future<void> _pump(
  WidgetTester tester, {
  UserSettings? settings = _settings,
  bool fail = false,
  Size size = const Size(1000, 1400),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsControllerProvider.overrideWith(
          () => _FakeSettingsController(value: settings, fail: fail),
        ),
        connectionProvider.overrideWith(
          () => _FakeConnectionNotifier(
            const ConnectionState(type: ConnectionType.direct),
          ),
        ),
        p2pStatusNotifierProvider.overrideWith(
          () => _FakeP2pStatusNotifier(_status),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/settings',
          routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsScreen(),
            ),
            GoRoute(
              path: '/settings/devices',
              builder: (context, state) =>
                  const Scaffold(body: Text('devices stub')),
            ),
            GoRoute(
              path: '/settings/diagnostics',
              builder: (context, state) =>
                  const Scaffold(body: Text('diagnostics stub')),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(_FakeSettingsController.skipCalls.clear);

  testWidgets('renders the hero with identity and connection', (tester) async {
    await _pump(tester);

    expect(find.byType(SettingsHero), findsOneWidget);
    expect(find.text('admin'), findsOneWidget);
    expect(find.text('mydia.local:4000'), findsOneWidget);
    expect(find.text('Connected to server'), findsOneWidget);
  });

  testWidgets('shows the current quality rung label', (tester) async {
    await _pump(tester);

    expect(find.text('Default quality'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
  });

  testWidgets('the skip toggle reports its change to the controller',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(_FakeSettingsController.skipCalls, [true]);
  });

  testWidgets('paired devices navigates to the devices route', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Paired devices'));
    await tester.pumpAndSettle();

    expect(find.text('devices stub'), findsOneWidget);
  });

  testWidgets('connection details navigates to diagnostics', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('Connection details'));
    await tester.pumpAndSettle();

    expect(find.text('diagnostics stub'), findsOneWidget);
  });

  testWidgets('the check-for-updates row is present on a supported platform',
      (tester) async {
    // A `flutter test` host on Linux always reports a supported platform, so
    // only this branch is reachable here. The absent branch is covered at the
    // gate itself by test/core/update/platform_updater_test.dart, which
    // exercises `supportedOnPlatform` for web, Android, and iOS.
    await _pump(tester);

    expect(find.byKey(const Key('check-for-updates-row')), findsOneWidget);
  });

  testWidgets('no row shows a raw relay url or peer count', (tester) async {
    await _pump(tester);

    // The Manage row subtitle mentions "peers" as a topic; assert against the
    // diagnostics strings that used to leak onto this screen instead.
    expect(find.textContaining('relay.'), findsNothing);
    expect(find.text('Connected peers'), findsNothing);
    expect(find.textContaining('None connected'), findsNothing);
  });

  group('when preferences fail to load', () {
    testWidgets('sign out stays reachable', (tester) async {
      await _pump(tester, settings: null, fail: true);

      expect(find.byKey(const Key('settings-sign-out')), findsOneWidget);
    });

    testWidgets('the screen is not replaced by a full-page error',
        (tester) async {
      await _pump(tester, settings: null, fail: true);

      expect(find.text('Paired devices'), findsOneWidget);
      expect(find.text('Connection details'), findsOneWidget);
    });

    testWidgets('playback controls are disabled and offer a retry',
        (tester) async {
      await _pump(tester, settings: null, fail: true);

      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('updateCheckSubtitle', () {
    test('macOS says Sparkle owns it rather than claiming a clean check', () {
      // Sparkle owns checking on macOS, so UpdateNotifier never runs one and
      // availableUpdate stays null. Reusing the generic wording here would
      // report "up to date" off the back of a check that never happened.
      expect(
        updateCheckSubtitle(isMacOS: true, availableVersion: null),
        'Opens the Sparkle update dialog',
      );
    });

    test('macOS wording wins even when a version is somehow known', () {
      expect(
        updateCheckSubtitle(isMacOS: true, availableVersion: '0.15.0'),
        'Opens the Sparkle update dialog',
      );
    });

    test('elsewhere an available version is named', () {
      expect(
        updateCheckSubtitle(isMacOS: false, availableVersion: '0.15.0'),
        'v0.15.0 available',
      );
    });

    test('elsewhere no available version reads as up to date', () {
      expect(
        updateCheckSubtitle(isMacOS: false, availableVersion: null),
        "You're up to date",
      );
    });
  });
}
