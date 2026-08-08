import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/media_proxy.dart';

/// Behavior every MediaProxy must have, run against each implementation.
///
/// Both platforms serve the same URL contract, so both must satisfy the same
/// tests. Anything asserted here is a promise the HLS and download call sites
/// rely on regardless of platform.
void mediaProxyConformanceTests(String name, MediaProxy Function() create) {
  group('$name conformance', () {
    test('is not running before start', () {
      expect(create().isRunning, isFalse);
    });

    test('baseUrl has no trailing slash so callers can append /hls/...',
        () async {
      final proxy = create();
      await proxy.start(targetPeer: 'peer-1', authToken: 'token-1');
      addTearDown(proxy.stop);
      expect(proxy.baseUrl, isNot(endsWith('/')));
    });

    test('stop is idempotent', () async {
      final proxy = create();
      await proxy.start(targetPeer: 'peer-1', authToken: 'token-1');
      await proxy.stop();
      await proxy.stop();
      expect(proxy.isRunning, isFalse);
    });
  });
}
