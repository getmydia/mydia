/// A stored Mydia account, the way every Mydia server is represented once the
/// startup migration has turned the old sign-in into an ordinary account.
library;

import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_gql_transport.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/domain/sources/item.dart';

import '../core/sources/mydia/fake_mydia_client.dart';

const testMydiaSource = Source(
  account: ProviderAccount(
    id: 'macct',
    kind: SourceKind.mydia,
    displayName: 'Harborview',
    storageNamespace: 'source/macct',
    activeProfileId: 'owner',
  ),
  profile: SourceProfile(
      id: 'owner', accountId: 'macct', name: 'Owner', isOwner: true),
  server: SourceServer(
      id: 'inst-1', accountId: 'macct', profileId: 'owner', name: 'Harborview'),
);

/// [testMydiaSource]'s id.
const testMydiaSourceId = SourceId('macct:owner:inst-1');

ItemRef testMydiaRef(ItemKind kind, String id) =>
    ItemRef(sourceId: testMydiaSourceId, kind: kind, externalId: id);

/// A [MydiaSource] over [transport], as [testMydiaSource] with [accountId].
MydiaSource testMydiaSourceOver(
  MydiaGqlTransport transport, {
  MydiaCredentials creds =
      const MydiaCredentials(instanceId: 'test', accessToken: 'access'),
  String accountId = 'macct',
}) =>
    MydiaSource(
      source: Source(
        account: ProviderAccount(
          id: accountId,
          kind: SourceKind.mydia,
          displayName: 'Harborview',
          storageNamespace: 'source/$accountId',
          activeProfileId: 'owner',
        ),
        profile: SourceProfile(
            id: 'owner', accountId: accountId, name: 'Owner', isOwner: true),
        server: SourceServer(
            id: 'inst-1',
            accountId: accountId,
            profileId: 'owner',
            name: 'Harborview'),
      ),
      client: fakeMydiaClient(transport, creds: creds),
    );

/// [testMydiaSource] as the account record the store holds.
SourceAccountRecord testMydiaRecord() => SourceAccountRecord(
      account: testMydiaSource.account,
      profiles: [testMydiaSource.profile],
      servers: [testMydiaSource.server],
      addedAtMs: 1,
    );
