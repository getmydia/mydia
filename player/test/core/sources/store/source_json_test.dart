import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';

SourceAccountRecord plexRecord({bool gone = false}) => SourceAccountRecord(
      account: const ProviderAccount(
        id: 'acc1',
        kind: SourceKind.plex,
        displayName: 'quill',
        storageNamespace: 'source/acc1',
        activeProfileId: 'owner',
      ),
      profiles: const [
        SourceProfile(
            id: 'owner', accountId: 'acc1', name: 'Quill', isOwner: true),
      ],
      servers: [
        SourceServer(
          id: 'abc123',
          accountId: 'acc1',
          profileId: 'owner',
          name: 'Attic',
          machineIdentifier: 'abc123',
          owned: false,
          gone: gone,
          httpsRequired: true,
          connections: [
            ServerConnection(
              uri: Uri.parse('https://10-0-0-5.abc123.plex.direct:32400'),
              local: true,
            ),
            ServerConnection(
              uri: Uri.parse('https://relay.example.test:8443'),
              relay: true,
            ),
          ],
        ),
      ],
      addedAtMs: 1700000000000,
    );

void main() {
  test('round-trips through JSON', () {
    final record = plexRecord();
    final copy = SourceAccountRecord.fromJson(record.toJson());
    expect(copy.account, record.account);
    expect(copy.profiles, record.profiles);
    expect(copy.servers, record.servers);
    expect(copy.addedAtMs, record.addedAtMs);
  });

  test('lists a source per server that is not gone', () {
    expect(plexRecord().sources.single.id, const SourceId('acc1:owner:abc123'));
    expect(plexRecord(gone: true).sources, isEmpty);
  });

  test('rejects an id that would break SourceId', () {
    expect(
      () => SourceAccountRecord(
        account: const ProviderAccount(
          id: 'a:b',
          kind: SourceKind.stash,
          displayName: 'x',
          storageNamespace: 'source/a',
          activeProfileId: 'owner',
        ),
        profiles: const [],
        servers: const [],
        addedAtMs: 0,
      ),
      throwsArgumentError,
    );
  });

  test('needsReauth and connections take part in equality', () {
    const a = ProviderAccount(
      id: 'acc1',
      kind: SourceKind.plex,
      displayName: 'quill',
      storageNamespace: 'source/acc1',
      activeProfileId: 'owner',
    );
    expect(a == a.copyWith(needsReauth: true), isFalse);
    final server = plexRecord().servers.single;
    expect(server == server.copyWith(connections: const []), isFalse);
  });

  test('rejects a server or profile whose own account or profile id is unsafe',
      () {
    final record = plexRecord();
    for (final bad in const [
      SourceServer(
          id: 'abc123', accountId: 'acc1', profileId: 'a/b', name: 'Attic'),
      SourceServer(
          id: 'abc123', accountId: 'a:b', profileId: 'owner', name: 'Attic'),
    ]) {
      expect(
        () => SourceAccountRecord(
          account: record.account,
          profiles: record.profiles,
          servers: [bad],
          addedAtMs: 0,
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => SourceAccountRecord(
        account: record.account,
        profiles: const [
          SourceProfile(id: 'owner', accountId: 'a b', name: 'Q', isOwner: true)
        ],
        servers: const [],
        addedAtMs: 0,
      ),
      throwsArgumentError,
    );
  });

  test('an old record reads with no PIN flags and its servers as chosen', () {
    final json = plexRecord().toJson();
    (json['profiles'] as List)
        .cast<Map<String, dynamic>>()
        .single
        .remove('protected');
    json.remove('chosenServerIds');
    final record = SourceAccountRecord.fromJson(json);
    expect(record.profiles.single.protected, isFalse);
    expect(record.chosenServerIds, isNull);
    expect(record.chosenServers, ['abc123']);
  });

  test('PIN flags and the chosen servers round-trip', () {
    final record = plexRecord().copyWith(
      profiles: const [
        SourceProfile(
            id: 'owner', accountId: 'acc1', name: 'Quill', isOwner: true),
        SourceProfile(
            id: 'kid0001',
            accountId: 'acc1',
            name: 'Pip',
            isOwner: false,
            protected: true),
      ],
      chosenServerIds: ['abc123', 'zz99'],
    );
    final copy = SourceAccountRecord.fromJson(record.toJson());
    expect(copy.profiles, record.profiles);
    expect(copy.profiles.last.protected, isTrue);
    expect(copy.chosenServers, ['abc123', 'zz99']);
  });

  test('copyWith can change the active profile', () {
    final account = plexRecord().account.copyWith(activeProfileId: 'kid0001');
    expect(account.activeProfileId, 'kid0001');
    expect(account.displayName, 'quill');
  });

  test('rejects a chosen server id that would break SourceId', () {
    expect(() => plexRecord().copyWith(chosenServerIds: ['has:colon']),
        throwsArgumentError);
  });
}
