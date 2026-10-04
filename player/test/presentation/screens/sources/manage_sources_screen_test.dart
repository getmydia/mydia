import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/lock/pin_store.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/sources/manage_sources_screen.dart';

import '../../../core/sources/jellyfin/jellyfin_media_source_test.dart'
    show jellyfinRecord;
import '../../../core/sources/store/source_json_test.dart' show plexRecord;
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/toast_harness.dart';

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
}
