import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_providers.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/files/smb_discovery.dart';
import 'package:player/core/sources/files/smb_native.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/sources/add_smb_screen.dart';

import '../../../core/sources/files/fake_backend.dart';
import '../../../core/sources/files/fake_media_names.dart';
import '../../../core/sources/files/fake_smb_discovery.dart';
import '../../../core/sources/files/fake_smb_native.dart';
import '../../../core/sources/files/files_fixture.dart';
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';

class _RecordingNative extends FakeSmbNative {
  final listed = <(String, int, SmbCredentials)>[];
  bool noShares = false;

  @override
  Future<List<String>> listShares(
      String host, int port, SmbCredentials c) async {
    listed.add((host, port, c));
    final shares = await super.listShares(host, port, c);
    return noShares ? const [] : shares;
  }
}

class _Harness {
  _Harness(this.box, this.store, this.storage, this.native, this.discovery);

  final Box<Map<dynamic, dynamic>> box;
  final InMemorySourceStore store;
  final MockAuthStorage storage;
  final _RecordingNative native;
  final FakeSmbDiscovery discovery;
  late final GoRouter router;
}

int _boxes = 0;

const _attic =
    DiscoveredSmbServer(name: 'Attic NAS', host: '192.168.1.20', port: 445);

Future<_Harness> _pump(
  WidgetTester tester, {
  String? reauthAccountId,
  _Harness? reuse,
  TargetPlatform platform = TargetPlatform.android,
  Duration timeout = const Duration(seconds: 5),
}) async {
  var box = reuse?.box;
  if (box == null) {
    final opened = (await tester.runAsync(() =>
        Hive.openBox<Map<dynamic, dynamic>>('smb_screen_${_boxes++}',
            bytes: Uint8List(0))))!;
    addTearDown(() => tester.runAsync(opened.close));
    box = opened;
  }
  final native = _RecordingNative()
    ..addDir('media', '/Films')
    ..addDir('media', '/Shows')
    ..addFile('media', '/Films/Amber Tide (2019).mkv');
  final h = _Harness(
    box,
    reuse?.store ?? InMemorySourceStore(),
    reuse?.storage ?? MockAuthStorage(),
    native,
    FakeSmbDiscovery(),
  );
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  h.router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, __) => const Text('home')),
      GoRoute(
          path: '/add',
          builder: (_, __) => AddSmbScreen(
                reauthAccountId: reauthAccountId,
                platform: platform,
                discoveryTimeout: timeout,
              )),
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
      smbNativeProvider.overrideWithValue(native),
      smbDiscoveryProvider.overrideWithValue(h.discovery),
    ],
    child: MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: h.router,
    ),
  ));
  await tester.pumpAndSettle();
  unawaited(h.router.push('/add'));
  await tester.pumpAndSettle();
  return h;
}

Future<void> _enter(WidgetTester tester, String key, String text) =>
    tester.enterText(find.byKey(Key(key)), text);

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _viaDiscovery(WidgetTester tester, _Harness h) async {
  h.discovery.emit([_attic]);
  await tester.pumpAndSettle();
  await _tap(tester, 'smb-server-192.168.1.20');
}

void main() {
  testWidgets('a discovered server leads to the login with its host filled',
      (tester) async {
    final h = await _pump(tester);
    expect(find.byKey(const Key('smb-servers')), findsOneWidget);
    await _viaDiscovery(tester, h);

    expect(find.byKey(const Key('smb-login')), findsOneWidget);
    final host = tester
        .widget<TextField>(find.byKey(const Key('smb-host-field')))
        .controller!
        .text;
    expect(host, '192.168.1.20');
  });

  testWidgets('the manual row shows its hint and accepts an address',
      (tester) async {
    final h = await _pump(tester);
    expect(find.text('Windows PCs usually need to be entered by address.'),
        findsOneWidget);
    await _tap(tester, 'smb-manual');
    await _enter(tester, 'smb-host-field', 'nas.example.test');
    await _enter(tester, 'smb-port-field', '4445');
    await _enter(tester, 'smb-user-field', 'viewer');
    await _enter(tester, 'smb-password-field', 'pw');
    await _enter(tester, 'smb-domain-field', 'HOME');
    await _tap(tester, 'smb-connect-button');

    final (host, port, creds) = h.native.listed.single;
    expect((host, port), ('nas.example.test', 4445));
    expect(
        (creds.user, creds.password, creds.domain), ('viewer', 'pw', 'HOME'));
    expect(find.byKey(const Key('smb-shares')), findsOneWidget);
  });

  testWidgets('guest connects with an empty user', (tester) async {
    final h = await _pump(tester);
    await _viaDiscovery(tester, h);
    await _tap(tester, 'smb-guest');

    final (_, _, creds) = h.native.listed.single;
    expect((creds.user, creds.password, creds.domain), ('', '', null));
    expect(find.byKey(const Key('smb-shares')), findsOneWidget);
  });

  testWidgets('a share, folders and kinds save one account with one root',
      (tester) async {
    final h = await _pump(tester);
    await _viaDiscovery(tester, h);
    await _enter(tester, 'smb-user-field', 'viewer');
    await _enter(tester, 'smb-password-field', 'pw');
    await _tap(tester, 'smb-connect-button');
    await _tap(tester, 'smb-share-media');

    await tester.tap(find.byKey(const Key('smb-tick-/Films')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('smb-kind-/Films')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('files-kind-movies')).last);
    await tester.pumpAndSettle();
    await _tap(tester, 'smb-save-button');

    final accountId = smbAccountId(Uri.parse('smb://192.168.1.20/media'));
    final record = (await h.store.load()).accounts.single;
    expect(record.account.id, accountId);
    final secret = await h.storage
        .read('${record.account.storageNamespace}/account_token');
    expect(SmbCredentials.fromJson(secret!).user, 'viewer');
    final roots = {
      for (final r in FileLibraryIndex(h.box, accountId: accountId).roots())
        r.path: r,
    };
    expect(roots.keys, ['/Films']);
    expect(roots['/Films']!.kind, FilesLibraryKind.movies);
    // Saved: the screen closed.
    expect(find.byKey(const Key('smb-login')), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('leaving the folder step unsaved closes the account',
      (tester) async {
    final h = await _pump(tester);
    await _viaDiscovery(tester, h);
    await _tap(tester, 'smb-guest');
    await _tap(tester, 'smb-share-media');
    expect(h.native.closedAccounts, isEmpty);

    h.router.pop();
    await tester.pumpAndSettle();
    expect(h.native.closedAccounts,
        [smbAccountId(Uri.parse('smb://192.168.1.20/media'))]);
  });

  group('errors', () {
    Future<_Harness> failing(WidgetTester tester, BackendFailure f) async {
      final h = await _pump(tester);
      await _viaDiscovery(tester, h);
      h.native.failure = f;
      await _tap(tester, 'smb-guest');
      return h;
    }

    testWidgets('unreachable', (tester) async {
      await failing(tester, const BackendUnreachable('boom'));
      expect(find.text("Can't reach the server."), findsOneWidget);
    });

    testWidgets('unauthorized', (tester) async {
      await failing(tester, const BackendUnauthorized());
      expect(find.text('The username or password is wrong.'), findsOneWidget);
    });

    testWidgets('SMB1 only', (tester) async {
      await failing(tester, const BackendUnreachable(kSmb1OnlyReason));
      expect(find.textContaining('only speaks SMB1'), findsOneWidget);
    });

    testWidgets('no shares', (tester) async {
      final h = await _pump(tester);
      h.native.noShares = true;
      await _tap(tester, 'smb-manual');
      await _enter(tester, 'smb-host-field', '10.0.0.9');
      await _tap(tester, 'smb-guest');
      expect(find.text('This server has no shared folders you can open.'),
          findsOneWidget);
      expect(find.byKey(const Key('smb-shares')), findsNothing);
    });
  });

  group('discovery empty states', () {
    testWidgets('an error shows none found, and no iOS hint on android',
        (tester) async {
      final h = await _pump(tester);
      h.discovery.fail();
      await tester.pumpAndSettle();
      expect(
          find.text('No file shares found on this network.'), findsOneWidget);
      expect(find.textContaining('Allow local network access'), findsNothing);
    });

    testWidgets('five quiet seconds show none found', (tester) async {
      await _pump(tester, timeout: const Duration(seconds: 5));
      expect(find.text('No file shares found on this network.'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(
          find.text('No file shares found on this network.'), findsOneWidget);
    });

    testWidgets('iOS adds the local network hint', (tester) async {
      final h = await _pump(tester, platform: TargetPlatform.iOS);
      h.discovery.fail();
      await tester.pumpAndSettle();
      expect(
          find.text('No file shares found on this network.'), findsOneWidget);
      expect(find.textContaining('Allow local network access'), findsOneWidget);
    });
  });

  testWidgets('signing in again keeps the share and replaces the credentials',
      (tester) async {
    final h = await _pump(tester);
    await _viaDiscovery(tester, h);
    await _enter(tester, 'smb-password-field', 'old');
    await _enter(tester, 'smb-user-field', 'viewer');
    await _tap(tester, 'smb-connect-button');
    await _tap(tester, 'smb-share-media');
    await tester.tap(find.byKey(const Key('smb-tick-/Films')));
    await tester.pumpAndSettle();
    await _tap(tester, 'smb-save-button');
    final accountId = smbAccountId(Uri.parse('smb://192.168.1.20/media'));

    await tester.pumpWidget(const SizedBox());
    final h2 = await _pump(tester, reauthAccountId: accountId, reuse: h);
    expect(find.byKey(const Key('smb-login')), findsOneWidget);
    expect(find.byKey(const Key('smb-servers')), findsNothing);
    expect(
        tester
            .widget<TextField>(find.byKey(const Key('smb-host-field')))
            .controller!
            .text,
        '192.168.1.20');

    await _enter(tester, 'smb-user-field', 'viewer');
    await _enter(tester, 'smb-password-field', 'new');
    await _tap(tester, 'smb-connect-button');

    expect(find.byKey(const Key('smb-shares')), findsNothing);
    final record = (await h2.store.load()).accounts.single;
    expect(record.account.id, accountId);
    final secret = await h2.storage
        .read('${record.account.storageNamespace}/account_token');
    expect(SmbCredentials.fromJson(secret!).password, 'new');
    expect(
        FileLibraryIndex(h2.box, accountId: accountId).roots(), hasLength(1));
    expect(find.text('home'), findsOneWidget);
  });
}
