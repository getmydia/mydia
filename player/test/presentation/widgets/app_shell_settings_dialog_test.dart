// The shell's entry points into the settings dialog: the sidebar row, Ctrl+,
// and the host hook the macOS menu uses. A real ShellRoute, so the dialog
// opens over the same navigator stack as in the app.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/compatibility/compatibility_verdict.dart';
import 'package:player/core/downloads/collection_auto_sync.dart';
import 'package:player/core/downloads/orphan_download_sweep.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/playback/playback_progress_providers.dart';
import 'package:player/core/remote/node_registration_providers.dart';
import 'package:player/core/remote/registration_status.dart';
import 'package:player/core/remote/remote_control_settings.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_secrets.dart';
import 'package:player/core/sources/source.dart' show Source, SourceId;
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/core/update/update_backend.dart';
import 'package:player/core/update/update_dismissal_provider.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/domain/models/user_settings.dart';
import 'package:player/presentation/screens/settings/dialog/open_settings.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';
import 'package:player/presentation/screens/settings/dialog/settings_dialog.dart'
    show SettingsCategory;
import 'package:player/presentation/screens/sources/mydia_instance_screen.dart';
import 'package:player/presentation/widgets/app_shell.dart';

import '../../core/sources/mydia/mydia_account_harness.dart' show mydiaRecord;
import '../../test_utils/mock_auth_storage.dart';
import '../../test_utils/mydia_test_source.dart';
import '../../test_utils/no_downloads.dart';
import '../../test_utils/toast_harness.dart';
import '../screens/sources/fake_media_source.dart';

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

/// The shell starts collection auto-sync, which opens a Hive box.
class _NoAutoSync implements CollectionAutoSync {
  @override
  dynamic noSuchMethod(Invocation invocation) {}
}

class _NoDismissals extends UpdateDismissalNotifier {
  @override
  Future<Set<String>> build() async => <String>{};
}

class _Src extends FakeMediaSource {
  _Src(this._source);
  final Source _source;

  @override
  Source get source => _source;
}

class _StubRegistration extends NodeRegistrations {
  @override
  Map<SourceId, RegistrationStatus> build() => const {};

  @override
  void retryAll() {}
}

/// A store whose rail starts pinned, so its rows take taps.
InMemorySidebarLayoutStore pinnedStore() {
  final store = InMemorySidebarLayoutStore();
  unawaited(store.saveRailPinned(true));
  return store;
}

void main() {
  final recordA = mydiaRecord('a', addedAtMs: 0);
  late Box<dynamic> box;
  var boxCounter = 0;

  setUp(() async {
    resetSettingsDialogForTest();
    boxCounter += 1;
    box = await Hive.openBox<dynamic>('shell_settings_$boxCounter',
        bytes: Uint8List(0));
  });
  tearDown(() async => box.close());

  late GoRouter shellRouter;

  Future<void> pumpShell(
    WidgetTester tester, {
    required bool dialog,
    ValueNotifier<bool>? noServers,
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = InMemorySourceStore();
    final secrets = SourceSecrets(MockAuthStorage());
    await store.putAccount(recordA);
    await writeMydiaCredentials(
        secrets,
        recordA.account,
        MydiaCredentials(
          instanceId: recordA.servers.single.id,
          accessToken: 'tok',
          serverUrl: 'https://${recordA.account.id}.example.test',
        ));

    final rootKey = GlobalKey<NavigatorState>();
    final shellKey = GlobalKey<NavigatorState>();
    final router = GoRouter(
      navigatorKey: rootKey,
      refreshListenable: noServers,
      // Stands in for the app's "no sources -> add-a-server" redirect.
      redirect: (_, state) =>
          (noServers?.value ?? false) && state.matchedLocation != '/sources/add'
              ? '/sources/add'
              : null,
      routes: [
        ShellRoute(
          navigatorKey: shellKey,
          builder: (context, state, child) =>
              AppShell(location: state.matchedLocation, child: child),
          routes: [
            GoRoute(
              path: '/',
              builder: (_, __) => const SizedBox.expand(),
            ),
            GoRoute(
              path: '/settings',
              builder: (_, __) => const Center(child: Text('settings page')),
            ),
          ],
        ),
        GoRoute(
          path: '/unlock',
          parentNavigatorKey: rootKey,
          builder: (_, __) => const Scaffold(body: Text('at /unlock')),
        ),
        GoRoute(
          path: '/sources/add',
          parentNavigatorKey: rootKey,
          builder: (_, __) => const Scaffold(body: Text('at /sources/add')),
        ),
      ],
    );
    addTearDown(router.dispose);
    shellRouter = router;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        settingsDialogEnabledProvider.overrideWithValue(dialog),
        sidebarLayoutStoreProvider.overrideWithValue(pinnedStore()),
        sourceProgressFlushProvider.overrideWith((ref) {}),
        orphanDownloadSweepProvider.overrideWith((ref) {}),
        settingsControllerProvider.overrideWith(_FakeSettingsController.new),
        p2pStatusNotifierProvider.overrideWith(_FakeP2pStatusNotifier.new),
        updateProvider.overrideWith(_FakeUpdateNotifier.new),
        noDownloadsOverride,
        collectionAutoSyncProvider.overrideWithValue((_) => _NoAutoSync()),
        updateDismissalProvider.overrideWith(_NoDismissals.new),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(secrets),
        remoteControlSettingsProvider
            .overrideWith((ref) async => RemoteControlSettings(box: box)),
        nodeRegistrationsProvider.overrideWith(_StubRegistration.new),
        activeSourceIdProvider.overrideWithValue(testMydiaSourceId),
        mediaSourceProvider.overrideWith((ref, id) => null),
        mediaSourceProvider(testMydiaSourceId)
            .overrideWithValue(_Src(testMydiaSource)),
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

  testWidgets('the sidebar Settings item opens the dialog on desktop',
      (tester) async {
    await pumpShell(tester, dialog: true);
    await tester.tap(find.byKey(const ValueKey('sidebar-row-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);
    expect(find.text('settings page'), findsNothing);
  });

  testWidgets('without the dialog the sidebar still routes', (tester) async {
    await pumpShell(tester, dialog: false);
    await tester.tap(find.byKey(const ValueKey('sidebar-row-settings')));
    await tester.pumpAndSettle();
    expect(find.text('settings page'), findsOneWidget);
  });

  testWidgets('Ctrl+, opens the dialog while the shell is up', (tester) async {
    // Reset in the body: the framework checks the override before tearDowns.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await pumpShell(tester, dialog: true);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-dialog')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the host route opens settings for the menu bar', (tester) async {
    await pumpShell(tester, dialog: true);
    expect(openSettingsFromHost('/settings'), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);
  });

  testWidgets('the unlock route sits above the dialog and returns to it',
      (tester) async {
    await pumpShell(tester, dialog: true);
    expect(openSettingsFromHost('/sources/manage'), isTrue);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('show-hidden-sources')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('show-hidden-sources')));
    await tester.pumpAndSettle();
    expect(find.text('at /unlock'), findsOneWidget);
    expect(find.text('at /unlock').hitTestable(), findsOneWidget);

    GoRouter.of(tester.element(find.text('at /unlock'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('at /unlock'), findsNothing);
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);
  });

  SettingsCategory selectedCategory(WidgetTester tester) =>
      SettingsCategory.values.singleWhere((c) => tester
          .widget<ListTile>(find.byKey(Key('settings-category-${c.name}')))
          .selected);

  Future<void> pressCtrlComma(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('the dialog closes when the shell is replaced by add-a-server',
      (tester) async {
    final noServers = ValueNotifier<bool>(false);
    addTearDown(noServers.dispose);
    await pumpShell(tester, dialog: true, noServers: noServers);
    expect(openSettingsFromHost('/sources/manage'), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);

    noServers.value = true;
    await tester.pumpAndSettle();
    expect(find.text('at /sources/add'), findsOneWidget);
    expect(find.byKey(const Key('settings-dialog')), findsNothing);
  });

  testWidgets('settings does not open over a root route', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await pumpShell(tester, dialog: true);
      unawaited(shellRouter.push<void>('/unlock'));
      await tester.pumpAndSettle();
      expect(find.text('at /unlock'), findsOneWidget);

      expect(openSettingsFromHost('/settings'), isFalse);
      await pressCtrlComma(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-dialog')), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the menu path retargets an open dialog', (tester) async {
    await pumpShell(tester, dialog: true);
    expect(openSettingsFromHost('/settings'), isTrue);
    await tester.pumpAndSettle();
    expect(selectedCategory(tester), SettingsCategory.playback);

    expect(openSettingsFromHost('/sources/manage'), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);
    expect(selectedCategory(tester), SettingsCategory.servers);
  });

  testWidgets('Ctrl+, leaves an open dialog where the user is', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await pumpShell(tester, dialog: true);
      expect(openSettingsFromHost('/sources/manage'), isTrue);
      await tester.pumpAndSettle();
      expect(selectedCategory(tester), SettingsCategory.servers);

      await pressCtrlComma(tester);
      expect(selectedCategory(tester), SettingsCategory.servers);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
