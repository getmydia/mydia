import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';

void main() {
  group('SourceId', () {
    test('compares by value', () {
      expect(const SourceId('a'), const SourceId('a'));
      expect(const SourceId('a').hashCode, const SourceId('a').hashCode);
      expect(const SourceId('a') == const SourceId('b'), isFalse);
    });
  });

  group('Source.id', () {
    test('joins account, profile and server ids', () {
      const account = ProviderAccount(
        id: 'acc1',
        kind: SourceKind.plex,
        displayName: 'someone@example.test',
        storageNamespace: 'source/acc1',
        activeProfileId: 'owner',
      );
      const profile = SourceProfile(
        id: 'owner',
        accountId: 'acc1',
        name: 'Owner',
        isOwner: true,
      );
      const server = SourceServer(
        id: 'srv9',
        accountId: 'acc1',
        profileId: 'owner',
        name: 'Basement',
      );
      const source = Source(account: account, profile: profile, server: server);

      expect(source.id, const SourceId('acc1:owner:srv9'));
      expect(source.kind, SourceKind.plex);
      expect(source.displayName, 'Basement');
    });
  });
}
