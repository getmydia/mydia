import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart';

/// Stands in for startup, which the unit suite cannot run: a real
/// `initialize()` resolves relays over the network and loads the native
/// bridge. This one finishes when the test says so and never builds a host.
class _SlowStartP2pService extends P2pService {
  final started = Completer<void>();
  int initializeCalls = 0;

  @override
  Future<void> initialize({List<String>? relayUrls}) async {
    initializeCalls++;
    await started.future;
  }
}

void main() {
  group('P2pService request senders', () {
    test('a GraphQL request sent during startup waits for it', () async {
      // MyApp starts initialize() in a microtask, and the first requests go
      // out while it is still resolving relays. Failing them outright lost
      // the launch-time compatibility check, which nothing retries.
      final service = _SlowStartP2pService();
      addTearDown(service.dispose);

      Object? error;
      var settled = false;
      unawaited(service
          .sendGraphQLRequest(peer: 'a' * 64, query: '{ __typename }')
          .then((_) {}, onError: (Object e) {
        error = e;
      }).whenComplete(() => settled = true));

      await pumpEventQueue();
      expect(service.initializeCalls, 1);
      expect(settled, isFalse, reason: 'must wait for startup to finish');

      service.started.complete();
      await pumpEventQueue();

      expect(settled, isTrue);
      expect('$error', contains('P2P host initialization failed'),
          reason: 'startup produced no host here, so the request fails only '
              'after startup has finished');
    });

    test('an HLS request sent during startup waits for it', () async {
      final service = _SlowStartP2pService();
      addTearDown(service.dispose);

      final result = service.sendHlsRequest(
        peer: 'a' * 64,
        sessionId: 'session',
        path: 'index.m3u8',
      );

      await pumpEventQueue();
      expect(service.initializeCalls, 1);

      service.started.complete();

      await expectLater(
        result,
        throwsA(
            predicate((e) => '$e'.contains('P2P host initialization failed'))),
      );
    });
  });
}
