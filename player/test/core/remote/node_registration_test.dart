import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/node_registration.dart';

import '../../test_utils/stub_graphql_client.dart';

void main() {
  group('NodeRegistration', () {
    test('sends the host node id to the server', () async {
      final link = StubLink.responses([
        {
          '__typename': 'Mutation',
          'registerDeviceNode': {
            '__typename': 'RemoteDevice',
            'id': 'device-1',
            'nodeId': 'abc123',
          },
        },
      ]);

      final registration = NodeRegistration(
        client: stubClient(link),
        nodeId: () async => 'abc123',
      );

      expect(await registration.register(), isTrue);
      expect(link.requests, hasLength(1));
    });

    test('reports failure rather than throwing when there is no node id',
        () async {
      // Never called, but StubLink.responses asserts a non-empty script.
      final link = StubLink.responses([
        <String, dynamic>{'__typename': 'Mutation'},
      ]);

      final registration = NodeRegistration(
        client: stubClient(link),
        nodeId: () async => null,
      );

      // A player that never started its host is not an error. It simply cannot
      // be controlled, and the picker will not list it.
      expect(await registration.register(), isFalse);
      expect(link.requests, isEmpty, reason: 'no node id means no round trip');
    });

    test('reports failure when the server rejects the node id', () async {
      final link = StubLink.responses([
        graphqlErrorResponse('Invalid node ID'),
      ]);

      final registration = NodeRegistration(
        client: stubClient(link),
        nodeId: () async => 'nope',
      );

      expect(await registration.register(), isFalse);
    });

    test('reports failure rather than throwing when nodeId() throws', () async {
      // Never called: the exception surfaces before any request is built.
      final link = StubLink.responses([
        <String, dynamic>{'__typename': 'Mutation'},
      ]);

      final registration = NodeRegistration(
        client: stubClient(link),
        nodeId: () async => throw Exception('host not started'),
      );

      expect(await registration.register(), isFalse);
      expect(link.requests, isEmpty,
          reason: 'a throwing nodeId() means no round trip');
    });

    test('reports failure rather than throwing when the mutate call throws',
        () async {
      final link = StubLink.responses([Exception('boom')]);

      final registration = NodeRegistration(
        client: stubClient(link),
        nodeId: () async => 'abc123',
      );

      expect(await registration.register(), isFalse);
    });
  });
}
