import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_providers.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/connections/backup_section.dart';

import '../../../test_utils/toast_harness.dart';
import 'fake_backup_sync_service.dart';

Future<FakeBackupSyncService> _pump(WidgetTester tester,
    [FakeBackupSyncService? service]) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = service ?? FakeBackupSyncService();
  await tester.pumpWidget(ProviderScope(
    overrides: [backupSyncServiceProvider.overrideWithValue(fake)],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      home: Scaffold(
        body: SingleChildScrollView(child: BackupSection()),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return fake;
}

FakeBackupSyncService _enabled() => FakeBackupSyncService()
  ..isEnabled = true
  ..keyText = 'ABCD ' * 12 + 'ABCD'
  ..statusNotifier.value = BackupIdle(DateTime.now()
      .subtract(const Duration(minutes: 3))
      .millisecondsSinceEpoch)
  ..membersNotifier.value = const [
    BackupMemberInfo(slotId: 'own', isThisDevice: true),
    BackupMemberInfo(
        slotId: 'tv', isThisDevice: false, deviceName: 'Living Room TV'),
  ];

void main() {
  testWidgets('Off shows the switch, off, and the idle notice', (tester) async {
    await _pump(tester);
    final tile =
        tester.widget<SwitchListTile>(find.byKey(const Key('backup-switch')));
    expect(tile.value, isFalse);
    expect(find.byKey(const Key('backup-unavailable')), findsNothing);
    expect(
        find.text('A backup that goes 180 days without a change is deleted.'),
        findsOneWidget);
    expect(find.byKey(const Key('backup-show-key')), findsNothing);
  });

  testWidgets('Unavailable shows the copy in place of the switch',
      (tester) async {
    final fake = FakeBackupSyncService()
      ..statusNotifier.value = const BackupUnavailable();
    await _pump(tester, fake);
    expect(find.byKey(const Key('backup-switch')), findsNothing);
    expect(find.text("Cloud backup isn't available yet"), findsOneWidget);
  });

  testWidgets('turning on opens the recovery key sheet', (tester) async {
    final fake = await _pump(tester);
    await tester.tap(find.byKey(const Key('backup-switch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-key-text')), findsOneWidget);
    expect(fake.calls, ['prepareEnable']);
    final button = tester.widget<FilledButton>(
        find.byKey(const Key('recovery-key-confirm-button')));
    expect(button.onPressed, isNull);
  });

  testWidgets('enabled shows status, devices and the key actions',
      (tester) async {
    await _pump(tester, _enabled());
    expect(find.text('Last backed up 3 minutes ago'), findsOneWidget);
    expect(find.byKey(const Key('backup-member-own')), findsOneWidget);
    expect(find.text('Living Room TV'), findsOneWidget);
    expect(find.byKey(const Key('backup-member-remove-own')), findsNothing);
    expect(find.byKey(const Key('backup-member-remove-tv')), findsOneWidget);
    expect(find.byKey(const Key('backup-show-key')), findsOneWidget);
    expect(find.byKey(const Key('backup-regenerate-key')), findsOneWidget);
    expect(find.byKey(const Key('backup-delete')), findsOneWidget);
    expect(find.byKey(const Key('backup-no-key')), findsNothing);
  });

  testWidgets('an error keeps the last success in view', (tester) async {
    final fake = _enabled()
      ..statusNotifier.value = BackupError(
          BackupRelayError.network,
          DateTime.now()
              .subtract(const Duration(minutes: 3))
              .millisecondsSinceEpoch);
    await _pump(tester, fake);
    expect(find.text("Can't reach the backup service. It will try again."),
        findsOneWidget);
    expect(find.text('Last backed up 3 minutes ago'), findsOneWidget);
  });

  testWidgets('removing a device asks first', (tester) async {
    final fake = await _pump(tester, _enabled());
    await tester.tap(find.byKey(const Key('backup-member-remove-tv')));
    await tester.pumpAndSettle();
    expect(find.text('Remove Living Room TV from the backup?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-remove-member-confirm')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['removeMember tv']);
    expect(find.byKey(const Key('backup-member-tv')), findsNothing);
  });

  testWidgets('a device that joined by pairing has no key to show',
      (tester) async {
    await _pump(tester, _enabled()..keyText = null);
    expect(find.byKey(const Key('backup-show-key')), findsNothing);
    expect(find.byKey(const Key('backup-no-key')), findsOneWidget);
    expect(find.byKey(const Key('backup-regenerate-key')), findsOneWidget);
  });

  testWidgets('a stored key that no longer works is flagged', (tester) async {
    await _pump(tester, _enabled()..mismatchNotifier.value = true);
    expect(find.byKey(const Key('backup-key-mismatch')), findsOneWidget);
  });

  testWidgets('an unreadable slot names its device', (tester) async {
    await _pump(
        tester,
        _enabled()
          ..names = {'tv': 'Living Room TV'}
          ..unreadableNotifier.value = {'tv'});
    expect(find.text("Couldn't read Living Room TV's backup"), findsOneWidget);
  });

  testWidgets('a new recovery key is confirmed, then shown', (tester) async {
    final fake = await _pump(tester, _enabled());
    await tester.tap(find.byKey(const Key('backup-regenerate-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup-regenerate-confirm')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['regenerateRecoveryKey']);
    expect(find.text(fake.keyText!), findsOneWidget);
  });

  testWidgets('deleting the backup asks first', (tester) async {
    final fake = await _pump(tester, _enabled());
    await tester.tap(find.byKey(const Key('backup-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup-delete-confirm')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['deleteBackup']);
    expect(find.byKey(const Key('backup-delete')), findsNothing);
  });

  testWidgets('turning off asks, then leaves the backup', (tester) async {
    final fake = await _pump(tester, _enabled());
    await tester.tap(find.byKey(const Key('backup-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup-turn-off-confirm')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['disable']);
  });

  testWidgets('the joined notice shows once and not after acknowledgement',
      (tester) async {
    final fake = _enabled()..joinedNoticeNotifier.value = true;
    await _pump(tester, fake);
    expect(find.text('This device is now backed up with your group'),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-joined-notice-dismiss')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['acknowledgeJoinedNotice']);
    expect(find.byKey(const Key('backup-joined-notice')), findsNothing);

    // Mounted again, as on the next visit: still gone.
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, fake);
    expect(find.byKey(const Key('backup-joined-notice')), findsNothing);
  });

  testWidgets('a vault choice offered by pairing opens the dialog',
      (tester) async {
    final fake = await _pump(tester, _enabled());
    fake.vaultChoiceNotifier.value = (current: 'mine', offered: 'group');
    await tester.pumpAndSettle();
    expect(find.text('Which backup should this device keep?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-vault-switch')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['resolveVaultChoice true']);
    expect(find.byKey(const Key('backup-vault-choice-row')), findsNothing);
  });

  testWidgets('a pending vault choice stays as a row until answered',
      (tester) async {
    final fake = _enabled()
      ..vaultChoiceNotifier.value = (current: 'mine', offered: 'group');
    await _pump(tester, fake);
    expect(find.byKey(const Key('backup-vault-choice-row')), findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-vault-choice-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup-vault-keep-current')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['resolveVaultChoice false']);
  });
}
