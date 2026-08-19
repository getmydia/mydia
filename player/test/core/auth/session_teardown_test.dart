import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/session_teardown.dart';

import '../../test_utils/mock_auth_storage.dart';

/// Every key a signed-in, paired device holds, plus the one that must survive.
const _signedIn = {
  'auth_token': 'tok',
  'server_url': 'https://mydia.local',
  'user_id': 'u1',
  'username': 'admin',
  'relay_url': 'https://relay.mydia.dev',
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
  'cert_fingerprints': '{"inst-1":"aa:bb:cc"}',
  'default_quality': '1080p',
  'auto_skip_segments': 'true',
  'library_sort_movies': 'YEAR:ASC',
  'library_sort_tvShows': 'RATING:DESC',
  'diagnostics_last_direct_attempt': '2026-01-01T00:00:00.000Z',
  'diagnostics_direct_url_errors': '{"https://mydia.local":{}}',
  'device_id': 'stable-id',
};

void main() {
  group('bestEffort', () {
    test('swallows a step that throws', () async {
      await expectLater(
        bestEffort('boom', () async => throw Exception('keyring unavailable')),
        completes,
      );
    });

    test('gives up on a step that never completes', () async {
      final stuck = Completer<void>();

      await expectLater(
        bestEffort('stuck', () => stuck.future,
            timeout: const Duration(milliseconds: 50)),
        completes,
      );

      expect(stuck.isCompleted, isFalse);
    });
  });

  group('SessionTeardown', () {
    test('erases every server-scoped credential', () async {
      final storage = MockAuthStorage()..seedData(_signedIn);

      await SessionTeardown(storage: storage).run();

      expect(storage.contents, {'device_id': 'stable-id'});
    });

    test('keeps going when the keychain refuses one delete', () async {
      // The macOS failure mode. One refused delete must not strand the rest.
      final storage = MockAuthStorage()
        ..seedData(_signedIn)
        ..failDeleteKeys.add('library_sort_movies');

      await SessionTeardown(storage: storage).run();

      expect(storage.containsKey('pairing_device_token'), isFalse);
      expect(storage.containsKey('auth_token'), isFalse);
      expect(storage.containsKey('device_id'), isTrue);
    });

    test('erases the pairing even when the session step fails entirely',
        () async {
      final storage = MockAuthStorage()
        ..seedData(_signedIn)
        ..failDeleteKeys.addAll({'auth_token', 'server_url'});

      await SessionTeardown(storage: storage).run();

      expect(storage.containsKey('pairing_device_token'), isFalse);
    });
  });
}
