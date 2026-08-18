import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/local_proxy_service.dart';

/// The call site these tests hold the proxy as. Each test builds its own
/// service, so one shared identity is enough to stand for "somebody needs
/// this up"; none of them is about ownership itself.
final testOwner = Object();

void main() {
  group('LocalProxyService LAN access', () {
    test('resolveLanAddress returns a non-loopback IPv4 address or null',
        () async {
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
      await service.start(owner: testOwner, targetPeer: 'peer-1');
      addTearDown(service.shutdown);

      final url = service.buildHlsUrl('sess-1');

      expect(url, startsWith('http://127.0.0.1:'));
      expect(url, endsWith('/hls/sess-1/index.m3u8'));
      expect(url, isNot(contains('/g/')));
    });

    test('enabling LAN access exposes a token-prefixed non-loopback URL',
        () async {
      final service = LocalProxyService.forTesting();
      await service.start(owner: testOwner, targetPeer: 'peer-1');
      addTearDown(service.shutdown);

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
      await service.start(owner: testOwner, targetPeer: 'peer-1');
      addTearDown(service.shutdown);

      await service.setLanAccess(true);
      if (!service.isLanAccessible) return;

      final response = await service.debugHandlePath('/hls/sess-1/index.m3u8');

      expect(response, 403);
    });

    test('enabling LAN access on a proxy that was never started stays closed',
        () async {
      // `isLanAccessible` used to guard a different set of fields than
      // `lanBaseUrl`, so this left the service claiming LAN reachability with
      // no listener at all — and the cast error message then told the user to
      // open "port 0" in their firewall.
      final service = LocalProxyService.forTesting();

      await service.setLanAccess(true);

      expect(service.isLanAccessible, isFalse);
      expect(service.lanBaseUrl, isNull);
      expect(service.port, 0);
    });

    test('a VPN or container interface is never advertised to a receiver', () {
      for (final name in const [
        'utun0',
        'ipsec1',
        'awdl0',
        'docker0',
        'br-1a2b3c',
        'veth0',
        'wg0',
        'vmnet8',
      ]) {
        expect(LocalProxyService.isNonLanInterface(name), isTrue,
            reason: '$name is not reachable from a TV');
      }

      for (final name in const ['en0', 'eth0', 'wlan0', 'wlp3s0']) {
        expect(LocalProxyService.isNonLanInterface(name), isFalse);
      }
    });

    test('private IPv4 ranges are recognised', () {
      expect(LocalProxyService.isPrivateIPv4('192.168.1.20'), isTrue);
      expect(LocalProxyService.isPrivateIPv4('10.0.0.4'), isTrue);
      expect(LocalProxyService.isPrivateIPv4('172.16.5.1'), isTrue);
      expect(LocalProxyService.isPrivateIPv4('172.31.255.254'), isTrue);

      expect(LocalProxyService.isPrivateIPv4('172.32.0.1'), isFalse);
      expect(LocalProxyService.isPrivateIPv4('8.8.8.8'), isFalse);
      expect(LocalProxyService.isPrivateIPv4('not-an-ip'), isFalse);
    });

    test('disabling LAN access returns the proxy to loopback', () async {
      final service = LocalProxyService.forTesting();
      await service.start(owner: testOwner, targetPeer: 'peer-1');
      addTearDown(service.shutdown);

      await service.setLanAccess(true);
      await service.setLanAccess(false);

      expect(service.isLanAccessible, isFalse);
      expect(service.lanBaseUrl, isNull);
      expect(service.buildHlsUrl('s').contains('/g/'), isFalse);
    });
  });
}
