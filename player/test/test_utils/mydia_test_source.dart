/// A stored Mydia account, the way every Mydia server is represented once the
/// startup migration has turned the old sign-in into an ordinary account.
library;

import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/domain/sources/item.dart';

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

/// [testMydiaSource] as the account record the store holds.
SourceAccountRecord testMydiaRecord() => SourceAccountRecord(
      account: testMydiaSource.account,
      profiles: [testMydiaSource.profile],
      servers: [testMydiaSource.server],
      addedAtMs: 1,
    );
