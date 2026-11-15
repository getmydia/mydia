// On a television the backup controls are reached with the D-pad alone:
// DOWN from the control above Backup & sync lands on its switch, and on the
// restore summary focus starts on Back (a stray OK must not restore) with
// Restore one RIGHT away.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/backup/backup_providers.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/backup/restore_backup_screen.dart';
import 'package:player/presentation/screens/connections/backup_section.dart';

import '../../../core/backup/fake_backup_relay.dart';
import '../../../test_utils/toast_harness.dart';
import '../../../test_utils/tv_shell_harness.dart';
import 'backup_device_rig.dart';
import 'fake_backup_sync_service.dart';

void main() {
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true';

  void tvView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('DOWN reaches the backup switch', skip: skipReason != false,
      (tester) async {
    tvView(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        backupSyncServiceProvider.overrideWithValue(FakeBackupSyncService()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: toastLayerBuilder,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                TextButton(
                  key: const Key('above'),
                  autofocus: true,
                  onPressed: () {},
                  child: const Text('above'),
                ),
                const BackupSection(),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expectFocusIn(const Key('above'));

    await press(tester, LogicalKeyboardKey.arrowDown);

    expectFocusIn(const Key('backup-switch'));
  });

  testWidgets('the restore summary starts on Back; RIGHT reaches Restore',
      skip: skipReason != false, (tester) async {
    tvView(tester);
    final (tv, fresh, key) = (await tester.runAsync(() async {
      final relay = FakeBackupRelay();
      final tv = BackupTestDevice(relay, 'Living Room TV');
      final key = await tv.enable();
      final fresh = BackupTestDevice(relay, 'Night Harbor Laptop');
      await fresh.service.start();
      return (tv, fresh, key);
    }))!;
    addTearDown(() {
      tv.dispose();
      fresh.dispose();
    });
    final router = GoRouter(
      initialLocation: restoreBackupLocation,
      routes: [
        GoRoute(
          path: restoreBackupLocation,
          builder: (_, __) => const RestoreBackupScreen(),
        ),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [backupSyncServiceProvider.overrideWithValue(fresh.service)],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: toastLayerBuilder,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('restore-key-field')), key.display);
    await tester.tap(find.byKey(const Key('restore-find-button')));
    await settleEngine(tester,
        until: () =>
            find.byKey(const Key('restore-summary')).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expectFocusIn(const Key('restore-back-button'));

    await press(tester, LogicalKeyboardKey.arrowRight);

    expectFocusIn(const Key('restore-confirm-button'));
    expect(fresh.service.enabled, isFalse, reason: 'nothing pressed OK');
  });
}
