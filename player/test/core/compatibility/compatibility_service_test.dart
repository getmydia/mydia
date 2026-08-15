import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/compatibility/compatibility_service.dart';

import '../../test_utils/stub_graphql_client.dart';

/// A well-formed response. Every object needs __typename, the root included,
/// or the normalized cache refuses the write and it surfaces as hasException.
Map<String, dynamic> okResponse({
  String version = '0.9.0',
  String min = '0.9.0',
  String recommended = '0.9.0',
}) =>
    {
      '__typename': 'RootQueryType',
      'serverCompatibility': {
        '__typename': 'ServerCompatibility',
        'version': version,
        'minPlayerVersion': min,
        'recommendedPlayerVersion': recommended,
      },
    };

void main() {
  group('CompatibilityService.fetch', () {
    test('returns the server info on a good response', () async {
      final link = StubLink.responses([
        okResponse(version: '0.10.0', min: '0.9.0', recommended: '0.10.0'),
      ]);
      final service = CompatibilityService(stubClient(link));

      final info = await service.fetch();

      expect(info, isNotNull);
      expect(info!.version, '0.10.0');
      expect(info.minPlayerVersion, '0.9.0');
      expect(info.recommendedPlayerVersion, '0.10.0');
    });

    test('returns null when the client is unavailable', () async {
      expect(await CompatibilityService(null).fetch(), isNull);
    });

    test(
        'returns null on a GraphQL error, which is what a pre-feature server gives',
        () async {
      // A server predating this field rejects the whole document:
      // "Cannot query field \"serverCompatibility\"".
      final link = StubLink.responses([
        graphqlErrorResponse('Cannot query field "serverCompatibility"'),
      ]);

      expect(await CompatibilityService(stubClient(link)).fetch(), isNull);
    });

    test('returns null on a transport failure', () async {
      final link = StubLink.responses([Exception('connection refused')]);

      expect(await CompatibilityService(stubClient(link)).fetch(), isNull);
    });

    test('returns null when the root field is null', () async {
      final link = StubLink.responses([
        {'__typename': 'RootQueryType', 'serverCompatibility': null},
      ]);

      expect(await CompatibilityService(stubClient(link)).fetch(), isNull);
    });
  });
}
