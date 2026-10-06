import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_secrets.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';

class _Unauthenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.unauthenticated);
}

/// A Mydia account record, owner profile and one server, as login stores it.
SourceAccountRecord mydiaRecord(String instanceId, {int addedAtMs = 0}) {
  final accountId = 'm$instanceId';
  return SourceAccountRecord(
    account: ProviderAccount(
      id: accountId,
      kind: SourceKind.mydia,
      displayName: 'Server $instanceId',
      storageNamespace: 'source/$accountId',
      activeProfileId: 'owner',
    ),
    profiles: [
      SourceProfile(
          id: 'owner', accountId: accountId, name: 'Owner', isOwner: true),
    ],
    servers: [
      SourceServer(
        id: instanceId,
        accountId: accountId,
        profileId: 'owner',
        name: 'Server $instanceId',
      ),
    ],
    addedAtMs: addedAtMs,
  );
}

/// Store, secrets and a container over them. [accounts] maps an instance id to
/// the credentials stored for it, in the order they are added.
Future<
    ({
      ProviderContainer container,
      InMemorySourceStore store,
      MockAuthStorage storage,
    })> boundMydiaHarness(
  Map<String, MydiaCredentials> accounts, {
  List<Override> overrides = const [],
}) async {
  final store = InMemorySourceStore();
  final storage = MockAuthStorage();
  final secrets = SourceSecrets(storage);
  var order = 0;
  for (final MapEntry(key: instanceId, value: creds) in accounts.entries) {
    final record = mydiaRecord(instanceId, addedAtMs: order++);
    await store.putAccount(record);
    await writeMydiaCredentials(secrets, record.account, creds);
  }
  final container = ProviderContainer(overrides: [
    authStateProvider.overrideWith(_Unauthenticated.new),
    noDownloadsOverride,
    sourceStoreProvider.overrideWith((ref) async => store),
    sourceSecretsProvider.overrideWithValue(secrets),
    ...overrides,
  ]);
  return (container: container, store: store, storage: storage);
}
