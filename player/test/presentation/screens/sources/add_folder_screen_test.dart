import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/router/app_router.dart' show filesReauthLocation;
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_accounts.dart';
import 'package:player/core/sources/files/files_providers.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/sources/add_folder_screen.dart';
import 'package:player/presentation/screens/sources/add_source_screen.dart';

import '../../../core/sources/files/fake_backend.dart';
import '../../../core/sources/files/fake_media_names.dart';
import '../../../core/sources/files/files_fixture.dart';
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';

void main() {
  group('folder_tile_hidden_on_mobile_and_web', () {
    Future<void> pumpAdd(WidgetTester tester, {bool isWeb = false}) =>
        tester.pumpWidget(ProviderScope(
          overrides: [hasMydiaProvider.overrideWithValue(false)],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AddSourceScreen(isWeb: isWeb),
          ),
        ));

    for (final platform in [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    ]) {
      testWidgets('shown on ${platform.name}', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        await pumpAdd(tester);
        expect(find.byKey(const Key('add-source-folder')), findsOneWidget);
        expect(find.byKey(const Key('add-source-webdav')), findsOneWidget);
        debugDefaultTargetPlatformOverride = null;
      });
    }

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('hidden on ${platform.name}', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        await pumpAdd(tester);
        expect(find.byKey(const Key('add-source-folder')), findsNothing);
        expect(find.byKey(const Key('add-source-webdav')), findsOneWidget);
        debugDefaultTargetPlatformOverride = null;
      });
    }

    testWidgets('neither on web', (tester) async {
      await pumpAdd(tester, isWeb: true);
      expect(find.byKey(const Key('add-source-folder')), findsNothing);
      expect(find.byKey(const Key('add-source-webdav')), findsNothing);
    });
  });

  test('signing a files account in again picks the right form', () {
    expect(filesReauthLocation(kFilesLocalAccountId), '/sources/add/folder');
    expect(filesReauthLocation('wabc'), '/sources/add/webdav?account=wabc');
  });

  testWidgets('picks a folder and adds it with its kind', (tester) async {
    final box = (await tester.runAsync(() =>
        Hive.openBox<Map<dynamic, dynamic>>('add_folder_screen',
            bytes: Uint8List(0))))!;
    final store = InMemorySourceStore();
    final router = GoRouter(
      initialLocation: '/add',
      routes: [
        GoRoute(path: '/add', builder: (_, __) => const AddFolderScreen()),
        GoRoute(
            path: '/s/:id',
            builder: (_, s) => Text('opened ${s.pathParameters['id']}')),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
        filesIndexBoxProvider.overrideWithValue(box),
        filesProgressStoreProvider
            .overrideWithValue(InMemoryPlaybackProgressStore()),
        mediaNamesProvider.overrideWithValue(FakeMediaNames()),
        relayTmdbProvider.overrideWithValue(FakeFilesRelay()),
        filesBackendBuilderProvider
            .overrideWithValue((ref, source) => FakeBackend({})),
        directoryPickerProvider
            .overrideWithValue(() async => '/home/viewer/Films'),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();

    final save = find.byKey(const Key('add-folder-save'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.tap(find.byKey(const Key('add-folder-choose')));
    await tester.pumpAndSettle();
    expect(find.text('/home/viewer/Films'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-folder-kind')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('files-kind-movies')).last);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    final record = (await store.load()).accounts.single;
    expect(record.account.id, kFilesLocalAccountId);
    expect(record.account.kind, SourceKind.files);
    expect(record.account.displayName, 'This device');
    final root =
        FileLibraryIndex(box, accountId: kFilesLocalAccountId).roots().single;
    expect(root.path, '/home/viewer/Films');
    expect(root.id, filesRootId('/home/viewer/Films'));
    expect(root.title, 'Films');
    expect(root.kind, FilesLibraryKind.movies);
    expect(find.text('opened $kFilesLocalAccountId:owner:$kFilesLocalServerId'),
        findsOneWidget);
  });

  testWidgets('selects the folder even when the screen left mid-save',
      (tester) async {
    final gate = Completer<void>();
    final router = GoRouter(
      initialLocation: '/add',
      routes: [
        GoRoute(path: '/add', builder: (_, __) => const AddFolderScreen()),
        GoRoute(path: '/elsewhere', builder: (_, __) => const Text('away')),
        GoRoute(path: '/s/:id', builder: (_, __) => const Text('opened')),
      ],
    );
    final container = ProviderContainer(overrides: [
      filesAccountsProvider.overrideWith((ref) => _GatedAccounts(ref, gate)),
      directoryPickerProvider.overrideWithValue(() async => '/media/films'),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-folder-choose')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-folder-save')));
    await tester.pump();

    router.go('/elsewhere');
    await tester.pumpAndSettle();
    expect(find.byType(AddFolderScreen), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(container.read(selectedSourceIdProvider), _GatedAccounts.id);
    expect(find.text('away'), findsOneWidget);
  });
}

/// Adds nothing, and answers only once [gate] completes.
class _GatedAccounts extends FilesAccounts {
  _GatedAccounts(super.ref, this.gate);

  static const id = SourceId('$kFilesLocalAccountId:owner:local');
  final Completer<void> gate;

  @override
  Future<SourceId> addLocalRoot({
    required String path,
    required FilesLibraryKind kind,
    required String accountName,
  }) async {
    await gate.future;
    return id;
  }
}
