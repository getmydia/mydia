// material.dart exports its own ConnectionState (the async-widget one), which
// clashes with the app's. Tasks 2 and 7 hit this too.
import 'dart:typed_data';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/connection/connection_provider.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/remote/remote_control_settings.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/user_settings.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';
import 'package:player/presentation/screens/settings/settings_screen.dart';
import 'package:player/presentation/screens/settings/widgets/settings_identity.dart';

/// A real, isolated Hive box per test: `RemoteControlSettings` takes a real
/// `Box`, and the settings screen's row is the thing under test here, not a
/// stand-in for it. A unique box name per test avoids Hive's open-box cache
/// leaking a prior test's opt-out into the next one.
///
/// Opened with `bytes:`, which selects Hive's in-memory backend, so every
/// read and write is a completed `Future.value()` with no file touched. That
/// is load-bearing rather than tidiness: `testWidgets` runs its body inside a
/// fake-async zone, and tapping the toggle below calls
/// `RemoteControlSettings.setControllable` -- a disk-backed box would leave a
/// real file write outstanding that the zone never drives, so the round trip
/// could never be asserted. `subtitle_track_selector_test.dart` hit the same
/// wall and solved it the same way.
late Box<dynamic> _remoteControlBox;
var _remoteControlBoxCounter = 0;

class _FakeConnectionNotifier extends ConnectionNotifier {
  _FakeConnectionNotifier(this._state);

  final ConnectionState _state;

  @override
  ConnectionState build() => _state;

  /// Sign-out used to call this before ending the session, so a throw here
  /// left the user signed in. Nothing else on this screen calls it.
  @override
  Future<void> clear() async => throw Exception('keyring unavailable');
}

/// Reports a signed-in session and records logout calls, without touching
/// storage. The real teardown is covered in session_teardown_test.dart.
class _RecordingAuthNotifier extends AuthStateNotifier {
  static int logoutCalls = 0;

  @override
  AsyncValue<AuthStatus> build() =>
      const AsyncValue.data(AuthStatus.authenticated);

  @override
  Future<void> logout() async {
    logoutCalls++;
  }
}

class _FakeP2pStatusNotifier extends P2pStatusNotifier {
  _FakeP2pStatusNotifier(this._status);

  final P2pStatus _status;

  @override
  P2pStatus build() => _status;
}

class _FakeUpdateNotifier extends UpdateNotifier {
  _FakeUpdateNotifier(this._state);

  final UpdateState _state;

  @override
  UpdateState build() => _state;
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
  String version = '',
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
        updateProvider.overrideWith(
          () => _FakeUpdateNotifier(UpdateState(currentVersion: version)),
        ),
        authStateProvider.overrideWith(_RecordingAuthNotifier.new),
        remoteControlSettingsProvider.overrideWith(
          (ref) async => RemoteControlSettings(box: _remoteControlBox),
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

  setUp(() async {
    _remoteControlBoxCounter += 1;
    _remoteControlBox = await Hive.openBox<dynamic>(
      'remote_control_$_remoteControlBoxCounter',
      bytes: Uint8List(0),
    );
  });

  // `deleteFromDisk` is unsupported on a memory box and there is nothing on
  // disk to clean up; closing is what unregisters the name.
  tearDown(() async {
    await _remoteControlBox.close();
  });

  testWidgets('renders the identity band with the account and server',
      (tester) async {
    await _pump(tester);

    expect(find.byType(SettingsIdentity), findsOneWidget);
    expect(find.text('admin'), findsOneWidget);
    expect(find.text('mydia.local:4000'), findsOneWidget);
  });

  testWidgets('connection state reads as the subtitle of the details row',
      (tester) async {
    await _pump(tester);

    expect(find.text('Connected to server'), findsOneWidget);
    expect(find.text('Relay, peers, and node identity'), findsNothing);
    expect(find.byKey(const Key('settings-row-status-dot')), findsOneWidget);
  });

  testWidgets('sign out is a danger row in an account section', (tester) async {
    await _pump(tester);

    expect(find.text('Account'), findsOneWidget);
    expect(find.byKey(const Key('settings-sign-out')), findsOneWidget);

    final context = tester.element(find.text('Sign out'));
    final title = tester.widget<Text>(find.text('Sign out'));

    expect(title.style?.color, Theme.of(context).colorScheme.error);
  });

  testWidgets('confirming sign out signs the user out', (tester) async {
    _RecordingAuthNotifier.logoutCalls = 0;
    await _pump(tester);

    await tester.ensureVisible(find.byKey(const Key('settings-sign-out')));
    await tester.tap(find.byKey(const Key('settings-sign-out')));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, 'Sign out'),
    ));
    await tester.pumpAndSettle();

    expect(_RecordingAuthNotifier.logoutCalls, 1);
  });

  testWidgets('cancelling sign out leaves the session alone', (tester) async {
    _RecordingAuthNotifier.logoutCalls = 0;
    await _pump(tester);

    await tester.ensureVisible(find.byKey(const Key('settings-sign-out')));
    await tester.tap(find.byKey(const Key('settings-sign-out')));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(_RecordingAuthNotifier.logoutCalls, 0);
  });

  testWidgets('the footer names the running version', (tester) async {
    await _pump(tester, version: '0.14.2');

    expect(find.text('Mydia Player 0.14.2'), findsOneWidget);
  });

  testWidgets('an unknown version renders no footer rather than a placeholder',
      (tester) async {
    // The hero showed an en dash here. A footer stating an unknown version is
    // worth less than no footer.
    await _pump(tester);

    expect(find.textContaining('Mydia Player'), findsNothing);
  });

  testWidgets('shows the current quality rung label', (tester) async {
    await _pump(tester);

    expect(find.text('Default quality'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
  });

  testWidgets('the skip toggle reports its change to the controller',
      (tester) async {
    await _pump(tester);

    await tester.tap(find.descendant(
      of: find.byKey(const Key('auto-skip-segments-switch')),
      matching: find.byType(Switch),
    ));
    await tester.pump();

    expect(_FakeSettingsController.skipCalls, [true]);
  });

  testWidgets(
      'the remote control toggle is interactive and writes through '
      'RemoteControlSettings', (tester) async {
    await _pump(tester);
    await tester.pumpAndSettle();

    final toggle = find.descendant(
      of: find.byKey(const Key('remote-control-enabled-switch')),
      matching: find.byType(Switch),
    );
    expect(find.text('Allow this device to be controlled'), findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isTrue);
    expect(tester.widget<Switch>(toggle).onChanged, isNotNull);

    await tester.ensureVisible(
      find.byKey(const Key('remote-control-enabled-switch')),
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    // Read back through a *separate* RemoteControlSettings over the same box,
    // which proves the opt-out reached storage rather than only the widget's
    // own state. Going through the class rather than the raw Hive key keeps
    // the test off a private constant.
    expect(
      await RemoteControlSettings(box: _remoteControlBox).controllableEnabled(),
      isFalse,
    );
    // And the switch itself reflects the stored value, which is the part that
    // depends on `_setControllable` invalidating remoteControlEnabledProvider.
    expect(tester.widget<Switch>(toggle).value, isFalse);
  });

  testWidgets('the remote control toggle turns back on', (tester) async {
    // The off direction is the one that stops the endpoint, so it is the one
    // that must not be one-way. Seeded opted-out so the screen starts there.
    await RemoteControlSettings(box: _remoteControlBox).setControllable(false);
    await _pump(tester);
    await tester.pumpAndSettle();

    final toggle = find.descendant(
      of: find.byKey(const Key('remote-control-enabled-switch')),
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await tester.ensureVisible(
      find.byKey(const Key('remote-control-enabled-switch')),
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(
      await RemoteControlSettings(box: _remoteControlBox).controllableEnabled(),
      isTrue,
    );
    expect(tester.widget<Switch>(toggle).value, isTrue);
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

      expect(
        tester
            .widget<Switch>(find.descendant(
              of: find.byKey(const Key('auto-skip-segments-switch')),
              matching: find.byType(Switch),
            ))
            .onChanged,
        isNull,
      );
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
