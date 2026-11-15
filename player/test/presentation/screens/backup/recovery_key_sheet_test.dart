import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/recovery_key.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/backup/recovery_key_sheet.dart';

import '../../../test_utils/toast_harness.dart';
import 'fake_backup_sync_service.dart';

RecoveryKey _key(int fill) => RecoveryKey.fromBytes(List.filled(32, fill));

/// Opens the enable sheet from a button, so its result can be read.
Future<List<bool>> _open(
    WidgetTester tester, FakeBackupSyncService fake) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final results = <bool>[];
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: toastLayerBuilder,
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          key: const Key('open'),
          onPressed: () async =>
              results.add(await showEnableBackupSheet(context, fake)),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
  return results;
}

final _savedBox = find.byKey(const Key('recovery-key-saved-checkbox'));

FilledButton _confirm(WidgetTester tester) => tester
    .widget<FilledButton>(find.byKey(const Key('recovery-key-confirm-button')));

void main() {
  testWidgets('shows 13 groups of 4 and a QR code', (tester) async {
    final key = _key(7);
    await _open(tester, FakeBackupSyncService()..keys.add(key));
    expect(find.text(key.display), findsOneWidget);
    expect(key.display.split(' '), hasLength(13));
    expect(key.display.split(' ').every((g) => g.length == 4), isTrue);
    expect(find.byKey(const Key('recovery-key-qr')), findsOneWidget);
    expect(find.byKey(const Key('recovery-key-copy')), findsOneWidget);
  });

  testWidgets('turn on stays disabled until the saved box is ticked',
      (tester) async {
    final key = _key(42);
    final fake = FakeBackupSyncService()..keys.add(key);
    final results = await _open(tester, fake);
    expect(_confirm(tester).onPressed, isNull);

    await tester.tap(_savedBox);
    await tester.pump();
    expect(_confirm(tester).onPressed, isNotNull);

    // Unticking takes it back.
    await tester.tap(_savedBox);
    await tester.pump();
    expect(_confirm(tester).onPressed, isNull);

    await tester.tap(_savedBox);
    await tester.pump();

    await tester.tap(find.byKey(const Key('recovery-key-confirm-button')));
    await tester.pumpAndSettle();
    expect(fake.calls, ['prepareEnable', 'confirmEnable ${key.display}']);
    expect(results, [true]);
  });

  testWidgets('a failed turn-on shows a new key to save', (tester) async {
    final first = _key(1);
    final second = _key(2);
    final fake = FakeBackupSyncService()
      ..keys.addAll([first, second])
      ..confirmError = const BackupRelayException(BackupRelayError.server);
    final results = await _open(tester, fake);
    await tester.tap(_savedBox);
    await tester.pump();
    await tester.tap(find.byKey(const Key('recovery-key-confirm-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('recovery-key-retry')), findsOneWidget);
    expect(find.text(second.display), findsOneWidget);
    expect(find.text(first.display), findsNothing);
    expect(_confirm(tester).onPressed, isNull,
        reason: 'the new key has to be confirmed as saved again');
    expect(tester.widget<CheckboxListTile>(_savedBox).value, isFalse);
    expect(results, isEmpty);
  });

  testWidgets('a failure after relay is enabled keeps the same key',
      (tester) async {
    final first = _key(1);
    final second = _key(2);
    final fake = FakeBackupSyncService()
      ..keys.addAll([first, second])
      ..enableBeforeConfirmError = true
      ..confirmError = const BackupRelayException(BackupRelayError.server);
    final results = await _open(tester, fake);
    await tester.tap(_savedBox);
    await tester.pump();
    await tester.tap(find.byKey(const Key('recovery-key-confirm-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('recovery-key-retry')), findsOneWidget);
    expect(find.text(first.display), findsOneWidget);
    expect(find.text(second.display), findsNothing);
    expect(fake.calls, ['prepareEnable', 'confirmEnable ${first.display}']);

    await tester.tap(find.byKey(const Key('recovery-key-confirm-button')));
    await tester.pumpAndSettle();
    expect(fake.calls.last, 'confirmEnable ${first.display}');
    expect(results, [true]);
  });

  testWidgets('a copied key is cleared from the clipboard on close',
      (tester) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      } else if (call.method == 'Clipboard.getData') {
        return {'text': clipboard};
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = _key(3);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            key: const Key('open'),
            onPressed: () => showRecoveryKeySheet(context, key.display),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('recovery-key-copy')));
    await tester.pump();
    expect(clipboard, key.display);
    expect(
        find.text('Recovery key copied. Keep it somewhere safe, like a '
            'password manager.'),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('recovery-key-done')));
    await tester.pumpAndSettle();
    expect(find.byType(RecoveryKeySheet), findsNothing);
    // The clear goes through the platform channel's own async hops.
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(clipboard, '');
  });

  testWidgets('a clipboard the viewer changed since is left alone',
      (tester) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      } else if (call.method == 'Clipboard.getData') {
        return {'text': clipboard};
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final key = _key(4);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      home: Scaffold(body: RecoveryKeySheet.show(keyText: key.display)),
    ));
    await tester.tap(find.byKey(const Key('recovery-key-copy')));
    await tester.pump();
    clipboard = 'something else';
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(clipboard, 'something else');
  });

  testWidgets('show mode only displays the key', (tester) async {
    final key = _key(9);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      home: Scaffold(body: RecoveryKeySheet.show(keyText: key.display)),
    ));
    await tester.pumpAndSettle();
    expect(find.text(key.display), findsOneWidget);
    expect(_savedBox, findsNothing);
    expect(find.byKey(const Key('recovery-key-done')), findsOneWidget);
  });
}
