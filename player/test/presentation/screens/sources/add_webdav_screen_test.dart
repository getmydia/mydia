import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_accounts.dart';
import 'package:player/core/sources/files/files_providers.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/sources/add_webdav_screen.dart';

import '../../../core/sources/files/fake_backend.dart';
import '../../../core/sources/files/fake_media_names.dart';
import '../../../core/sources/files/files_fixture.dart';
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';

class _Harness {
  _Harness(this.box, this.store, this.storage, this.backend);

  final Box<Map<dynamic, dynamic>> box;
  final InMemorySourceStore store;
  final MockAuthStorage storage;
  final FakeBackend backend;
  final connects = <(Uri, String, String)>[];
  final clients = <http.Client>[];
}

int _boxes = 0;

/// [reuse] keeps the box, records and secrets of an earlier pump, as a
/// restart of the app would.
Future<_Harness> _pump(WidgetTester tester,
    {String? reauthAccountId, _Harness? reuse}) async {
  var box = reuse?.box;
  if (box == null) {
    final opened = (await tester.runAsync(() =>
        Hive.openBox<Map<dynamic, dynamic>>('webdav_screen_${_boxes++}',
            bytes: Uint8List(0))))!;
    // Only a box this pump opened: a reused one belongs to the first pump.
    addTearDown(() => tester.runAsync(opened.close));
    box = opened;
  }
  final h = _Harness(
    box,
    reuse?.store ?? InMemorySourceStore(),
    reuse?.storage ?? MockAuthStorage(),
    FakeBackend({
      '/dav/Films/Amber Tide (2019).mkv': 10,
      '/dav/Shows/Low Orbit/Low Orbit S01E01.mkv': 10,
      '/dav/Shows/Glass Orchard/Glass Orchard S01E01.mkv': 10,
    }),
  );
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // Pushed over a home route, as the add-source screen does, so back has
  // somewhere to go.
  final router = GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(path: '/home', builder: (_, __) => const Text('home')),
      GoRoute(
          path: '/add',
          builder: (_, __) =>
              AddWebDavScreen(reauthAccountId: reauthAccountId)),
      GoRoute(
          path: '/s/:id',
          builder: (_, s) => Text('opened ${s.pathParameters['id']}')),
    ],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...noHiveOverrides,
      sourceStoreProvider.overrideWith((ref) async => h.store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(h.storage)),
      filesIndexBoxProvider.overrideWithValue(h.box),
      filesProgressStoreProvider
          .overrideWithValue(InMemoryPlaybackProgressStore()),
      mediaNamesProvider.overrideWithValue(FakeMediaNames()),
      relayTmdbProvider.overrideWithValue(FakeFilesRelay()),
      filesBackendBuilderProvider
          .overrideWithValue((ref, source) => FakeBackend({})),
      webDavConnectorProvider.overrideWithValue((base, user, password, client) {
        h.connects.add((base, user, password));
        h.clients.add(client);
        return h.backend;
      }),
    ],
    child: MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  ));
  await tester.pumpAndSettle();
  unawaited(router.push('/add'));
  await tester.pumpAndSettle();
  return h;
}

Future<void> _connect(WidgetTester tester,
    {String password = 'pw',
    String url = 'https://nas.example.test/dav/'}) async {
  await tester.enterText(find.byKey(const Key('webdav-url-field')), url);
  await tester.enterText(find.byKey(const Key('webdav-user-field')), 'viewer');
  await tester.enterText(
      find.byKey(const Key('webdav-password-field')), password);
  await tester.tap(find.byKey(const Key('webdav-connect-button')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('warns that WebDAV libraries are experimental', (tester) async {
    await _pump(tester);
    expect(
        find.descendant(
            of: find.byKey(const Key('add-webdav-experimental')),
            matching: find.textContaining('very experimental')),
        findsOneWidget);
  });

  testWidgets('refuses a password over http to a host outside the network',
      (tester) async {
    final h = await _pump(tester);
    await _connect(tester, url: 'http://nas.example.test/dav');

    expect(h.connects, isEmpty);
    expect(
        find.textContaining('Use https:// for a WebDAV share'), findsOneWidget);
    expect((await h.store.load()).accounts, isEmpty);
    expect(h.storage.keys, isEmpty);
  });

  testWidgets('lets a password go over http on the home network',
      (tester) async {
    final h = await _pump(tester);
    await _connect(tester, url: 'http://192.168.1.20:8080/dav');

    expect(h.connects.single.$1, Uri.parse('http://192.168.1.20:8080/dav'));
    expect(find.textContaining('Use https://'), findsNothing);
    expect(find.byKey(const Key('webdav-save-button')), findsOneWidget);
  });

  testWidgets('every connect attempt shares one http client', (tester) async {
    final h = await _pump(tester);
    h.backend.probeFailure = const BackendUnreachable('down');
    await _connect(tester);
    await tester.tap(find.byKey(const Key('webdav-connect-button')));
    await tester.pumpAndSettle();
    expect(h.clients, hasLength(2));
    expect(identical(h.clients[0], h.clients[1]), isTrue);
  });

  testWidgets('webdav_connect_tests_the_root_before_saving', (tester) async {
    final h = await _pump(tester);
    h.backend.probeFailure = const BackendUnauthorized('HTTP 401');
    await _connect(tester, password: 'wrong');

    expect(h.connects.single.$1, Uri.parse('https://nas.example.test/dav'));
    expect(find.text('Wrong user or password.'), findsOneWidget);
    expect(find.byKey(const Key('webdav-save-button')), findsNothing);
    expect((await h.store.load()).accounts, isEmpty);
    expect(h.storage.keys, isEmpty);

    h.backend.probeFailure = const BackendUnreachable('down');
    await tester.tap(find.byKey(const Key('webdav-connect-button')));
    await tester.pumpAndSettle();
    expect(find.text("Can't reach the server."), findsOneWidget);
    expect((await h.store.load()).accounts, isEmpty);
  });

  testWidgets('webdav_lists_folders_and_saves_chosen_roots_with_kinds',
      (tester) async {
    final h = await _pump(tester);
    await _connect(tester);

    expect(find.byKey(const Key('webdav-folder-/dav/Films')), findsOneWidget);
    expect(find.byKey(const Key('webdav-folder-/dav/Shows')), findsOneWidget);
    expect(find.byKey(const Key('webdav-save-button')), findsOneWidget);

    // Films as movies.
    await tester.tap(find.byKey(const Key('webdav-tick-/dav/Films')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('webdav-kind-/dav/Films')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('files-kind-movies')).last);
    await tester.pumpAndSettle();

    // Descend into Shows and tick it from inside as TV shows.
    await tester.tap(find.byKey(const Key('webdav-folder-/dav/Shows')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('webdav-folder-/dav/Shows/Low Orbit')),
        findsOneWidget);
    await tester.tap(find.byKey(const Key('webdav-tick-/dav/Shows')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('webdav-kind-/dav/Shows')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('files-kind-series')).last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('webdav-save-button')));
    await tester.pumpAndSettle();

    final record = (await h.store.load()).accounts.single;
    final accountId =
        webDavAccountId(Uri.parse('https://nas.example.test/dav'));
    expect(record.account.id, accountId);
    final secret = await h.storage
        .read('${record.account.storageNamespace}/account_token');
    final creds = WebDavCredentials.fromJson(secret!);
    expect((creds.user, creds.password), ('viewer', 'pw'));

    final roots = {
      for (final r in FileLibraryIndex(h.box, accountId: accountId).roots())
        r.path: r,
    };
    expect(roots.keys, unorderedEquals(['/dav/Films', '/dav/Shows']));
    expect(roots['/dav/Films']!.kind, FilesLibraryKind.movies);
    expect(roots['/dav/Films']!.id, filesRootId('/dav/Films'));
    expect(roots['/dav/Films']!.title, 'Films');
    expect(roots['/dav/Shows']!.kind, FilesLibraryKind.series);
    expect(find.text('opened $accountId:owner:$accountId'), findsOneWidget);
  });

  testWidgets('an encoded share path is listed decoded', (tester) async {
    final h = await _pump(tester);
    await _connect(tester, url: 'https://nas.example.test/my%20dav/');
    expect(h.connects.single.$1.path, '/my%20dav');
    expect(h.backend.listed.first, '/my dav');
  });

  testWidgets('signing in again fills the address and replaces the password',
      (tester) async {
    final h = await _pump(tester);
    await _connect(tester, password: 'old');
    await tester.tap(find.byKey(const Key('webdav-tick-/dav/Films')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('webdav-save-button')));
    await tester.pumpAndSettle();
    final accountId =
        webDavAccountId(Uri.parse('https://nas.example.test/dav'));

    await tester.pumpWidget(const SizedBox());
    await _pump(tester, reauthAccountId: accountId, reuse: h);
    final url = tester
        .widget<TextField>(find.byKey(const Key('webdav-url-field')))
        .controller!
        .text;
    expect(url, 'https://nas.example.test/dav');

    await tester.enterText(
        find.byKey(const Key('webdav-user-field')), 'viewer');
    await tester.enterText(
        find.byKey(const Key('webdav-password-field')), 'new');
    await tester.tap(find.byKey(const Key('webdav-connect-button')));
    await tester.pumpAndSettle();
    // Nothing ticked, yet saving the new password is allowed.
    await tester.tap(find.byKey(const Key('webdav-save-button')));
    await tester.pumpAndSettle();

    final record = (await h.store.load()).accounts.single;
    expect(record.account.id, accountId);
    final secret = await h.storage
        .read('${record.account.storageNamespace}/account_token');
    expect(WebDavCredentials.fromJson(secret!).password, 'new');
    expect(FileLibraryIndex(h.box, accountId: accountId).roots(), hasLength(1));
  });

  testWidgets('back from a subfolder lists its parent and stays',
      (tester) async {
    await _pump(tester);
    await _connect(tester);
    await tester.tap(find.byKey(const Key('webdav-folder-/dav/Shows')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('webdav-folder-/dav/Shows/Low Orbit')));
    await tester.pumpAndSettle();
    expect(find.text('/dav/Shows/Low Orbit'), findsOneWidget);

    // The app bar arrow climbs one folder.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('/dav/Shows'), findsOneWidget);
    expect(find.text('home'), findsNothing);

    // So does the system back gesture.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('/dav'), findsOneWidget);
    expect(find.byKey(const Key('webdav-folder-/dav/Films')), findsOneWidget);
    expect(find.text('home'), findsNothing);

    // At the share's root, back leaves the setup.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('back abandons a slow folder listing', (tester) async {
    final h = await _pump(tester);
    await _connect(tester);
    await tester.tap(find.byKey(const Key('webdav-folder-/dav/Shows')));
    await tester.pumpAndSettle();

    final slow = Completer<void>();
    h.backend.holds['/dav/Shows/Low Orbit'] = slow;
    await tester
        .tap(find.byKey(const Key('webdav-folder-/dav/Shows/Low Orbit')));
    await tester.pump();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('/dav/Shows'), findsOneWidget);
    expect(find.text('home'), findsNothing);

    // The abandoned answer arrives late and is dropped.
    slow.complete();
    await tester.pumpAndSettle();
    expect(find.text('/dav/Shows'), findsOneWidget);

    // Back is live again and climbs.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('/dav'), findsOneWidget);
  });

  testWidgets('back leaves once climbing has failed', (tester) async {
    final h = await _pump(tester);
    await _connect(tester);
    await tester.tap(find.byKey(const Key('webdav-folder-/dav/Shows')));
    await tester.pumpAndSettle();

    h.backend.failures['/dav'] = const BackendUnreachable('down');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('/dav/Shows'), findsOneWidget);
    expect(find.byKey(const Key('webdav-error')), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('back at the root abandons a slow listing before leaving',
      (tester) async {
    final h = await _pump(tester);
    await _connect(tester);
    await tester.tap(find.byKey(const Key('webdav-tick-/dav/Films')));
    await tester.pumpAndSettle();

    final slow = Completer<void>();
    h.backend.holds['/dav/Shows'] = slow;
    await tester.tap(find.byKey(const Key('webdav-folder-/dav/Shows')));
    await tester.pump();

    // The first back abandons the listing; the ticked folder survives.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsNothing);
    expect(find.text('/dav'), findsOneWidget);
    expect(
        tester
            .widget<Checkbox>(find.byKey(const Key('webdav-tick-/dav/Films')))
            .value,
        isTrue);
    slow.complete();
    await tester.pumpAndSettle();
    expect(find.text('/dav'), findsOneWidget);

    // The next one leaves.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('connecting jumps to the folders under reduced motion',
      (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final h = await _pump(tester);
    for (var i = 0; i < 40; i++) {
      h.backend.setFile('/dav/Folder ${i.toString().padLeft(2, '0')}/a.mkv', 1);
    }
    await tester.binding.setSurfaceSize(const Size(400, 800));
    await tester.enterText(find.byKey(const Key('webdav-url-field')),
        'https://nas.example.test/dav/');
    await tester.tap(find.byKey(const Key('webdav-connect-button')));
    // Two frames with no time passing: the listing lands, then the
    // post-frame scroll. An animated scroll would still be at its start.
    await tester.pump();
    await tester.pump();
    expect(
        tester.getRect(find.byKey(const Key('webdav-up'))).top, lessThan(250));
  });

  testWidgets('back before connecting leaves the setup', (tester) async {
    await _pump(tester);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('the up button and save stay on screen in a long folder list',
      (tester) async {
    final h = await _pump(tester);
    for (var i = 0; i < 40; i++) {
      h.backend.setFile('/dav/Folder ${i.toString().padLeft(2, '0')}/a.mkv', 1);
    }
    await tester.binding.setSurfaceSize(const Size(400, 800));
    await _connect(tester);
    // Connecting scrolls the spent form away so the folders fill the screen.
    expect(
        tester.getRect(find.byKey(const Key('webdav-up'))).top, lessThan(250));

    await tester.drag(
        find.byKey(const Key('webdav-folder-list')), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('webdav-folder-/dav/Shows')), findsOneWidget);
    // The list scrolled under the location bar rather than taking it along.
    expect(find.byKey(const Key('webdav-folder-/dav/Folder 00')), findsNothing);
    final screen = tester.getRect(find.byType(Scaffold));
    for (final key in ['webdav-up', 'webdav-dir', 'webdav-save-button']) {
      final rect = tester.getRect(find.byKey(Key(key)));
      expect(screen.contains(rect.center), isTrue,
          reason: '$key is off screen');
    }
    expect(
        tester.getRect(find.byKey(const Key('webdav-save-button'))).top,
        greaterThanOrEqualTo(tester
            .getRect(find.byKey(const Key('webdav-folder-list')))
            .bottom));

    await tester.tap(find.byKey(const Key('webdav-folder-/dav/Shows')));
    await tester.pumpAndSettle();
    expect(find.text('/dav/Shows'), findsOneWidget);
    await tester.tap(find.byKey(const Key('webdav-up')));
    await tester.pumpAndSettle();
    expect(find.text('/dav'), findsOneWidget);
  });
}
