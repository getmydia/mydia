// Pairing adds sources in quick succession while the router listens for how
// many servers All servers includes. That listener must not keep the media
// source instances mounted, or a refresh inside the scheduler flush rebuilds
// the list twice in one frame.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/router/app_router.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../test_utils/mock_auth_storage.dart';

SourceAccountRecord _record(String id) => SourceAccountRecord(
      account: ProviderAccount(
        id: id,
        kind: SourceKind.plex,
        displayName: 'Server $id',
        storageNamespace: 'source/$id',
        activeProfileId: 'owner',
      ),
      profiles: [
        SourceProfile(id: 'owner', accountId: id, name: 'Owner', isOwner: true),
      ],
      servers: [
        SourceServer(
            id: 's1',
            accountId: id,
            profileId: 'owner',
            name: 'Server $id',
            machineIdentifier: 's1'),
      ],
      addedAtMs: 1700000000000,
    );

void main() {
  testWidgets('adding sources in a burst does not rebuild a provider twice',
      (tester) async {
    final store = InMemorySourceStore();
    var mediaBuilt = 0;
    final container = ProviderContainer(overrides: [
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(MockAuthStorage())),
      authServiceProvider
          .overrideWithValue(AuthService(storage: MockAuthStorage())),
      mediaSourceProvider.overrideWith((ref, id) {
        mediaBuilt++;
        return null;
      }),
    ]);
    addTearDown(container.dispose);
    final router = container.read(appRouterProvider);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await container.read(sourceRecordsProvider.future);
    await tester.pumpAndSettle();

    final notifier = container.read(sourceRecordsProvider.notifier);
    // Writes land back to back, with no frame between them.
    await Future.wait([
      for (final id in ['a', 'b', 'c']) notifier.putAccount(_record(id)),
    ]);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The router decides from a count; it never builds a media source.
    expect(container.read(allServersIncludedCountProvider), 3);
    expect(mediaBuilt, 0);
  });
}
