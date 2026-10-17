import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/compatibility/compatibility_verdict.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/remote/node_registration_providers.dart';
import 'package:player/core/remote/registration_status.dart';
import 'package:player/core/remote/remote_control_settings.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_secrets.dart';
import 'package:player/core/sources/source.dart' show SourceId;
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/core/update/update_backend.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/user_settings.dart';
import 'package:player/presentation/screens/settings/dialog/open_settings.dart';
import 'package:player/presentation/screens/settings/dialog/settings_dialog.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';
import 'package:player/presentation/screens/sources/mydia_instance_screen.dart';

import '../../../../core/sources/mydia/mydia_account_harness.dart'
    show mydiaRecord;
import '../../../../test_utils/mock_auth_storage.dart';
import '../../../../test_utils/mydia_test_source.dart';
import '../../../../test_utils/no_downloads.dart';
import '../../../../test_utils/toast_harness.dart';

class _FakeP2pStatusNotifier extends P2pStatusNotifier {
  @override
  P2pStatus build() => const P2pStatus(
        isInitialized: true,
        isRelayConnected: false,
        connectedPeersCount: 0,
      );
}

class _FakeUpdateNotifier extends UpdateNotifier {
  @override
  UpdateState build() =>
      const UpdateState(manualCheck: ManualCheckBehaviour.checksOnly);
}

class _FakeSettingsController extends SettingsController {
  @override
  Future<UserSettings> build() async => const UserSettings(
        serverUrl: 'mydia.local:4000',
        username: 'admin',
        defaultQuality: '1080p',
      );
}

class _StubRegistration extends NodeRegistrations {
  @override
  Map<SourceId, RegistrationStatus> build() => const {};

  @override
  void retryAll() {}
}

void main() {
  final recordA = mydiaRecord('a', addedAtMs: 0);
  final recordB = mydiaRecord('b', addedAtMs: 1);
  late Box<dynamic> box;
  var boxCounter = 0;

  setUp(() async {
    resetSettingsDialogForTest();
    boxCounter += 1;
    box = await Hive.openBox<dynamic>('open_settings_$boxCounter',
        bytes: Uint8List(0));
  });
  tearDown(() async => box.close());

  Future<void> pumpApp(
    WidgetTester tester, {
    required bool dialog,
    SettingsCategory initial = SettingsCategory.playback,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = InMemorySourceStore();
    final secrets = SourceSecrets(MockAuthStorage());
    for (final r in [recordA, recordB]) {
      await store.putAccount(r);
      await writeMydiaCredentials(
          secrets,
          r.account,
          MydiaCredentials(
            instanceId: r.servers.single.id,
            accessToken: 'tok',
            serverUrl: 'https://${r.account.id}.example.test',
          ));
    }
    Widget stub(String path) => Scaffold(body: Text('at $path'));
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => openSettings(context, initial: initial),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      for (final p in [
        '/settings',
        '/settings/diagnostics',
        '/sources/manage',
        '/sources/add',
        '/unlock',
      ])
        GoRoute(path: p, builder: (_, __) => stub(p)),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        settingsDialogEnabledProvider.overrideWithValue(dialog),
        settingsControllerProvider.overrideWith(_FakeSettingsController.new),
        p2pStatusNotifierProvider.overrideWith(_FakeP2pStatusNotifier.new),
        updateProvider.overrideWith(_FakeUpdateNotifier.new),
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(secrets),
        remoteControlSettingsProvider
            .overrideWith((ref) async => RemoteControlSettings(box: box)),
        nodeRegistrationsProvider.overrideWith(_StubRegistration.new),
        activeSourceIdProvider.overrideWithValue(testMydiaSourceId),
        mediaSourceProvider.overrideWith((ref, id) => null),
        serverCompatibilityProvider.overrideWith((ref, id) async =>
            const ServerCompatibility(
                info: null, verdict: CompatibilityVerdict.unknown)),
      ],
      child: MaterialApp.router(
        builder: toastLayerBuilder,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('off desktop, openSettings follows the old routes',
      (tester) async {
    await pumpApp(tester, dialog: false, initial: SettingsCategory.servers);
    await open(tester);
    expect(find.text('at /sources/manage'), findsOneWidget);
    expect(find.byKey(const Key('settings-dialog')), findsNothing);
  });

  testWidgets('on desktop, openSettings opens the dialog on the category',
      (tester) async {
    await pumpApp(tester, dialog: true, initial: SettingsCategory.about);
    await open(tester);
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);
    expect(find.byKey(const Key('check-for-updates-row')), findsOneWidget);
  });

  testWidgets('a second open retargets instead of stacking', (tester) async {
    await pumpApp(tester, dialog: true);
    await open(tester);
    final context = tester.element(find.byKey(const Key('settings-dialog')));
    expect(openSettingsForRoute(context, '/settings/diagnostics'), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);
    expect(find.byKey(const Key('copy-diagnostics')), findsOneWidget);
  });

  testWidgets('openSettingsForRoute ignores other routes and mobile',
      (tester) async {
    await pumpApp(tester, dialog: false);
    final context = tester.element(find.text('open'));
    expect(openSettingsForRoute(context, '/settings'), isFalse);
    expect(openSettingsForRoute(context, '/downloads'), isFalse);
  });

  testWidgets('Servers opens an instance in the pane and back returns',
      (tester) async {
    await pumpApp(tester, dialog: true, initial: SettingsCategory.servers);
    await open(tester);
    await tester.tap(find.byKey(Key('manage-settings-${recordA.account.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mydia-instance-server')), findsOneWidget);
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-dialog-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manage-add')), findsOneWidget);
  });

  testWidgets('Add server closes the dialog, then pushes add-a-server',
      (tester) async {
    await pumpApp(tester, dialog: true, initial: SettingsCategory.servers);
    await open(tester);
    await tester.tap(find.byKey(const Key('manage-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog')), findsNothing);
    expect(find.text('at /sources/add'), findsOneWidget);
  });

  testWidgets('the unlock screen opens above the dialog and returns to it',
      (tester) async {
    await pumpApp(tester, dialog: true, initial: SettingsCategory.servers);
    await open(tester);
    await tester.ensureVisible(find.byKey(const Key('show-hidden-sources')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('show-hidden-sources')));
    await tester.pumpAndSettle();
    expect(find.text('at /unlock'), findsOneWidget);

    GoRouter.of(tester.element(find.text('at /unlock'))).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);
  });

  testWidgets('removing the open instance pops back to the list',
      (tester) async {
    await pumpApp(tester, dialog: true, initial: SettingsCategory.servers);
    await open(tester);
    await tester.tap(find.byKey(Key('manage-settings-${recordA.account.id}')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('mydia-instance-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('mydia-instance-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-remove-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mydia-instance-server')), findsNothing);
    expect(find.byKey(const Key('manage-add')), findsOneWidget);
  });

  test('isSettingsShortcut matches Ctrl+, key-down only', () {
    const down = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.comma,
      logicalKey: LogicalKeyboardKey.comma,
      timeStamp: Duration.zero,
    );
    const up = KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.comma,
      logicalKey: LogicalKeyboardKey.comma,
      timeStamp: Duration.zero,
    );
    expect(isSettingsShortcut(down, controlPressed: true), isTrue);
    expect(isSettingsShortcut(down, controlPressed: false), isFalse);
    expect(isSettingsShortcut(up, controlPressed: true), isFalse);
  });

  test('isSettingsShortcut rejects Shift, Alt (AltGr) and Meta', () {
    const down = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.comma,
      logicalKey: LogicalKeyboardKey.comma,
      timeStamp: Duration.zero,
    );
    expect(isSettingsShortcut(down, controlPressed: true, shiftPressed: true),
        isFalse);
    expect(isSettingsShortcut(down, controlPressed: true, altPressed: true),
        isFalse);
    expect(isSettingsShortcut(down, controlPressed: true, metaPressed: true),
        isFalse);
  });
}
