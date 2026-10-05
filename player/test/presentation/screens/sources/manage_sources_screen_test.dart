import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/sources/lock/pin_store.dart';
import 'package:player/core/sources/mydia/mydia_guest_credentials.dart';
import 'package:player/core/sources/mydia/mydia_guest_secrets.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/sources/manage_sources_screen.dart';

import '../../../core/sources/jellyfin/jellyfin_media_source_test.dart'
    show jellyfinRecord;
import '../../../core/sources/store/source_json_test.dart' show plexRecord;
import '../../../core/sources/stash/stash_media_source_test.dart'
    show stashRecord;
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/toast_harness.dart';

class _RecordingP2p extends P2pService {
  final unwatched = <String>[];
  @override
  void unwatchPeer(String peer) => unwatched.add(peer);
}

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
      authStateProvider.overrideWith(_Authenticated.new),
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      p2pServiceProvider.overrideWithValue(p2p),
    ],
    child: const MaterialApp(
        builder: toastLayerBuilder, home: ManageSourcesScreen()),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('manage-remove-mguest')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('manage-remove-confirm')));
  await tester.pumpAndSettle();
  return store;
}

class _Authenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.authenticated);
}

void main() {
  testWidgets('removes an account after confirming', (tester) async {
    final store = InMemorySourceStore();
    final storage = MockAuthStorage();
    await storage.write('source/acc1/account_token', 'tok');
    await store.putAccount(plexRecord());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authStateProvider.overrideWith(_Authenticated.new),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      ],
      child: const MaterialApp(
          builder: toastLayerBuilder, home: ManageSourcesScreen()),
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
        authStateProvider.overrideWith(_Authenticated.new),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: const MaterialApp(
          builder: toastLayerBuilder, home: ManageSourcesScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manage-switch-user-acc1')), findsOneWidget);
  });

  testWidgets('labels a Jellyfin account as a Jellyfin user', (tester) async {
    final store = InMemorySourceStore();
    await store.putAccount(jellyfinRecord);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authStateProvider.overrideWith(_Authenticated.new),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: const MaterialApp(
          builder: toastLayerBuilder, home: ManageSourcesScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Jellyfin user'), findsOneWidget);
    expect(find.text('Stash server'), findsNothing);
    expect(find.text('Change address or sign in'), findsOneWidget);
    expect(find.text('Other servers'), findsOneWidget);
  });

  testWidgets('hides a hidden server while locked and offers Show hidden',
      (tester) async {
    final store = InMemorySourceStore();
    await store.putAccount(plexRecord()
        .copyWith(serverLocks: const {'abc123': SourceLock.hidden}));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authStateProvider.overrideWith(_Authenticated.new),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: const MaterialApp(
          builder: toastLayerBuilder, home: ManageSourcesScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Attic'), findsNothing);
    expect(find.text('quill'), findsNothing);
    expect(find.byKey(const Key('show-hidden-sources')), findsOneWidget);
  });

  testWidgets('Show hidden is there with nothing hidden', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authStateProvider.overrideWith(_Authenticated.new),
        sourceStoreProvider.overrideWith((ref) async => InMemorySourceStore()),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: const MaterialApp(
          builder: toastLayerBuilder, home: ManageSourcesScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('show-hidden-sources')), findsOneWidget);
  });

  testWidgets('first lock asks for a PIN, then stores the lock',
      (tester) async {
    final store = InMemorySourceStore();
    await store.putAccount(plexRecord());
    final storage = MockAuthStorage();
    final pins = PinStore(storage, iterations: 1000);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authStateProvider.overrideWith(_Authenticated.new),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
        pinStoreProvider.overrideWithValue(pins),
      ],
      child: const MaterialApp(
          builder: toastLayerBuilder, home: ManageSourcesScreen()),
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
    await writeGuestCredentials(
        SourceSecrets(storage),
        _guestRecord().account,
        const MydiaGuestCredentials(
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
        authStateProvider.overrideWith(_Authenticated.new),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: const MaterialApp(
          builder: toastLayerBuilder, home: ManageSourcesScreen()),
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

  testWidgets('home Mydia has its own switch when signed in', (tester) async {
    final store = InMemorySourceStore();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authStateProvider.overrideWith(_Authenticated.new),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: const MaterialApp(
          builder: toastLayerBuilder, home: ManageSourcesScreen()),
    ));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('manage-all-servers-mydia')), findsOneWidget);
    expect(find.text('No servers yet.'), findsNothing);
  });

  testWidgets('removing a guest whose secret cannot be read still removes it',
      (tester) async {
    final p2p = _RecordingP2p();
    final store = await _removeGuest(tester, _UnreadableStorage(), p2p);
    expect(p2p.unwatched, isEmpty);
    expect((await store.load()).accounts, isEmpty);
  });
}
