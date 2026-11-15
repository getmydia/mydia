import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/backup/backup_providers.dart';
import 'package:player/core/backup/recovery_key.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/backup/restore_backup_screen.dart';

import '../../../core/backup/fake_backup_relay.dart';
import '../../../test_utils/toast_harness.dart';
import 'backup_device_rig.dart';

/// A vault made by [tv], with one account and two watch records, and a
/// fresh install ([fresh]) to restore it onto.
Future<(BackupTestDevice, BackupTestDevice, RecoveryKey)> _vault() async {
  final relay = FakeBackupRelay();
  final tv = BackupTestDevice(relay, 'Living Room TV');
  await tv.sources.putAccount(testPlexAccount('p1', 'Night Harbor Plex'));
  await tv.sync.setWatched('tmdb:movie:1', true, nowMs: 1000);
  await tv.sync.setWatched('tmdb:movie:2', true, nowMs: 1000);
  final key = await tv.enable();
  final fresh = BackupTestDevice(relay, 'Night Harbor Laptop');
  await fresh.service.start();
  return (tv, fresh, key);
}

Future<void> _pump(WidgetTester tester, BackupTestDevice device) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: restoreBackupLocation,
    routes: [
      GoRoute(path: '/', builder: (_, __) => const SizedBox(key: Key('home'))),
      GoRoute(
        path: restoreBackupLocation,
        builder: (_, __) => const RestoreBackupScreen(),
      ),
    ],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [backupSyncServiceProvider.overrideWithValue(device.service)],
    child: MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      routerConfig: router,
    ),
  ));
  await tester.pumpAndSettle();
}

Future<(BackupTestDevice, BackupTestDevice, RecoveryKey)> _setUp(
    WidgetTester tester) async {
  final rig = (await tester.runAsync(_vault))!;
  addTearDown(() {
    rig.$1.dispose();
    rig.$2.dispose();
  });
  return rig;
}

void main() {
  testWidgets('a malformed key is rejected inline, without the relay',
      (tester) async {
    final (tv, fresh, _) = await _setUp(tester);
    await _pump(tester, fresh);
    final before = tv.relay.requests.length;

    await tester.enterText(
        find.byKey(const Key('restore-key-field')), 'not a key');
    await tester.tap(find.byKey(const Key('restore-find-button')));
    await tester.pumpAndSettle();

    expect(
        find.text(
            "That isn't a recovery key. It has 52 letters and digits in groups of four."),
        findsOneWidget);
    expect(tv.relay.requests.length, before);
  });

  testWidgets('a key with no backup says so', (tester) async {
    final (_, fresh, _) = await _setUp(tester);
    await _pump(tester, fresh);

    await tester.enterText(find.byKey(const Key('restore-key-field')),
        RecoveryKey.generate().display);
    await tester.tap(find.byKey(const Key('restore-find-button')));
    await settleEngine(tester,
        until: () =>
            find.byKey(const Key('restore-error')).evaluate().isNotEmpty);

    expect(find.text('No backup matches this key'), findsOneWidget);
  });

  testWidgets('the summary shows before Restore, which then restores',
      (tester) async {
    final (_, fresh, key) = await _setUp(tester);
    await _pump(tester, fresh);

    await tester.enterText(
        find.byKey(const Key('restore-key-field')), key.display.toLowerCase());
    await tester.tap(find.byKey(const Key('restore-find-button')));
    await settleEngine(tester,
        until: () =>
            find.byKey(const Key('restore-summary')).evaluate().isNotEmpty);

    expect(
        find.text('1 source, 2 watch records, from 1 device'), findsOneWidget);
    expect(find.text('Living Room TV'), findsOneWidget);
    // Nothing is applied before Restore is pressed.
    expect(fresh.putAccounts, isEmpty);
    expect(fresh.service.enabled, isFalse);

    await tester.tap(find.byKey(const Key('restore-confirm-button')));
    await settleEngine(tester,
        until: () => find.byKey(const Key('home')).evaluate().isNotEmpty);

    expect(fresh.putAccounts, ['p1']);
    expect(fresh.service.enabled, isTrue);
    expect(find.byKey(const Key('home')), findsOneWidget);

    // The joined service polls on a timer, and the toast times out: both
    // live in the test's fake time, so end them inside the test.
    fresh.dispose();
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a device already in a backup cannot restore another',
      (tester) async {
    final (tv, _, _) = await _setUp(tester);
    await _pump(tester, tv);
    expect(find.byKey(const Key('restore-already-on')), findsOneWidget);
    expect(find.byKey(const Key('restore-key-field')), findsNothing);
  });
}
