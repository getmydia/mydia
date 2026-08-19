import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/channels/pairing_service.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  test('clearCredentials removes every pairing key', () async {
    final storage = MockAuthStorage()
      ..seedData({
        'pairing_server_url': 'p2p://server',
        'pairing_device_id': 'dev-1',
        'pairing_media_token': 'media-tok',
        'pairing_media_token_expiry': '2026-01-01T00:00:00.000Z',
        'pairing_access_token': 'access-tok',
        'pairing_device_token': 'device-tok',
        'pairing_direct_urls': '["https://mydia.local"]',
        'pairing_cert_fingerprint': 'aa:bb:cc',
        'pairing_instance_name': 'Home',
        'server_public_key': 'pubkey',
        'instance_id': 'inst-1',
        'server_node_addr': 'node-addr',
      });

    await PairingService(authStorage: storage).clearCredentials();

    expect(storage.contents, isEmpty);
  });

  test('clearCredentials leaves the device identity alone', () async {
    // device_id is this installation's stable identity. Wiping it makes the
    // next pairing create a second device row on the server.
    final storage = MockAuthStorage()
      ..seedData({'device_id': 'stable-id', 'pairing_device_token': 'tok'});

    await PairingService(authStorage: storage).clearCredentials();

    expect(storage.contents, {'device_id': 'stable-id'});
  });

  test(
      'an early refused delete does not strand pairing_device_token '
      '(the key that mints fresh access tokens)', () async {
    final storage = MockAuthStorage()
      ..seedData({
        'pairing_server_url': 'p2p://server',
        'pairing_device_id': 'dev-1',
        'pairing_media_token': 'media-tok',
        'pairing_media_token_expiry': '2026-01-01T00:00:00.000Z',
        'pairing_access_token': 'access-tok',
        'pairing_device_token': 'device-tok',
        'pairing_direct_urls': '["https://mydia.local"]',
        'pairing_cert_fingerprint': 'aa:bb:cc',
        'pairing_instance_name': 'Home',
        'server_public_key': 'pubkey',
        'instance_id': 'inst-1',
        'server_node_addr': 'node-addr',
      })
      // The first delete in the sequence refuses. Sequential awaits would
      // abort here and strand every key after it, pairing_device_token
      // included.
      ..failDeleteKeys.add('pairing_server_url');

    // The aggregate rejection is expected. Production wraps this call in
    // bestEffort; the test only cares what happened to storage before the
    // rejection surfaced.
    await expectLater(
      PairingService(authStorage: storage).clearCredentials(),
      throwsA(anything),
    );

    expect(storage.containsKey('pairing_device_token'), isFalse);
    expect(storage.contents.keys.toSet(), {'pairing_server_url'});
  });
}
