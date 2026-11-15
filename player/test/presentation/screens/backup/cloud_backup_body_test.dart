import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_providers.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/slot_transport.dart';

import 'backup_section_harness.dart';
import 'fake_backup_controller.dart';
import 'fake_backup_sync_service.dart';

const _all = {
  BackupStoreKind.relay,
  BackupStoreKind.icloud,
  BackupStoreKind.gdrive,
};

/// Backing up to Google Drive as ana@example.com, with the TV beside this
/// device.
FakeBackupController _onDrive() {
  final c = FakeBackupController(offered: _all, active: BackupStoreKind.gdrive);
  c.clouds[BackupStoreKind.gdrive]!
    ..accountNotifier.value = 'ana@example.com'
    ..statusNotifier.value = BackupIdle(DateTime.now()
        .subtract(const Duration(minutes: 3))
        .millisecondsSinceEpoch)
    ..names = {'tv': 'Living Room TV'}
    ..slotsNotifier.value = [
      SlotInfo(
          slotId: 'own',
          version: '1',
          deviceName: 'Night Harbor Laptop',
          updatedAtMs: DateTime.now().millisecondsSinceEpoch),
      const SlotInfo(slotId: 'tv', version: '1', deviceName: 'Living Room TV'),
    ];
  return c;
}

void main() {
  testWidgets('cloud_body_shows_account_and_devices_without_recovery_key',
      (tester) async {
    await pumpBackupSection(tester, _onDrive());

    expect(find.text('Backing up to Google Drive (ana@example.com)'),
        findsOneWidget);
    expect(find.byKey(const Key('backup-cloud-device-own')), findsOneWidget);
    expect(find.byKey(const Key('backup-cloud-device-tv')), findsOneWidget);
    expect(find.text('Living Room TV'), findsOneWidget);
    expect(
        find.byKey(const Key('backup-cloud-device-remove-own')), findsNothing,
        reason: 'this device is not removed from here');
    expect(find.byKey(const Key('backup-show-key')), findsNothing);
    expect(find.byKey(const Key('backup-regenerate-key')), findsNothing);
    expect(find.byKey(const Key('backup-delete')), findsOneWidget);
  });

  testWidgets('iCloud has no account to name', (tester) async {
    final c =
        FakeBackupController(offered: _all, active: BackupStoreKind.icloud);
    c.clouds[BackupStoreKind.icloud]!.statusNotifier.value =
        const BackupIdle(null);
    await pumpBackupSection(tester, c);

    expect(find.text('Backing up to iCloud'), findsOneWidget);
  });

  testWidgets('signed_out_shows_reconnect', (tester) async {
    final c = _onDrive();
    c.clouds[BackupStoreKind.gdrive]!.statusNotifier.value =
        const BackupError(BackupRelayError.signedOut, null);
    final google = FakeGoogleSignIn(c.calls, email: 'ana@example.com');
    await pumpBackupSection(tester, c, google: google);

    expect(find.text('Signed out of Google Drive. Backup is paused.'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-reconnect')));
    await tester.pumpAndSettle();

    // A revoked grant can leave the email behind: sign in regardless.
    expect(c.calls, ['signIn', 'reconnect gdrive']);
    expect(find.text('Signed out of Google Drive. Backup is paused.'),
        findsNothing);
  });

  testWidgets('a full Google storage says so', (tester) async {
    final c = _onDrive();
    c.clouds[BackupStoreKind.gdrive]!.statusNotifier.value =
        const BackupError(BackupRelayError.quotaFull, null);
    await pumpBackupSection(tester, c);

    expect(find.text('Your Google storage is full. Backup is paused.'),
        findsOneWidget);
  });

  testWidgets('an unavailable iCloud says how to fix it', (tester) async {
    final c =
        FakeBackupController(offered: _all, active: BackupStoreKind.icloud);
    c.clouds[BackupStoreKind.icloud]!.statusNotifier.value =
        const BackupError(BackupRelayError.cloudUnavailable, null);
    await pumpBackupSection(tester, c);

    expect(find.text('iCloud is unavailable. Sign in to iCloud in Settings.'),
        findsOneWidget);
  });

  testWidgets('a newer version on another device is flagged', (tester) async {
    final c = _onDrive();
    c.clouds[BackupStoreKind.gdrive]!.newerNotifier.value = true;
    await pumpBackupSection(tester, c);

    expect(
        find.text(
            'A device uses a newer Mydia. Update this one to read its backup.'),
        findsOneWidget);
  });

  testWidgets('moved_notice_switch_calls_switchTo', (tester) async {
    final relay = FakeBackupSyncService()
      ..isEnabled = true
      ..keyText = 'ABCD ' * 12 + 'ABCD'
      ..statusNotifier.value = const BackupIdle(null)
      ..names = {'tv': 'Living Room TV'}
      ..movedNotifier.value = {'tv': 'gdrive'};
    final c = FakeBackupController(relay: relay, offered: _all);
    final google = FakeGoogleSignIn(c.calls, email: 'ana@example.com');
    await pumpBackupSection(tester, c, google: google);

    expect(find.text('Living Room TV moved backup to Google Drive.'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-moved-switch-tv')));
    await tester.pumpAndSettle();

    expect(c.calls, ['switchTo gdrive deleteOld=false']);
    expect(c.active.value, BackupStoreKind.gdrive);
  });

  testWidgets('hint_notice_shown_until_acknowledged', (tester) async {
    final c = FakeBackupController(offered: _all)
      ..hintNotifier.value =
          const CloudStoreHint(BackupStoreKind.gdrive, 'ana@example.com');
    await pumpBackupSection(tester, c);

    expect(find.text('Your devices back up to Google Drive. Sign in to join.'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-hint-dismiss')));
    await tester.pumpAndSettle();

    expect(c.calls, ['acknowledgeHint']);
    expect(find.text('Your devices back up to Google Drive. Sign in to join.'),
        findsNothing);
  });

  testWidgets('the hint joins the store it names', (tester) async {
    final c = FakeBackupController(offered: _all)
      ..hintNotifier.value =
          const CloudStoreHint(BackupStoreKind.gdrive, 'ana@example.com');
    final google = FakeGoogleSignIn(c.calls);
    await pumpBackupSection(tester, c, google: google);

    await tester.tap(find.byKey(const Key('backup-hint-join')));
    await tester.pumpAndSettle();

    expect(c.calls, ['signIn', 'enableCloud gdrive']);
  });

  testWidgets('the hint rejects a Google sign-in on another account',
      (tester) async {
    final c = FakeBackupController(offered: _all)
      ..hintNotifier.value =
          const CloudStoreHint(BackupStoreKind.gdrive, 'ana@example.com');
    final google = FakeGoogleSignIn(c.calls, signInAs: 'bob@example.com');
    await pumpBackupSection(tester, c, google: google);

    await tester.tap(find.byKey(const Key('backup-hint-join')));
    await tester.pumpAndSettle();

    expect(c.calls, ['signIn']);
    expect(
      find.text(
          'Signed in to bob@example.com. Sign in to ana@example.com to join this backup.'),
      findsOneWidget,
    );
  });

  testWidgets('deleting a cloud backup warns about signed-in devices',
      (tester) async {
    final c = _onDrive();
    await pumpBackupSection(tester, c);

    await tester.tap(find.byKey(const Key('backup-delete')));
    await tester.pumpAndSettle();
    expect(
        find.text('Delete the backup in Google Drive? Devices still signed in '
            'will back it up again until you turn backup off on them.'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-delete-confirm')));
    await tester.pumpAndSettle();

    expect(c.calls, ['deleteBackup gdrive']);
  });

  testWidgets('removing a Drive device explains it and links Google access',
      (tester) async {
    final c = _onDrive();
    await pumpBackupSection(tester, c);

    await tester.tap(find.byKey(const Key('backup-cloud-device-remove-tv')));
    await tester.pumpAndSettle();
    expect(
        find.text('Remove Living Room TV from the backup? It can still read '
            'the backup until it signs out of Google Drive.'),
        findsOneWidget);
    expect(find.byKey(const Key('backup-google-connections')), findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-remove-member-confirm')));
    await tester.pumpAndSettle();

    expect(c.calls, ['removeDevice tv']);
  });

  testWidgets('switching stores asks, and can delete the old backup',
      (tester) async {
    final c = _onDrive();
    await pumpBackupSection(tester, c);

    await tester.tap(find.byKey(const Key('backup-store-icloud')));
    await tester.pumpAndSettle();
    expect(
        find.text('Switch backup to iCloud? Your other devices will be asked '
            'to switch too.'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-switch-delete-old')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('backup-switch-confirm')));
    await tester.pumpAndSettle();

    expect(c.calls, ['switchTo icloud deleteOld=true']);
  });

  testWidgets('turning a cloud store off disables it', (tester) async {
    final c = _onDrive();
    await pumpBackupSection(tester, c);

    await tester.tap(find.byKey(const Key('backup-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup-turn-off-confirm')));
    await tester.pumpAndSettle();

    expect(c.calls, ['disable gdrive']);
  });
}
