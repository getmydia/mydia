import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_providers.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/connections/backup_section.dart';

import '../../../test_utils/toast_harness.dart';
import 'fake_backup_controller.dart';
import 'fake_backup_sync_service.dart';

Future<FakeBackupSyncService> _pump(
  WidgetTester tester, [
  FakeBackupSyncService? service,
]) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = service ?? FakeBackupSyncService();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backupSyncServiceProvider.overrideWithValue(fake),
        backupControllerProvider.overrideWithValue(
          FakeBackupController(relay: fake),
        ),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: toastLayerBuilder,
        home: Scaffold(body: SingleChildScrollView(child: BackupSection())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

/// Opens Manage backup, where the devices, the key and Delete live.
Future<void> _manage(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('backup-manage')));
  await tester.pumpAndSettle();
}

FakeBackupSyncService _enabled() => FakeBackupSyncService()
  ..isEnabled = true
  ..keyText = 'ABCD ' * 12 + 'ABCD'
  ..statusNotifier.value = BackupIdle(
    DateTime.now().subtract(const Duration(minutes: 3)).millisecondsSinceEpoch,
  )
  ..membersNotifier.value = const [
    BackupMemberInfo(slotId: 'own', isThisDevice: true),
    BackupMemberInfo(
      slotId: 'tv',
      isThisDevice: false,
      deviceName: 'Living Room TV',
    ),
  ];

void main() {
  testWidgets('Off shows the switch, off, and the idle notice', (tester) async {
    await _pump(tester);
    final tile = tester.widget<SwitchListTile>(
      find.byKey(const Key('backup-switch')),
    );
    expect(tile.value, isFalse);
    expect(find.byKey(const Key('backup-unavailable')), findsNothing);
    expect(
      find.text('A backup that goes 180 days without a change is deleted.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('backup-show-key')), findsNothing);
  });

  testWidgets('Unavailable shows the copy in place of the switch', (
    tester,
  ) async {
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
      find.byKey(const Key('recovery-key-confirm-button')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('enabled keeps devices, key and delete behind Manage backup', (
    tester,
  ) async {
    await _pump(tester, _enabled());
    expect(find.text('Last backed up 3 minutes ago'), findsOneWidget);
    expect(find.byKey(const Key('backup-manage')), findsOneWidget);
    expect(find.text('2 devices'), findsOneWidget);
    for (final key in [
      'backup-member-own',
      'backup-show-key',
      'backup-regenerate-key',
      'backup-delete',
      'backup-idle-notice',
    ]) {
      expect(find.byKey(Key(key)), findsNothing, reason: key);
    }
  });

  testWidgets('Manage backup shows status, devices and the key actions', (
    tester,
  ) async {
    await _pump(tester, _enabled());
    await _manage(tester);
    expect(find.text('Last backed up 3 minutes ago'), findsOneWidget);
    expect(find.byKey(const Key('backup-member-own')), findsOneWidget);
    expect(find.text('Living Room TV'), findsOneWidget);
    expect(find.byKey(const Key('backup-member-remove-own')), findsNothing);
    expect(find.byKey(const Key('backup-member-remove-tv')), findsOneWidget);
    expect(find.byKey(const Key('backup-show-key')), findsOneWidget);
    expect(find.byKey(const Key('backup-regenerate-key')), findsOneWidget);
    expect(find.byKey(const Key('backup-delete')), findsOneWidget);
    expect(find.byKey(const Key('backup-no-key')), findsNothing);
    expect(find.byKey(const Key('backup-idle-notice')), findsOneWidget);
  });

  testWidgets('Off has no Manage backup row', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('backup-manage')), findsNothing);
  });

  testWidgets('a warning stays in view while Manage backup is closed', (
    tester,
  ) async {
    await _pump(tester, _enabled()..mismatchNotifier.value = true);
    expect(find.byKey(const Key('backup-key-mismatch')), findsOneWidget);
    expect(find.byKey(const Key('backup-show-key')), findsNothing);
  });

  testWidgets('the unnamed own device is not labelled twice', (tester) async {
    await _pump(tester, _enabled());
    await _manage(tester);
    expect(
      find.descendant(
        of: find.byKey(const Key('backup-member-own')),
        matching: find.text('This device'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('an error keeps the last success in view', (tester) async {
    final fake = _enabled()
      ..statusNotifier.value = BackupError(
        BackupRelayError.network,
        DateTime.now()
            .subtract(const Duration(minutes: 3))
            .millisecondsSinceEpoch,
      );
    await _pump(tester, fake);
    expect(
      find.text("Can't reach the backup service. It will try again."),
      findsOneWidget,
    );
    expect(find.text('Last backed up 3 minutes ago'), findsOneWidget);
  });

  testWidgets('removing a device asks first, then shows the new recovery key '
      'until acknowledged', (tester) async {
    final fake = await _pump(tester, _enabled());
    await _manage(tester);
    await tester.tap(find.byKey(const Key('backup-member-remove-tv')));
    await tester.pumpAndSettle();
    expect(find.text('Remove Living Room TV from the backup?'), findsOneWidget);
    expect(find.textContaining('replaces your recovery key'), findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-remove-member-confirm')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['removeMember tv']);
    expect(find.byKey(const Key('backup-member-tv')), findsNothing);

    // The replaced key is up, and Back or a tap outside does not close it.
    expect(find.byKey(const Key('recovery-key-replaced')), findsOneWidget);
    expect(find.text(fake.keyText!), findsOneWidget);
    expect(find.byKey(const Key('recovery-key-copy')), findsOneWidget);
    expect(find.byKey(const Key('recovery-key-qr')), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await navigator.maybePop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-key-replaced')), findsOneWidget);
    expect(fake.calls, isNot(contains('acknowledgeNewRecoveryKey')));
    await tester.tap(find.byKey(const Key('recovery-key-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-key-replaced')), findsNothing);
    expect(fake.calls, ['removeMember tv', 'acknowledgeNewRecoveryKey']);
    expect(find.byKey(const Key('backup-unsaved-key')), findsNothing);
  });

  testWidgets(
    'a new recovery key never acknowledged is flagged until Done on its '
    'sheet',
    (tester) async {
      final fake = _enabled()..unsavedKeyNotifier.value = true;
      await _pump(tester, fake);
      expect(find.byKey(const Key('backup-unsaved-key')), findsOneWidget);
      expect(
        find.text('Your recovery key was replaced. Save the new one.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('backup-unsaved-key-show')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recovery-key-replaced')), findsOneWidget);
      expect(find.text(fake.keyText!), findsOneWidget);
      // Not dismissable: a tap outside leaves it up and acknowledges nothing.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recovery-key-replaced')), findsOneWidget);
      expect(fake.calls, isEmpty);

      await tester.tap(find.byKey(const Key('recovery-key-done')));
      await tester.pumpAndSettle();
      expect(fake.calls, ['acknowledgeNewRecoveryKey']);
      expect(find.byKey(const Key('backup-unsaved-key')), findsNothing);
    },
  );

  testWidgets('a revoked device still in the backup is flagged with Remove', (
    tester,
  ) async {
    final fake = _enabled()
      ..removalsNotifier.value = const [
        PendingRemoval(
          nodeId: 'node-tv',
          slotId: 'tv',
          deviceName: 'Living Room TV',
        ),
      ];
    await _pump(tester, fake);
    expect(
      find.text(
        'Living Room TV was removed from your devices but can still '
        'read your backup',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('backup-pending-removal-remove-tv')));
    await tester.pumpAndSettle();
    expect(find.text('Remove Living Room TV from the backup?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-remove-member-confirm')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['removeMember tv']);
    await tester.tap(find.byKey(const Key('recovery-key-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('backup-pending-removal-tv')), findsNothing);
  });

  testWidgets('a device that joined by pairing has no key to show', (
    tester,
  ) async {
    await _pump(tester, _enabled()..keyText = null);
    await _manage(tester);
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
        ..unreadableNotifier.value = {'tv'},
    );
    expect(find.text("Couldn't read Living Room TV's backup"), findsOneWidget);
  });

  testWidgets('a new recovery key is confirmed, then shown', (tester) async {
    final fake = await _pump(tester, _enabled());
    await _manage(tester);
    await tester.tap(find.byKey(const Key('backup-regenerate-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup-regenerate-confirm')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['regenerateRecoveryKey']);
    expect(find.text(fake.keyText!), findsOneWidget);
  });

  testWidgets('deleting the backup asks first', (tester) async {
    final fake = await _pump(tester, _enabled());
    await _manage(tester);
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

  testWidgets('the joined notice shows once and not after acknowledgement', (
    tester,
  ) async {
    final fake = _enabled()..joinedNoticeNotifier.value = true;
    await _pump(tester, fake);
    expect(
      find.text('This device is now backed up with your group'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('backup-joined-notice-dismiss')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['acknowledgeJoinedNotice']);
    expect(find.byKey(const Key('backup-joined-notice')), findsNothing);

    // Mounted again, as on the next visit: still gone.
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, fake);
    expect(find.byKey(const Key('backup-joined-notice')), findsNothing);
  });

  testWidgets('a vault choice offered by pairing opens the dialog', (
    tester,
  ) async {
    final fake = await _pump(tester, _enabled());
    fake.vaultChoiceNotifier.value = (current: 'mine', offered: 'group');
    await tester.pumpAndSettle();
    expect(find.text('Which backup should this device keep?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('backup-vault-switch')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['resolveVaultChoice true']);
    expect(find.byKey(const Key('backup-vault-choice-row')), findsNothing);
  });

  testWidgets('a pending vault choice stays as a row until answered', (
    tester,
  ) async {
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
