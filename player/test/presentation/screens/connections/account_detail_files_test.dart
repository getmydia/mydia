import 'dart:typed_data';

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
import 'package:player/core/sources/files/files_scan_controller.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/connections/account_detail_page.dart';

import '../../../core/sources/files/fake_backend.dart';
import '../../../core/sources/files/fake_media_names.dart';
import '../../../core/sources/files/files_fixture.dart';
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';
import '../../../test_utils/toast_harness.dart';

int _boxes = 0;

class _FixedScan extends FilesScanController {
  _FixedScan(super.sourceId, this.fixed);

  final ScanState fixed;

  @override
  ScanState build() => fixed;
}

Future<(InMemorySourceStore, Box<Map<dynamic, dynamic>>)> _pump(
    WidgetTester tester,
    {ScanState? scan,
    String? accountId}) async {
  final box = (await tester.runAsync(() => Hive.openBox<Map<dynamic, dynamic>>(
      'manage_files_${_boxes++}',
      bytes: Uint8List(0))))!;
  final index = FileLibraryIndex(box, accountId: kFilesLocalAccountId);
  await tester.runAsync(() async {
    await index.putRoot(const LibraryRoot(
        id: 'rfilms',
        path: '/media/films',
        kind: FilesLibraryKind.movies,
        title: 'films'));
    await index.putRoot(const LibraryRoot(
        id: 'rshows',
        path: '/media/shows',
        kind: FilesLibraryKind.series,
        title: 'shows'));
  });
  final store = InMemorySourceStore();
  await store.putAccount(filesLocalRecord);
  await tester.binding.setSurfaceSize(const Size(900, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...noHiveOverrides,
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(MockAuthStorage())),
      filesIndexBoxProvider.overrideWithValue(box),
      filesProgressStoreProvider
          .overrideWithValue(InMemoryPlaybackProgressStore()),
      mediaNamesProvider.overrideWithValue(FakeMediaNames()),
      relayTmdbProvider.overrideWithValue(FakeFilesRelay()),
      filesBackendBuilderProvider
          .overrideWithValue((ref, source) => FakeBackend({})),
      if (scan != null)
        filesScanProvider(filesLocalSource.id)
            .overrideWith(() => _FixedScan(filesLocalSource.id, scan)),
    ],
    child: MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: toastLayerBuilder,
      routerConfig: GoRouter(
        initialLocation: '/sources/manage',
        routes: [
          GoRoute(
              path: '/sources/manage',
              builder: (_, __) => Scaffold(
                  body: AccountDetailBody(
                      accountId: accountId ?? filesLocalRecord.account.id))),
          GoRoute(
              path: '/sources/add/files',
              redirect: (_, s) =>
                  filesReauthLocation(s.uri.queryParameters['account'])),
          GoRoute(
              path: '/sources/add/folder',
              builder: (_, __) => const Text('add folder screen')),
        ],
      ),
    ),
  ));
  if (scan?.running ?? false) {
    // A running scan's spinner never settles.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  } else {
    await tester.pumpAndSettle();
  }
  return (store, box);
}

/// Pumps the detail page for [url]'s account, saved through the app.
Future<void> _pumpShare(WidgetTester tester, Uri url) async {
  final smb = url.scheme == 'smb';
  final id = smb ? smbAccountId(url) : webDavAccountId(url);
  await _pump(tester, accountId: id);
  final accounts =
      ProviderScope.containerOf(tester.element(find.byType(AccountDetailBody)))
          .read(filesAccountsProvider);
  if (smb) {
    await accounts.addSmbAccount(
        url: url,
        credentials: const SmbCredentials(user: 'viewer', password: 'pw'));
  } else {
    await accounts.addWebDavAccount(url: url, user: 'viewer', password: 'pw');
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('smb_account_shows_change_address', (tester) async {
    final smbUrl = Uri.parse('smb://192.168.1.5/movies');
    await _pumpShare(tester, smbUrl);
    final smbId = smbAccountId(smbUrl);
    expect(find.byKey(Key('manage-remove-$smbId')), findsOneWidget);
    expect(find.byKey(Key('manage-change-address-$smbId')), findsOneWidget);
  });

  testWidgets('a webdav account has no change address', (tester) async {
    final davUrl = Uri.parse('https://dav.example.test/media');
    await _pumpShare(tester, davUrl);
    final davId = webDavAccountId(davUrl);
    expect(find.byKey(Key('manage-remove-$davId')), findsOneWidget);
    expect(find.byKey(Key('manage-change-address-$davId')), findsNothing);
  });

  testWidgets('the device account has no change address', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('manage-remove-$kFilesLocalAccountId')),
        findsOneWidget);
    expect(find.byKey(const Key('manage-change-address-$kFilesLocalAccountId')),
        findsNothing);
  });

  testWidgets('lists the folders and removes one', (tester) async {
    final (_, box) = await _pump(tester);
    expect(find.byKey(const ValueKey('manage-root-rfilms')), findsOneWidget);
    expect(find.byKey(const ValueKey('manage-root-rshows')), findsOneWidget);
    expect(find.byKey(const ValueKey('manage-rescan-$kFilesLocalAccountId')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('manage-remove-root-rfilms')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('manage-root-rfilms')), findsNothing);
    expect(
        FileLibraryIndex(box, accountId: kFilesLocalAccountId)
            .roots()
            .map((r) => r.id),
        ['rshows']);
  });

  testWidgets('a running scan shows its progress in place of Rescan',
      (tester) async {
    await _pump(tester,
        scan: const ScanState(running: true, walking: true, foldersRead: 12));
    final rescan =
        find.byKey(const ValueKey('manage-rescan-$kFilesLocalAccountId'));
    expect(
        find.descendant(of: rescan, matching: find.text('Reading folders: 12')),
        findsOneWidget);
    expect(find.text('Rescan'), findsNothing);
  });

  testWidgets('removing the account clears its index', (tester) async {
    final (store, box) = await _pump(tester);
    await tester
        .tap(find.byKey(const Key('manage-remove-$kFilesLocalAccountId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-remove-confirm')));
    await tester.pumpAndSettle();

    expect((await store.load()).accounts, isEmpty);
    expect(FileLibraryIndex(box, accountId: kFilesLocalAccountId).roots(),
        isEmpty);
  });

  testWidgets('the device account offers Add folder, which picks a folder',
      (tester) async {
    await _pump(tester);
    final button = find.byKey(const Key('manage-reauth-$kFilesLocalAccountId'));
    expect(find.descendant(of: button, matching: find.text('Add folder')),
        findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('add folder screen'), findsOneWidget);
  });
}
