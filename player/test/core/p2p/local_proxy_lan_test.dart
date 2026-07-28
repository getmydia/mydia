import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/local_proxy_service.dart';

void main() {
  group('LocalProxyService LAN access', () {
    test('resolveLanAddress returns a non-loopback IPv4 address or null', () async {
      final address = await LocalProxyService.resolveLanAddress();

      if (address != null) {
        expect(address, isNot(startsWith('127.')));
        expect(address.split('.').length, 4);
      }
    });

    test('lanBaseUrl is null and isLanAccessible false before enabling', () {
      final service = LocalProxyService.forTesting();

      expect(service.isLanAccessible, isFalse);
      expect(service.lanBaseUrl, isNull);
    });

    test('buildHlsUrl uses loopback with no token prefix by default', () async {
      final service = LocalProxyService.forTesting();
      await service.start(targetPeer: 'peer-1');
      addTearDown(service.stop);

      final url = service.buildHlsUrl('sess-1');

      expect(url, startsWith('http://127.0.0.1:'));
      expect(url, endsWith('/hls/sess-1/index.m3u8'));
      expect(url, isNot(contains('/g/')));
    });

    test('enabling LAN access exposes a token-prefixed non-loopback URL', () async {
      final service = LocalProxyService.forTesting();
      await service.start(targetPeer: 'peer-1');
      addTearDown(service.stop);

      await service.setLanAccess(true);

      if (!service.isLanAccessible) {
        // No usable LAN interface in this environment (common in CI sandboxes).
        return;
      }

      final base = service.lanBaseUrl;
      expect(base, isNotNull);
      expect(base, isNot(contains('127.0.0.1')));
      expect(base, contains('/g/'));
      expect(service.buildHlsUrl('sess-1'), startsWith(base!));
    });

    test('requests without the token prefix are rejected when LAN-exposed',
        () async {
      final service = LocalProxyService.forTesting();
      await service.start(targetPeer: 'peer-1');
      addTearDown(service.stop);

      await service.setLanAccess(true);
      if (!service.isLanAccessible) return;

      final response = await service.debugHandlePath('/hls/sess-1/index.m3u8');

      expect(response, 403);
    });

    test('disabling LAN access returns the proxy to loopback', () async {
      final service = LocalProxyService.forTesting();
      await service.start(targetPeer: 'peer-1');
      addTearDown(service.stop);

      await service.setLanAccess(true);
      await service.setLanAccess(false);

      expect(service.isLanAccessible, isFalse);
      expect(service.lanBaseUrl, isNull);
      expect(service.buildHlsUrl('s').contains('/g/'), isFalse);
    });
  });
}
