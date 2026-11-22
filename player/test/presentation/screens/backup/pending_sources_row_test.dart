import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/backup/pending_sources_row.dart';

import '../../../core/backup/fake_backup_relay.dart';
import '../../../test_utils/toast_harness.dart';
import 'backup_device_rig.dart';

/// Device [tv] backs up an account that [laptop], already in the vault,
/// does not have: [laptop] is offered it.
Future<(BackupTestDevice, BackupTestDevice)> _offered() async {
  final relay = FakeBackupRelay();
  final tv = BackupTestDevice(relay, 'Living Room TV');
  final laptop = BackupTestDevice(relay, 'Night Harbor Laptop');
  final key = await tv.enable();
  await laptop.join(key);
  await tv.sources.putAccount(testPlexAccount('p1', 'Night Harbor Plex'));
  await tv.upload();
  await laptop.service.poll();
  return (tv, laptop);
}

Future<void> _pump(WidgetTester tester, BackupTestDevice device) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      home: Scaffold(body: PendingSourcesRow(service: device.service)),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('lists the device the sources came from; Add adds them', (
    tester,
  ) async {
    final (tv, laptop) = (await tester.runAsync(_offered))!;
    addTearDown(() {
      tv.dispose();
      laptop.dispose();
    });
    await _pump(tester, laptop);

    expect(find.text('1 source added on Living Room TV'), findsOneWidget);
    expect(find.text('Night Harbor Plex'), findsOneWidget);

    await tester.tap(find.byKey(const Key('backup-pending-add')));
    await settleEngine(
      tester,
      until: () => laptop.service.pendingOffers.value.isEmpty,
    );

    expect(laptop.putAccounts, ['p1']);
    expect(
      find.byKey(const Key('backup-pending-Living Room TV')),
      findsNothing,
    );
  });

  testWidgets('Dismiss forgets the offer', (tester) async {
    final (tv, laptop) = (await tester.runAsync(_offered))!;
    addTearDown(() {
      tv.dispose();
      laptop.dispose();
    });
    await _pump(tester, laptop);

    await tester.tap(find.byKey(const Key('backup-pending-dismiss')));
    await settleEngine(
      tester,
      until: () => laptop.service.pendingOffers.value.isEmpty,
    );

    expect(laptop.putAccounts, isEmpty);
    expect(
      find.byKey(const Key('backup-pending-Living Room TV')),
      findsNothing,
    );
    expect(laptop.meta.pendingAccounts(), isEmpty);
  });
}
