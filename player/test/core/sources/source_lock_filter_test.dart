import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/lock/source_lock_controller.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../test_utils/mock_auth_storage.dart';
import 'store/source_json_test.dart' show plexRecord;

class _Authenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.authenticated);
}

class _Unlocked extends SourceLockController {
  @override
  bool build() => true;
}

Future<ProviderContainer> _container(SourceLock lock,
    {bool unlocked = false}) async {
  final store = InMemorySourceStore();
  await store.putAccount(plexRecord().copyWith(
      serverLocks: lock == SourceLock.none ? const {} : {'abc123': lock}));
  final c = ProviderContainer(overrides: [
    authStateProvider.overrideWith(_Authenticated.new),
    sourceStoreProvider.overrideWith((ref) async => store),
    sourceSecretsProvider.overrideWithValue(SourceSecrets(MockAuthStorage())),
    if (unlocked) sourceLockProvider.overrideWith(_Unlocked.new),
  ]);
  addTearDown(c.dispose);
  await c.read(sourceRecordsProvider.future);
  return c;
}

void main() {
  test('a hidden source is absent while locked', () async {
    final c = await _container(SourceLock.hidden);
    expect(c.read(thirdPartySourcesProvider), isEmpty);
    expect(c.read(sourcesProvider), [Source.legacyMydia()]);
    // One source left: the switcher (and any count it shows) disappears.
    expect(c.read(switchableSourcesProvider), isEmpty);
    expect(c.read(gatedSourceIdsProvider), hasLength(1));
  });

  test('a hidden source appears once unlocked', () async {
    final c = await _container(SourceLock.hidden, unlocked: true);
    expect(c.read(thirdPartySourcesProvider), hasLength(1));
    expect(c.read(gatedSourceIdsProvider), isEmpty);
    expect(c.read(windowSecureProvider), isTrue);
  });

  test('a locked source stays listed but gated', () async {
    final c = await _container(SourceLock.locked);
    final plex = c.read(thirdPartySourcesProvider).single;
    expect(c.read(gatedSourceIdsProvider), {plex.id});
    expect(c.read(sourceLocksProvider), {plex.id: SourceLock.locked});
    expect(c.read(windowSecureProvider), isFalse);
  });

  test('a gated pick falls back to the first ungated source', () async {
    final c = await _container(SourceLock.locked);
    final plex = c.read(thirdPartySourcesProvider).single;
    c.read(selectedSourceIdProvider.notifier).select(plex.id);
    expect(c.read(activeSourceIdProvider), SourceId.legacyMydia);
  });

  test('no locks, nothing gated', () async {
    final c = await _container(SourceLock.none);
    expect(c.read(gatedSourceIdsProvider), isEmpty);
    expect(c.read(windowSecureProvider), isFalse);
  });
}
