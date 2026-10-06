import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/node_registration.dart';
import 'package:player/domain/sources/source_error.dart';

import '../sources/mydia/fake_mydia_client.dart';
import '../sources/mydia/fake_mydia_transport.dart';

void main() {
  group('NodeRegistration', () {
    test('sends the host node id to the server', () async {
      final server = FakeMydiaTransport();
      server.handlers['RegisterDeviceNode'] = (_) => {
            'registerDeviceNode': {'id': 'device-1', 'nodeId': 'abc123'},
          };

      final registration = NodeRegistration(
        client: fakeMydiaClient(server),
        nodeId: () async => 'abc123',
      );

      expect(await registration.register(), isTrue);
      expect(server.calls, hasLength(1));
      expect(server.calls.single.vars, {'nodeId': 'abc123'});
    });

    test('reports failure rather than throwing when there is no node id',
        () async {
      final server = FakeMydiaTransport();

      final registration = NodeRegistration(
        client: fakeMydiaClient(server),
        nodeId: () async => null,
      );

      // A player that never started its host is not an error. It simply cannot
      // be controlled, and the picker will not list it.
      expect(await registration.register(), isFalse);
      expect(server.calls, isEmpty, reason: 'no node id means no round trip');
    });

    test('reports failure when the server rejects the node id', () async {
      final server = FakeMydiaTransport();
      server.handlers['RegisterDeviceNode'] =
          (_) => throw const SourceException.server('Invalid node ID');

      final registration = NodeRegistration(
        client: fakeMydiaClient(server),
        nodeId: () async => 'nope',
      );

      expect(await registration.register(), isFalse);
    });

    test('reports failure when the server echoes a different node id',
        () async {
      final server = FakeMydiaTransport();
      server.handlers['RegisterDeviceNode'] = (_) => {
            'registerDeviceNode': {'id': 'device-1', 'nodeId': 'other'},
          };

      final registration = NodeRegistration(
        client: fakeMydiaClient(server),
        nodeId: () async => 'abc123',
      );

      expect(await registration.register(), isFalse);
    });

    test('reports failure rather than throwing when nodeId() throws', () async {
      final server = FakeMydiaTransport();

      final registration = NodeRegistration(
        client: fakeMydiaClient(server),
        nodeId: () async => throw Exception('host not started'),
      );

      expect(await registration.register(), isFalse);
      expect(server.calls, isEmpty,
          reason: 'a throwing nodeId() means no round trip');
    });

    test('reports failure rather than throwing when the server is unreachable',
        () async {
      final server = FakeMydiaTransport();
      server.unreachable = true;

      final registration = NodeRegistration(
        client: fakeMydiaClient(server),
        nodeId: () async => 'abc123',
      );

      expect(await registration.register(), isFalse);
    });
  });
}
