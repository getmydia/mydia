import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/sources/lock/pin_store.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_secrets.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/connections/account_detail_page.dart';
import 'package:player/presentation/screens/settings/settings_nav.dart';
import 'package:player/presentation/widgets/window_chrome/window_title_row.dart';

import '../../../core/sources/jellyfin/jellyfin_media_source_test.dart'
    show jellyfinRecord;
import '../../../core/sources/store/source_json_test.dart' show plexRecord;
import '../../../core/sources/stash/stash_media_source_test.dart'
    show stashRecord;
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/mydia_test_source.dart';
import '../../../test_utils/no_downloads.dart';
import '../../../test_utils/toast_harness.dart';

class _RecordingP2p extends P2pService {
  final unwatched = <String>[];
  @override
  void unwatchPeer(String peer) => unwatched.add(peer);
}

class _RemovalNav implements SettingsNav {
  int removed = 0;
  @override
  void accountRemoved() => removed++;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Widget _hosted(String accountId, [SettingsNav? nav]) => SettingsNavScope(
      nav: nav ?? _RemovalNav(),
      child: Scaffold(body: AccountDetailBody(accountId: accountId)),
    );

class _UnreadableStorage extends MockAuthStorage {
  @override
  Future<String?> read(String key) async => throw StateError('keychain locked');
}

SourceAccountRecord _guestRecord() => SourceAccountRecord(
      account: const ProviderAccount(
        id: 'mguest',
        kind: SourceKind.mydia,
        displayName: 'Lakeside',
        storageNamespace: 'source/mguest',
        activeProfileId: 'owner',
      ),
      profiles: const [
        SourceProfile(
            id: 'owner', accountId: 'mguest', name: 'Owner', isOwner: true),
      ],
      servers: const [
        SourceServer(
            id: 'inst-2',
            accountId: 'mguest',
            profileId: 'owner',
            name: 'Lakeside'),
      ],
      addedAtMs: 0,
    );

Future<InMemorySourceStore> _removeGuest(
  WidgetTester tester,
  MockAuthStorage storage,
  P2pService p2p,
) async {
  final store = InMemorySourceStore();
  await store.putAccount(_guestRecord());
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...noHiveOverrides,
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      p2pServiceProvider.overrideWithValue(p2p),
    ],
    child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: toastLayerBuilder,
        home: _hosted('mguest')),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('manage-remove-mguest')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('manage-remove-confirm')));
  await tester.pumpAndSettle();
  return store;
}

Future<void> _pumpRouted(
  WidgetTester tester,
  SourceAccountRecord record,
) async {
  final store = InMemorySourceStore();
  await store.putAccount(record);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      ...noHiveOverrides,
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(MockAuthStorage())),
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
                  body: AccountDetailBody(accountId: record.account.id)),
              routes: [
                GoRoute(
                    path: ':sourceId',
                    builder: (_, state) => Text(
                        'settings for ${state.pathParameters['sourceId']}')),
              ]),
        ],
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a Mydia card opens that instance\'s settings', (tester) async {
    final record = testMydiaRecord();
    await _pumpRouted(tester, record);

    await tester.tap(find.byKey(Key('manage-settings-${record.account.id}')));
    await tester.pumpAndSettle();

    expect(
        find.text('settings for ${testMydiaSourceId.value}'), findsOneWidget);
  });

  testWidgets('a Plex card has no settings button', (tester) async {
    await _pumpRouted(tester, plexRecord());

    expect(find.byKey(const Key('manage-remove-acc1')), findsOneWidget);
    expect(find.byKey(const Key('manage-settings-acc1')), findsNothing);
  });

  testWidgets('removes an account after confirming', (tester) async {
    final store = InMemorySourceStore();
    final storage = MockAuthStorage();
    await storage.write('source/acc1/account_token', 'tok');
    await store.putAccount(plexRecord());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      ],
      child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: toastLayerBuilder,
          home: _hosted('acc1')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('quill'), findsOneWidget);
    expect(find.text('Attic'), findsOneWidget);

    await tester.tap(find.byKey(const Key('manage-remove-acc1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-remove-confirm')));
    await tester.pumpAndSettle();
    expect((await store.load()).accounts, isEmpty);
    expect(find.text('quill'), findsNothing);
    expect(await storage.read('source/acc1/account_token'), isNull);
  });

  testWidgets('offers Switch user only for a Plex account with Home users',
      (tester) async {
    final store = InMemorySourceStore();
    await store.putAccount(plexRecord().copyWith(profiles: const [
      SourceProfile(
          id: 'owner', accountId: 'acc1', name: 'Quill', isOwner: true),
      SourceProfile(
          id: 'kid0001', accountId: 'acc1', name: 'Pip', isOwner: false),
    ]));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: toastLayerBuilder,
          home: _hosted('acc1')),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manage-switch-user-acc1')), findsOneWidget);
  });

  testWidgets('labels a Jellyfin account as a Jellyfin user', (tester) async {
    final store = InMemorySourceStore();
    await store.putAccount(jellyfinRecord);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: toastLayerBuilder,
          home: _hosted('jf1')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Jellyfin user'), findsOneWidget);
    expect(find.text('Stash server'), findsNothing);
    expect(find.text('Change address or sign in'), findsOneWidget);
  });

  testWidgets('first lock asks for a PIN, then stores the lock',
      (tester) async {
    final store = InMemorySourceStore();
    await store.putAccount(plexRecord());
    final storage = MockAuthStorage();
    final pins = PinStore(storage, iterations: 1000);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
        pinStoreProvider.overrideWithValue(pins),
      ],
      child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: toastLayerBuilder,
          home: _hosted('acc1')),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-lock-abc123')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('lock-choice-locked')));
    await tester.pumpAndSettle();
    for (var round = 0; round < 2; round++) {
      for (final d in '4821'.split('')) {
        await tester.tap(find.byKey(Key('pin-pad-$d')).last);
      }
      await tester.tap(find.byKey(const Key('pin-pad-ok')).last);
      await tester.pumpAndSettle();
    }
    expect((await store.load()).accounts.single.lockOf('abc123'),
        SourceLock.locked);
    expect(await pins.check('4821'), isA<PinAccepted>());
  });

  testWidgets('removing a p2p guest stops watching its node', (tester) async {
    final storage = MockAuthStorage();
    final p2p = _RecordingP2p();
    await writeMydiaCredentials(
        SourceSecrets(storage),
        _guestRecord().account,
        const MydiaCredentials(
            instanceId: 'inst-2', accessToken: 'at', nodeAddr: '{"id":"n1"}'));
    final store = await _removeGuest(tester, storage, p2p);
    expect(p2p.unwatched, ['{"id":"n1"}']);
    expect((await store.load()).accounts, isEmpty);
  });

  testWidgets('removing a guest with a garbage secret still removes it',
      (tester) async {
    final storage = MockAuthStorage();
    await storage.write('source/mguest/account_token', 'not json');
    final p2p = _RecordingP2p();
    final store = await _removeGuest(tester, storage, p2p);
    expect(p2p.unwatched, isEmpty);
    expect((await store.load()).accounts, isEmpty);
  });

  testWidgets('each server has an All servers switch, Stash off by default',
      (tester) async {
    final store = InMemorySourceStore();
    await store.putAccount(plexRecord());
    await store.putAccount(stashRecord);
    final plexId = plexRecord().sources.single.id.value;
    final stashId = stashRecord.sources.single.id.value;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: toastLayerBuilder,
          home: Scaffold(
              body: Column(children: [
            Expanded(child: AccountDetailBody(accountId: 'acc1')),
            Expanded(child: AccountDetailBody(accountId: 'st1')),
          ]))),
    ));
    await tester.pumpAndSettle();
    final plexSwitch = find.byKey(ValueKey('manage-all-servers-$plexId'));
    final stashSwitch = find.byKey(ValueKey('manage-all-servers-$stashId'));
    await tester.ensureVisible(stashSwitch);
    expect(tester.widget<SwitchListTile>(plexSwitch).value, isTrue);
    expect(tester.widget<SwitchListTile>(stashSwitch).value, isFalse);

    await tester.tap(stashSwitch);
    await tester.pumpAndSettle();
    expect((await store.load()).allServers[SourceId(stashId)], isTrue);
    expect(tester.widget<SwitchListTile>(stashSwitch).value, isTrue);
  });

  testWidgets('the migrated Mydia server is an ordinary account with a remove',
      (tester) async {
    final store = InMemorySourceStore();
    await store.putAccount(testMydiaRecord());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: toastLayerBuilder,
          home: _hosted('macct')),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manage-remove-macct')), findsOneWidget);
    expect(
        find.byKey(ValueKey('manage-all-servers-${testMydiaSourceId.value}')),
        findsOneWidget);
    expect(find.text('Mydia account'), findsOneWidget);
    expect(find.text('No servers yet.'), findsNothing);
  });

  testWidgets('removing a guest whose secret cannot be read still removes it',
      (tester) async {
    final p2p = _RecordingP2p();
    final store = await _removeGuest(tester, _UnreadableStorage(), p2p);
    expect(p2p.unwatched, isEmpty);
    expect((await store.load()).accounts, isEmpty);
  });

  testWidgets('removing the account pops to the hub', (tester) async {
    final store = InMemorySourceStore();
    await store.putAccount(plexRecord());
    final nav = _RemovalNav();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: toastLayerBuilder,
          home: SettingsNavScope(
              nav: nav,
              child:
                  const Scaffold(body: AccountDetailBody(accountId: 'acc1')))),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-remove-acc1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-remove-confirm')));
    await tester.pumpAndSettle();

    expect(nav.removed, 1);
    expect((await store.load()).accounts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown account renders nothing', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => InMemorySourceStore()),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: toastLayerBuilder,
          home: _hosted('missing')),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(SizedBox), findsWidgets);
    expect(find.byType(ListView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the page has a window title bar named after the account',
      (tester) async {
    final record = plexRecord();
    final store = InMemorySourceStore();
    await store.putAccount(record);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: toastLayerBuilder,
        home: SettingsNavScope(
          nav: _RemovalNav(),
          child: AccountDetailPage(accountId: record.account.id),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsNothing);
    expect(
        find.descendant(
            of: find.byType(WindowTitleBar),
            matching: find.text(record.account.displayName)),
        findsOneWidget);
  });

  testWidgets('router opens account detail', (tester) async {
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const Text('home')),
      GoRoute(
          path: '/sources/manage/account/:accountId',
          builder: (_, state) => Text('at ${state.uri}')),
    ]);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    RouterSettingsNav(router).openAccount('acc1');
    await tester.pumpAndSettle();

    expect(find.text('at /sources/manage/account/acc1'), findsOneWidget);
  });
}
