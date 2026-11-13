import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_accounts.dart';
import 'package:player/core/sources/files/files_providers.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/files/smb_discovery.dart';
import 'package:player/core/sources/files/smb_native.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/connections/smb_address_sheet.dart';

import '../../../core/sources/files/fake_backend.dart';
import '../../../core/sources/files/fake_media_names.dart';
import '../../../core/sources/files/fake_smb_discovery.dart';
import '../../../core/sources/files/fake_smb_native.dart';
import '../../../core/sources/files/files_fixture.dart';
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';

int _boxes = 0;

final _url = Uri.parse('smb://192.168.1.5/movies');
final _accountId = smbAccountId(_url);

/// Lists [shares] when set, instead of every share the fake holds.
class _Native extends FakeSmbNative {
  List<String>? shares;

  @override
  Future<List<String>> listShares(
      String host, int port, SmbCredentials c) async {
    final all = await super.listShares(host, port, c);
    return shares ?? all;
  }
}

class _Harness {
  _Harness(this.store, this.native, this.discovery, this.container);

  final InMemorySourceStore store;
  final _Native native;
  final FakeSmbDiscovery discovery;
  final ProviderContainer container;

  Future<SourceAccountRecord> record() async =>
      (await store.load()).accounts.single;
}

/// A screen with one button that opens the sheet for the saved share.
class _Opener extends ConsumerWidget {
  const _Opener();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final record = ref
        .watch(sourceRecordsProvider)
        .value
        ?.accounts
        .where((r) => r.account.id == _accountId)
        .firstOrNull;
    return Scaffold(
      body: record == null
          ? const SizedBox.shrink()
          : TextButton(
              key: const Key('open'),
              onPressed: () => showSmbAddressSheet(context, record: record),
              child: const Text('open'),
            ),
    );
  }
}

Future<_Harness> _pump(WidgetTester tester) async {
  final box = (await tester.runAsync(() => Hive.openBox<Map<dynamic, dynamic>>(
      'smb_address_${_boxes++}',
      bytes: Uint8List(0))))!;
  addTearDown(() => tester.runAsync(box.close));
  final store = InMemorySourceStore();
  // The saved share holds the movies share, so a listing must find it.
  final native = _Native()..addDir('Movies', '/Films');
  final discovery = FakeSmbDiscovery();
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
      smbNativeProvider.overrideWithValue(native),
      smbDiscoveryProvider.overrideWithValue(discovery),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: _Opener(),
    ),
  ));
  await tester.pumpAndSettle();
  final container =
      ProviderScope.containerOf(tester.element(find.byType(_Opener)));
  final accounts = container.read(filesAccountsProvider);
  final id = await accounts.addSmbAccount(
      url: _url,
      credentials: const SmbCredentials(user: 'viewer', password: 'pw'));
  await tester.pumpAndSettle();
  await accounts.addSmbRoot(id, path: '/Films', kind: FilesLibraryKind.movies);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
  return _Harness(store, native, discovery, container);
}

Future<void> _save(WidgetTester tester) async {
  final save = find.byKey(const Key('smb-address-save'));
  await tester.ensureVisible(save);
  await tester.tap(save);
  await tester.pumpAndSettle();
}

List<String> _hosts(SourceAccountRecord r) =>
    [for (final c in r.servers.single.connections) c.uri.host];

void main() {
  testWidgets('change_address_keeps_id_and_roots', (tester) async {
    final h = await _pump(tester);
    expect(find.byKey(const Key('smb-address-host')), findsOneWidget);

    await tester.enterText(
        find.byKey(const Key('smb-address-host')), '10.0.0.7');
    await _save(tester);

    final record = await h.record();
    expect(record.account.id, _accountId);
    expect(record.servers.single.connections.single.uri,
        Uri.parse('smb://10.0.0.7/movies'));
    expect(h.container.read(filesIndexProvider(_accountId)).roots().single.path,
        '/Films');
    expect(find.byKey(const Key('smb-address-host')), findsNothing);
  });

  testWidgets('share_missing_shows_error_and_keeps_address', (tester) async {
    final h = await _pump(tester);
    final before = await h.record();
    h.native.shares = const ['Backups'];
    await tester.enterText(
        find.byKey(const Key('smb-address-host')), '10.0.0.7');
    await _save(tester);

    expect(find.text('This server has no share named movies'), findsOneWidget);
    expect(find.byKey(const Key('smb-address-host')), findsOneWidget);
    expect((await h.record()).servers.single.connections,
        before.servers.single.connections);
  });

  testWidgets('refused_login_shows_error', (tester) async {
    final h = await _pump(tester);
    final before = await h.record();
    h.native.failure = const BackendUnauthorized('denied');
    await tester.enterText(
        find.byKey(const Key('smb-address-host')), '10.0.0.7');
    await _save(tester);
    h.native.failure = null;

    expect(find.text('The username or password is wrong.'), findsOneWidget);
    expect((await h.record()).servers.single.connections,
        before.servers.single.connections);
  });

  testWidgets('picking_discovered_server_fills_host', (tester) async {
    final h = await _pump(tester);
    h.discovery.emit(const [
      DiscoveredSmbServer(
        name: 'NAS',
        host: '192.168.1.30',
        port: 445,
        alternatives: ['10.0.0.30'],
        hostname: 'nas.local',
      ),
    ]);
    await tester.pumpAndSettle();
    final row = find.byKey(const Key('smb-address-server-NAS'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    final host = tester
        .widget<TextField>(find.byKey(const Key('smb-address-host')))
        .controller!
        .text;
    expect(host, '192.168.1.30');

    await _save(tester);

    final record = await h.record();
    expect(record.account.id, _accountId);
    expect(_hosts(record), ['192.168.1.30', 'nas.local', '10.0.0.30']);
    expect(record.servers.single.serviceName, 'NAS');
    expect(find.byKey(const Key('smb-address-host')), findsNothing);
    expect(h.discovery.cancelCount, h.discovery.listenCount);
  });

  testWidgets('editing_the_host_after_a_pick_saves_it_as_typed',
      (tester) async {
    final h = await _pump(tester);
    h.discovery.emit(const [
      DiscoveredSmbServer(
          name: 'NAS', host: '192.168.1.30', port: 445, hostname: 'nas.local'),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('smb-address-server-NAS')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('smb-address-host')), '10.0.0.8');
    await _save(tester);

    final record = await h.record();
    expect(_hosts(record), ['10.0.0.8']);
    expect(record.servers.single.serviceName, isNull);
  });

  testWidgets('missing_credentials_show_the_refused_login_message',
      (tester) async {
    final h = await _pump(tester);
    final before = await h.record();
    await h.container
        .read(sourceSecretsProvider)
        .deleteAccountToken(before.account);
    await tester.enterText(
        find.byKey(const Key('smb-address-host')), '10.0.0.7');
    await _save(tester);

    expect(find.text('The username or password is wrong.'), findsOneWidget);
    expect((await h.record()).servers.single.connections,
        before.servers.single.connections);
  });
}
