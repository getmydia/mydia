import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_providers.dart';
import 'package:player/core/backup/backup_relay_client.dart';

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
        findsOneWidget);
    expect(
        find.text('Stored in your iCloud account. Apple can read it, '
            'including your source sign-ins.'),
        findsOneWidget);
    expect(
        find.text('Stored in your Google account. Google can read it, '
            'including your source sign-ins.'),
        findsOneWidget);
    // The picker takes the switch's place.
    expect(find.byKey(const Key('backup-switch')), findsNothing);
  });

  testWidgets('a store that is not offered is not listed', (tester) async {
    await pumpBackupSection(
        tester,
        FakeBackupController(
            offered: const {BackupStoreKind.relay, BackupStoreKind.gdrive}));

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

  testWidgets('picking gdrive while signed in skips the sign-in',
      (tester) async {
    final controller = FakeBackupController(offered: _all);
    final google = FakeGoogleSignIn(controller.calls, email: 'ana@example.com');
    await pumpBackupSection(tester, controller, google: google);

    await tester.tap(find.byKey(const Key('backup-store-gdrive')));
    await tester.pumpAndSettle();

    expect(controller.calls, ['enableCloud gdrive']);
  });

  testWidgets('a declined Google sign-in enables nothing, quietly',
      (tester) async {
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

  testWidgets('picking iCloud while iCloud is unavailable says how to fix it',
      (tester) async {
    final controller = FakeBackupController(offered: _all)
      ..enableError =
          const BackupRelayException(BackupRelayError.cloudUnavailable);
    await pumpBackupSection(tester, controller);

    await tester.tap(find.byKey(const Key('backup-store-icloud')));
    await tester.pumpAndSettle();

    expect(controller.calls, ['enableCloud icloud']);
    expect(find.text('iCloud is unavailable. Sign in to iCloud in Settings.'),
        findsOneWidget);
  });

  testWidgets('picking the relay goes through the controller with the key',
      (tester) async {
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

  testWidgets('picking a dormant relay wakes it without a new key',
      (tester) async {
    final relay = FakeBackupSyncService()..isDormant = true;
    final controller = FakeBackupController(relay: relay, offered: _all);
    await pumpBackupSection(tester, controller);

    await tester.tap(find.byKey(const Key('backup-store-relay')));
    await tester.pumpAndSettle();

    expect(controller.calls, ['switchTo relay deleteOld=false']);
    expect(find.byKey(const Key('recovery-key-text')), findsNothing);
  });
}
