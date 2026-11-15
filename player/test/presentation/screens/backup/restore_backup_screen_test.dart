import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/backup/backup_providers.dart';
import 'package:player/core/backup/backup_records.dart';
import 'package:player/core/backup/cloud/cloud_backup_service.dart';
import 'package:player/core/backup/recovery_key.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/backup/google_device_code_sheet.dart';
import 'package:player/presentation/screens/backup/restore_backup_screen.dart';

import '../../../core/backup/fake_backup_relay.dart';
import '../../../test_utils/toast_harness.dart';
import 'backup_device_rig.dart';
import 'fake_backup_controller.dart';

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
    overrides: [
      backupSyncServiceProvider.overrideWithValue(device.service),
      // Only the relay is offered: the screen opens on the key entry.
      backupControllerProvider
          .overrideWithValue(FakeBackupController(relay: device.service)),
    ],
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
    expect(
        find.text('This device is already in a backup. Turn backup off in '
            'Servers & devices to restore another one.'),
        findsOneWidget);
    expect(find.byKey(const Key('restore-key-field')), findsNothing);
  });

  testWidgets('backup turning on after the preview says so, not an error',
      (tester) async {
    final (_, fresh, key) = await _setUp(tester);
    await _pump(tester, fresh);
    await tester.enterText(
        find.byKey(const Key('restore-key-field')), key.display);
    await tester.tap(find.byKey(const Key('restore-find-button')));
    await settleEngine(tester,
        until: () =>
            find.byKey(const Key('restore-summary')).evaluate().isNotEmpty);

    // Pairing, say, turned backup on meanwhile.
    await tester.runAsync(fresh.enable);
    await tester.pump();

    expect(find.byKey(const Key('restore-already-on')), findsOneWidget);
    expect(find.byKey(const Key('restore-confirm-button')), findsNothing);
    expect(find.byKey(const Key('restore-error')), findsNothing);
    fresh.dispose();
    await tester.pump(const Duration(seconds: 10));
  });

  group('cloud stores', () {
    const all = {
      BackupStoreKind.relay,
      BackupStoreKind.icloud,
      BackupStoreKind.gdrive,
    };
    const watched = [
      WatchBackupRecord(key: 'watch:tmdb:movie:1', watched: true, updatedAt: 1),
      WatchBackupRecord(key: 'watch:tmdb:movie:2', watched: true, updatedAt: 1),
    ];

    testWidgets('restore_screen_shows_three_entries_on_apple_two_elsewhere',
        (tester) async {
      await _pumpCloud(tester, FakeBackupController(offered: all));
      expect(find.byKey(const Key('restore-entry-icloud')), findsOneWidget);
      expect(find.byKey(const Key('restore-entry-gdrive')), findsOneWidget);
      expect(find.byKey(const Key('restore-entry-key')), findsOneWidget);
      expect(find.text('Restore from iCloud'), findsOneWidget);
      expect(find.text('Restore from Google Drive'), findsOneWidget);
      expect(find.text('Restore with a recovery key'), findsOneWidget);
      expect(find.byKey(const Key('restore-key-field')), findsNothing);

      await _pumpCloud(
          tester,
          FakeBackupController(
              offered: const {BackupStoreKind.relay, BackupStoreKind.gdrive}));
      expect(find.byKey(const Key('restore-entry-icloud')), findsNothing);
      expect(find.byKey(const Key('restore-entry-gdrive')), findsOneWidget);
      expect(find.byKey(const Key('restore-entry-key')), findsOneWidget);

      await tester.tap(find.byKey(const Key('restore-entry-key')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('restore-key-field')), findsOneWidget);
    });

    testWidgets('iCloud shows the summary, then restores', (tester) async {
      final c = FakeBackupController(offered: all);
      c.clouds[BackupStoreKind.icloud]!.preview = fakeCloudPreview(watched);
      await _pumpCloud(tester, c);

      await tester.tap(find.byKey(const Key('restore-entry-icloud')));
      await tester.pumpAndSettle();
      expect(find.text('0 sources, 2 watch records, from 1 device'),
          findsOneWidget);
      expect(find.text('Living Room TV'), findsOneWidget);
      expect(c.calls, ['previewRestore icloud']);

      await tester.tap(find.byKey(const Key('restore-confirm-button')));
      await tester.pumpAndSettle();
      expect(c.calls, ['previewRestore icloud', 'commitRestore icloud']);
      expect(find.byKey(const Key('home')), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('Google Drive signs in first', (tester) async {
      final c = FakeBackupController(offered: all);
      c.clouds[BackupStoreKind.gdrive]!.preview = fakeCloudPreview(watched);
      await _pumpCloud(tester, c, google: FakeGoogleSignIn(c.calls));

      await tester.tap(find.byKey(const Key('restore-entry-gdrive')));
      await tester.pumpAndSettle();

      expect(c.calls, ['signIn', 'previewRestore gdrive']);
      expect(find.byKey(const Key('restore-summary')), findsOneWidget);
    });

    testWidgets('a store with nothing readable offers no Restore',
        (tester) async {
      final c = FakeBackupController(offered: all);
      c.clouds[BackupStoreKind.icloud]!.preview =
          fakeCloudPreview(const [], unreadable: {'tv'});
      await _pumpCloud(tester, c);

      await tester.tap(find.byKey(const Key('restore-entry-icloud')));
      await tester.pumpAndSettle();

      expect(find.text('0 sources, 0 watch records, from 0 devices'),
          findsOneWidget);
      expect(
          find.text('Nothing could be read from this backup.'), findsOneWidget);
      expect(find.byKey(const Key('restore-confirm-button')), findsNothing);
    });

    testWidgets('an empty store says no backup was found', (tester) async {
      final c = FakeBackupController(offered: all);
      await _pumpCloud(tester, c);

      await tester.tap(find.byKey(const Key('restore-entry-icloud')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('restore-error')), findsOneWidget);
    });

    testWidgets('a device backing up to a cloud store cannot restore',
        (tester) async {
      await _pumpCloud(tester,
          FakeBackupController(offered: all, active: BackupStoreKind.gdrive));
      expect(find.byKey(const Key('restore-already-on')), findsOneWidget);
      expect(find.byKey(const Key('restore-entry-icloud')), findsNothing);
    });

    testWidgets('the store link opens straight on its summary', (tester) async {
      final c = FakeBackupController(offered: all);
      c.clouds[BackupStoreKind.icloud]!.preview = fakeCloudPreview(watched);
      await _pumpCloud(tester, c, initialStore: BackupStoreKind.icloud);

      expect(find.byKey(const Key('restore-summary')), findsOneWidget);
    });

    testWidgets('double tapping Google Drive ignores re-entry while signing in',
        (tester) async {
      final waiter = Completer<void>();
      final c = FakeBackupController(offered: all);
      c.clouds[BackupStoreKind.gdrive]!.preview = fakeCloudPreview(watched);
      final google = FakeGoogleSignIn(c.calls)..signInWaiter = waiter;
      await _pumpCloud(tester, c, google: google);

      await tester.tap(find.byKey(const Key('restore-entry-gdrive')));
      await tester.pump();
      expect(c.calls, ['signIn']);

      await tester.tap(find.byKey(const Key('restore-entry-gdrive')));
      await tester.pump();
      expect(c.calls, ['signIn']);

      waiter.complete();
      await tester.pumpAndSettle();
      expect(c.calls, ['signIn', 'previewRestore gdrive']);
      expect(find.byKey(const Key('restore-summary')), findsOneWidget);
    });

    testWidgets('key entry offers Back when cloud stores are offered',
        (tester) async {
      final c = FakeBackupController(offered: all);
      await _pumpCloud(tester, c);

      await tester.tap(find.byKey(const Key('restore-entry-key')));
      await tester.pumpAndSettle();

      final back = find.byKey(const Key('restore-key-back'));
      expect(back, findsOneWidget);
      await tester.tap(back);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('restore-entry-gdrive')), findsOneWidget);
    });
  });

  group('login', () {
    testWidgets('login_offers_icloud_restore_when_slots_exist', (tester) async {
      final c = FakeBackupController(
          offered: const {BackupStoreKind.relay, BackupStoreKind.icloud});
      c.clouds[BackupStoreKind.icloud]!.preview = fakeCloudPreview(const [
        WatchBackupRecord(key: 'watch:a', watched: true, updatedAt: 1),
      ]);
      await _pumpLoginButton(tester, c, apple: true);

      expect(find.byKey(const Key('restore-from-icloud')), findsOneWidget);
      expect(find.text('Restore from iCloud'), findsOneWidget);
      expect(c.calls, ['previewRestore icloud']);
    });

    testWidgets('no iCloud slots, no button', (tester) async {
      final c = FakeBackupController(
          offered: const {BackupStoreKind.relay, BackupStoreKind.icloud});
      await _pumpLoginButton(tester, c, apple: true);

      expect(find.byKey(const Key('restore-from-icloud')), findsNothing);
    });

    testWidgets('a slow iCloud gives up after 5 s', (tester) async {
      final c = FakeBackupController(
          offered: const {BackupStoreKind.relay, BackupStoreKind.icloud});
      c.clouds[BackupStoreKind.icloud]!.preview =
          Completer<CloudRestorePreview>();
      await _pumpLoginButton(tester, c, apple: true, settle: false);
      await tester.pump(const Duration(seconds: 6));

      expect(find.byKey(const Key('restore-from-icloud')), findsNothing);
    });

    testWidgets('elsewhere the store is never probed', (tester) async {
      final c = FakeBackupController(
          offered: const {BackupStoreKind.relay, BackupStoreKind.icloud});
      c.clouds[BackupStoreKind.icloud]!.preview = fakeCloudPreview(const [
        WatchBackupRecord(key: 'watch:a', watched: true, updatedAt: 1),
      ]);
      await _pumpLoginButton(tester, c, apple: false);

      expect(find.byKey(const Key('restore-from-icloud')), findsNothing);
      expect(c.calls, isEmpty);
    });
  });
}

Future<void> _pumpCloud(
  WidgetTester tester,
  FakeBackupController controller, {
  FakeGoogleSignIn? google,
  BackupStoreKind? initialStore,
}) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    initialLocation: restoreBackupLocation,
    routes: [
      GoRoute(path: '/', builder: (_, __) => const SizedBox(key: Key('home'))),
      GoRoute(
        path: restoreBackupLocation,
        builder: (_, __) => RestoreBackupScreen(initialStore: initialStore),
      ),
    ],
  );
  // A fresh scope each pump, so one test can compare two set-ups.
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(ProviderScope(
    overrides: [
      backupSyncServiceProvider.overrideWithValue(controller.relay),
      backupControllerProvider.overrideWithValue(controller),
      googleSignInMethodProvider.overrideWithValue(google?.method),
    ],
    child: MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      routerConfig: router,
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _pumpLoginButton(
  WidgetTester tester,
  FakeBackupController controller, {
  required bool apple,
  bool settle = true,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      backupControllerProvider.overrideWithValue(controller),
      appleBackupPlatformProvider.overrideWithValue(apple),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: RestoreFromICloudButton())),
    ),
  ));
  if (settle) await tester.pumpAndSettle();
}
