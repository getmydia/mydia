import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/widgets/files/remote_folder_picker.dart';

import '../../../core/sources/files/fake_backend.dart';

Future<void> _pump(
  WidgetTester tester,
  FileSystemBackend backend,
  List<String> picked, {
  String root = '/',
  VoidCallback? onExit,
}) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: RemoteFolderPicker(
          backend: backend, root: root, onPicked: picked.add, onExit: onExit),
    ),
  ));
  await tester.pumpAndSettle();
}

/// A listing that also names a folder elsewhere on the server, as a WebDAV
/// href outside the base can.
class _StrayBackend extends FakeBackend {
  _StrayBackend(super.files);

  @override
  Future<List<FileEntry>> list(String dir) async => [
        ...await super.list(dir),
        FileEntry(
          path: '/elsewhere',
          name: 'elsewhere',
          isDir: true,
          size: 0,
          modified: FakeBackend.defaultModified,
        ),
      ];
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

  testWidgets('the root cannot be picked until it has listed', (tester) async {
    final picked = <String>[];
    final backend = FakeBackend({'/A/f.mkv': 1})
      ..failures['/'] = const BackendUnreachable();
    await _pump(tester, backend, picked);
    await tester.tap(find.text('This folder'));
    expect(picked, isEmpty);
  });

  testWidgets('folders outside the root get no row', (tester) async {
    await _pump(tester, _StrayBackend({'/dav/A/f.mkv': 1}), [], root: '/dav');
    expect(find.text('A'), findsOneWidget);
    expect(find.text('elsewhere'), findsNothing);
  });

  testWidgets('with onExit, back at the root calls it and stays',
      (tester) async {
    var exits = 0;
    await _pump(tester, FakeBackend({'/A/f.mkv': 1}), [],
        onExit: () => exits++);
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));

    await navigator.maybePop();
    await tester.pumpAndSettle();
    expect(exits, 0, reason: 'a subfolder climbs first');
    expect(find.text('A'), findsOneWidget);

    await navigator.maybePop();
    await tester.pumpAndSettle();
    expect(exits, 1);
    expect(find.byType(RemoteFolderPicker), findsOneWidget);
  });

  testWidgets('shows the empty text when a folder has no subfolders',
      (tester) async {
    await _pump(tester, FakeBackend({'/f.mkv': 1}), []);
    expect(find.byKey(const Key('folder-picker-empty')), findsOneWidget);
  });
}
