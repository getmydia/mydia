import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/all_servers_inclusion.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../test_utils/mock_auth_storage.dart';
import 'stash/stash_media_source_test.dart' show stashRecord;
import 'store/source_json_test.dart' show plexRecord;

class _Unauthenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.unauthenticated);
}

void main() {
  final plexSource = plexRecord().sources.single;
  final stashSource = stashRecord.sources.single;

  test('defaults: everything but Stash', () {
    expect(includedInAllServers(Source.legacyMydia(), const {}), isTrue);
    expect(includedInAllServers(plexSource, const {}), isTrue);
    expect(includedInAllServers(stashSource, const {}), isFalse);
  });

  test('a stored choice wins over the default', () {
    expect(includedInAllServers(stashSource, {stashSource.id: true}), isTrue);
    expect(includedInAllServers(plexSource, {plexSource.id: false}), isFalse);
  });

  group('allServersNeedSignInProvider', () {
    late InMemorySourceStore store;
    late ProviderContainer container;

    setUp(() {
      store = InMemorySourceStore();
      container = ProviderContainer(overrides: [
        authStateProvider.overrideWith(_Unauthenticated.new),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ]);
      addTearDown(container.dispose);
    });

    test('lists included sources flagged for sign-in, not excluded ones',
        () async {
      await store.putAccount(plexRecord());
      await container.read(sourceRecordsProvider.future);
      final notifier = container.read(sourceRecordsProvider.notifier);
      await notifier.markNeedsReauth('acc1', true);
      expect(container.read(allServersNeedSignInProvider).single.id,
          plexSource.id);

      await notifier.setIncludedInAllServers(plexSource.id, false);
      expect(container.read(allServersNeedSignInProvider), isEmpty);
    });
  });
}
