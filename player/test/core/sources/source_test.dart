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

  group('SourceServer.serviceName', () {
    const base = SourceServer(
      id: 'srv',
      accountId: 'acc',
      profileId: 'p',
      name: 'Nas',
    );

    test('server_json_round_trips_service_name', () {
      final server = SourceServer.fromJson(
        base.copyWith(serviceName: 'NAS').toJson(),
      );
      expect(server.serviceName, 'NAS');
    });

    test('server_json_omits_null_service_name', () {
      expect(base.toJson().containsKey('serviceName'), isFalse);
      expect(SourceServer.fromJson(base.toJson()).serviceName, isNull);
    });

    test('copy_with_can_clear_service_name', () {
      final named = base.copyWith(serviceName: 'NAS');
      expect(named.copyWith().serviceName, 'NAS');
      expect(named.copyWith(clearServiceName: true).serviceName, isNull);
      expect(named == base, isFalse);
    });
  });
}
