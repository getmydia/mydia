import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/cert_storage.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  test('clearAll removes the pinned fingerprints', () async {
    final storage = MockAuthStorage();
    final certs = CertStorage(storage: storage);

    await certs.storeFingerprint('instance-1', 'aa:bb:cc');

    await certs.clearAll();

    expect(storage.containsKey('cert_fingerprints'), isFalse);
  });
}
