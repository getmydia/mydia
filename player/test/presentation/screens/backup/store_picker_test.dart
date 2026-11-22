import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_providers.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/backup/google_device_code_sheet.dart';
import 'package:player/presentation/screens/connections/backup_section.dart';

import '../../../core/backup/cloud/in_memory_cloud_backend.dart';
import '../../../core/backup/fake_backup_relay.dart';
import '../../../test_utils/toast_harness.dart';
import 'backup_device_rig.dart';
import 'backup_section_harness.dart';
import 'fake_backup_controller.dart';
import 'fake_backup_sync_service.dart';

const _all = {
  BackupStoreKind.relay,
  BackupStoreKind.icloud,
  BackupStoreKind.gdrive,
};

void main() {
  testWidgets('picker_lists_offered_stores_with_privacy_lines', (tester) async {
    await pumpBackupSection(tester, FakeBackupController(offered: _all));

    expect(find.byKey(const Key('backup-store-relay')), findsOneWidget);
    expect(find.byKey(const Key('backup-store-icloud')), findsOneWidget);
    expect(find.byKey(const Key('backup-store-gdrive')), findsOneWidget);
    expect(find.text('Mydia relay (end-to-end encrypted)'), findsOneWidget);
    expect(
      find.text('Only your devices can read it. Keep the recovery key safe.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Stored in your iCloud account. Apple can read it, '
        'including your source sign-ins.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Stored in your Google account. Google can read it, '
        'including your source sign-ins.',
      ),
      findsOneWidget,
    );
    // The picker takes the switch's place.
    expect(find.byKey(const Key('backup-switch')), findsNothing);
  });

  testWidgets('a store that is not offered is not listed', (tester) async {
    await pumpBackupSection(
      tester,
      FakeBackupController(
        offered: const {BackupStoreKind.relay, BackupStoreKind.gdrive},
      ),
    );

    expect(find.byKey(const Key('backup-store-icloud')), findsNothing);
    expect(find.byKey(const Key('backup-store-gdrive')), findsOneWidget);
  });

  testWidgets('with only the relay offered, the switch stays', (tester) async {
    await pumpBackupSection(tester, FakeBackupController());

    expect(find.byKey(const Key('backup-switch')), findsOneWidget);
    expect(find.byKey(const Key('backup-store-relay')), findsNothing);
  });

  testWidgets('picking_gdrive_runs_sign_in_then_enables', (tester) async {
    final controller = FakeBackupController(offered: _all);
    final google = FakeGoogleSignIn(controller.calls);
    await pumpBackupSection(tester, controller, google: google);

    await tester.tap(find.byKey(const Key('backup-store-gdrive')));
    await tester.pumpAndSettle();

    expect(controller.calls, ['signIn', 'enableCloud gdrive']);
    expect(controller.active.value, BackupStoreKind.gdrive);
  });

  testWidgets('picking gdrive while signed in skips the sign-in', (
    tester,
  ) async {
    final controller = FakeBackupController(offered: _all);
    final google = FakeGoogleSignIn(controller.calls, email: 'ana@example.com');
    await pumpBackupSection(tester, controller, google: google);

    await tester.tap(find.byKey(const Key('backup-store-gdrive')));
    await tester.pumpAndSettle();

    expect(controller.calls, ['enableCloud gdrive']);
  });

  testWidgets('a declined Google sign-in enables nothing, quietly', (
    tester,
  ) async {
    final controller = FakeBackupController(offered: _all);
    final google = FakeGoogleSignIn(controller.calls)
      ..signInError = const BackupRelayException(BackupRelayError.signedOut);
    await pumpBackupSection(tester, controller, google: google);

    await tester.tap(find.byKey(const Key('backup-store-gdrive')));
    await tester.pumpAndSettle();

    expect(controller.calls, ['signIn']);
    expect(controller.active.value, isNull);
    expect(find.text("Couldn't update the backup. Try again."), findsNothing);
  });

  testWidgets('picking iCloud while iCloud is unavailable says how to fix it', (
    tester,
  ) async {
    final controller = FakeBackupController(offered: _all)
      ..enableError = const BackupRelayException(
        BackupRelayError.cloudUnavailable,
      );
    await pumpBackupSection(tester, controller);

    await tester.tap(find.byKey(const Key('backup-store-icloud')));
    await tester.pumpAndSettle();

    expect(controller.calls, ['enableCloud icloud']);
    expect(
      find.text('iCloud is unavailable. Sign in to iCloud in Settings.'),
      findsOneWidget,
    );
  });

  testWidgets('picking the relay goes through the controller with the key', (
    tester,
  ) async {
    final relay = FakeBackupSyncService();
    final controller = FakeBackupController(relay: relay, offered: _all);
    await pumpBackupSection(tester, controller);

    await tester.tap(find.byKey(const Key('backup-store-relay')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-key-text')), findsOneWidget);
    await tester.tap(find.byKey(const Key('recovery-key-saved-checkbox')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('recovery-key-confirm-button')));
    await tester.pumpAndSettle();

    expect(controller.calls, ['switchTo relay deleteOld=false key']);
    expect(relay.calls.last, startsWith('confirmEnable'));
  });

  testWidgets(
    'a stored cloud store that cannot be built shows the picker, and the '
    'relay can still be turned on',
    (tester) async {
      final device = BackupTestDevice(FakeBackupRelay(), 'Living Room TV');
      addTearDown(device.dispose);
      device.auth.seedData({BackupController.storeKey: 'gdrive'});
      final icloud = InMemoryCloudStore();
      final controller = BackupController(
        relay: device.service,
        authStorage: device.auth,
        resolveOffered: () async => _all,
        buildCloud: (kind) async {
          if (kind == BackupStoreKind.gdrive) throw StateError('no backend');
          return buildCloudBackupService(
            backend: InMemoryCloudBackend(icloud, kind: kind.cloudKind!),
            authStorage: device.auth,
            meta: device.meta,
            snapshot: device.snapshot,
            deviceName: () async => device.name,
            platform: 'linux',
          );
        },
      );
      addTearDown(controller.dispose);
      await tester.runAsync(() async {
        await controller.ready;
        await controller.start();
      });

      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backupSyncServiceProvider.overrideWithValue(device.service),
            backupControllerProvider.overrideWithValue(controller),
            googleSignInMethodProvider.overrideWithValue(null),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: toastLayerBuilder,
            home: Scaffold(body: SingleChildScrollView(child: BackupSection())),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Off, so the picker, not a relay switch whose toggle would throw for
      // the missing store. Turning the relay on from here is covered by
      // `stored_cloud_store_that_cannot_be_built_is_off_not_stuck`.
      expect(controller.active.value, isNull);
      expect(find.byKey(const Key('backup-store-relay')), findsOneWidget);
      expect(find.byKey(const Key('backup-store-icloud')), findsOneWidget);
      expect(find.byKey(const Key('backup-store-gdrive')), findsNothing);
      expect(find.byKey(const Key('backup-switch')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('picking a dormant relay wakes it without a new key', (
    tester,
  ) async {
    final relay = FakeBackupSyncService()..isDormant = true;
    final controller = FakeBackupController(relay: relay, offered: _all);
    await pumpBackupSection(tester, controller);

    await tester.tap(find.byKey(const Key('backup-store-relay')));
    await tester.pumpAndSettle();

    expect(controller.calls, ['switchTo relay deleteOld=false']);
    expect(find.byKey(const Key('recovery-key-text')), findsNothing);
  });
}
