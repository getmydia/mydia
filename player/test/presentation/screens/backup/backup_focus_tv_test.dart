// On a television the backup controls are reached with the D-pad alone:
// DOWN from the control above Backup & sync lands on its switch, and on the
// restore summary focus starts on Back (a stray OK must not restore) with
// Restore one RIGHT away.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/backup/backup_providers.dart';
import 'package:player/core/backup/cloud/google_oauth_flows.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/backup/google_device_code_sheet.dart';
import 'package:player/presentation/screens/backup/restore_backup_screen.dart';
import 'package:player/presentation/screens/connections/backup_section.dart';

import '../../../core/backup/fake_backup_relay.dart';
import '../../../test_utils/toast_harness.dart';
import '../../../test_utils/tv_shell_harness.dart';
import 'backup_device_rig.dart';
import 'fake_backup_controller.dart';
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

  testWidgets('DOWN reaches the backup switch', skip: skipReason != false, (
    tester,
  ) async {
    tvView(tester);
    final relay = FakeBackupSyncService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backupSyncServiceProvider.overrideWithValue(relay),
          backupControllerProvider.overrideWithValue(
            FakeBackupController(relay: relay),
          ),
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
      ),
    );
    await tester.pumpAndSettle();
    expectFocusIn(const Key('above'));

    await press(tester, LogicalKeyboardKey.arrowDown);

    expectFocusIn(const Key('backup-switch'));
  });

  testWidgets(
    'the restore summary starts on Back; RIGHT reaches Restore',
    skip: skipReason != false,
    (tester) async {
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
            builder: (_, _) => const RestoreBackupScreen(),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backupSyncServiceProvider.overrideWithValue(fresh.service),
            backupControllerProvider.overrideWithValue(
              FakeBackupController(relay: fresh.service),
            ),
          ],
          child: MaterialApp.router(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: toastLayerBuilder,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('restore-key-field')),
        key.display,
      );
      await tester.tap(find.byKey(const Key('restore-find-button')));
      await settleEngine(
        tester,
        until: () =>
            find.byKey(const Key('restore-summary')).evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expectFocusIn(const Key('restore-back-button'));

      await press(tester, LogicalKeyboardKey.arrowRight);

      expectFocusIn(const Key('restore-confirm-button'));
      expect(fresh.service.enabled, isFalse, reason: 'nothing pressed OK');
    },
  );

  testWidgets(
    'picker_and_device_code_sheet_reachable_by_dpad',
    skip: skipReason != false,
    (tester) async {
      tvView(tester);
      final controller = FakeBackupController(
        offered: const {BackupStoreKind.relay, BackupStoreKind.gdrive},
      );
      final google = FakeGoogleSignIn(controller.calls)
        ..deviceCode = StreamController<DeviceCodeState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backupSyncServiceProvider.overrideWithValue(controller.relay),
            backupControllerProvider.overrideWithValue(controller),
            googleSignInMethodProvider.overrideWithValue(google.method),
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
        ),
      );
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(const Key('backup-store-relay'));
      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(const Key('backup-store-gdrive'));

      // The sheet spins until the first code arrives: no settling yet.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      await tester.pump();
      google.deviceCode!.add(
        DeviceCodePending(
          userCode: 'ABCD-EFGH',
          verificationUrl: Uri.parse('https://www.google.com/device'),
          expiresAt: DateTime.now().add(const Duration(minutes: 15)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('ABCD-EFGH'), findsOneWidget);
      // Nothing to type on the TV: focus waits on Cancel.
      expectFocusIn(const Key('google-device-code-cancel'));

      google.deviceCode!.add(const DeviceCodeExpired());
      await tester.pumpAndSettle();
      expectFocusIn(const Key('google-device-code-retry'));
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expectFocusIn(const Key('google-device-code-cancel'));
    },
  );
}
