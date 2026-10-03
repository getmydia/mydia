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

  group('Source.legacyMydia', () {
    test('uses the fixed legacy id and the legacy namespace', () {
      final source = Source.legacyMydia();
      expect(source.id, SourceId.legacyMydia);
      expect(source.kind, SourceKind.mydia);
      expect(source.account.storageNamespace, kLegacyStorageNamespace);
      expect(source.profile.isOwner, isTrue);
      expect(source.displayName, 'Mydia');
    });

    test('two legacy sources are equal', () {
      expect(Source.legacyMydia(), Source.legacyMydia());
    });
  });

  group('Source.id for non-legacy accounts', () {
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
