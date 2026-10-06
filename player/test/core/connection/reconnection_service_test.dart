import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/reconnection_service.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  test('reconnect reports the instance id it was given, not a stored key',
      () async {
    final storage = MockAuthStorage()
      ..seedData({
        'pairing_direct_urls': '["https://mydia.example.test"]',
        'instance_id': 'stale-key',
      });
    final service =
        ReconnectionService(authStorage: storage, instanceId: 'inst-9');

    final result = await service.reconnect();

    expect(result.success, isTrue);
    expect(result.session?.instanceId, 'inst-9');
  });
}
