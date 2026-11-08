import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/widgets/files/remote_folder_picker.dart';

import '../../../core/sources/files/fake_backend.dart';

Future<void> _pump(
    WidgetTester tester, FakeBackend backend, List<String> picked) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: RemoteFolderPicker(
            backend: backend, root: '/', onPicked: picked.add),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('walks into a folder, back up, and picks the open one',
      (tester) async {
    final picked = <String>[];
    await _pump(tester, FakeBackend({'/A/B/x.mkv': 1, '/A/f.mkv': 1}), picked);

    expect(find.text('A'), findsOneWidget);
    final up = find.byKey(const Key('folder-picker-up'));
    expect(tester.widget<IconButton>(up).onPressed, isNull);

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
    expect(find.text('f.mkv'), findsNothing);
    expect(tester.widget<IconButton>(up).onPressed, isNotNull);

    await tester.tap(find.text('This folder'));
    expect(picked, ['/A']);

    await tester.tap(up);
    await tester.pumpAndSettle();
    expect(find.text('A'), findsOneWidget);
    expect(tester.widget<IconButton>(up).onPressed, isNull);
  });

  for (final (failure, text) in <(BackendFailure, String)>[
    (const BackendUnauthorized(), 'Wrong user or password.'),
    (
      const BackendNotFound(),
      'That shared folder no longer exists on this server.'
    ),
    (const BackendPermissionLost(), "This account can't open that folder."),
    (const BackendUnreachable(), "Can't reach the server."),
  ]) {
    testWidgets('a ${failure.runtimeType} has its own message', (tester) async {
      final backend = FakeBackend({'/f.mkv': 1})..failures['/'] = failure;
      await _pump(tester, backend, []);
      expect(
        tester.widget<Text>(find.byKey(const Key('folder-picker-error'))).data,
        text,
      );
    });
  }

  testWidgets('shows the empty text when a folder has no subfolders',
      (tester) async {
    await _pump(tester, FakeBackend({'/f.mkv': 1}), []);
    expect(find.byKey(const Key('folder-picker-empty')), findsOneWidget);
  });
}
