import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  group('AuthService.storageDegraded', () {
    test('is false when storage is persisting normally', () {
      final storage = MockAuthStorage();
      final service = AuthService(storage: storage);

      expect(service.storageDegraded, isFalse);
    });

    test('reflects storage that cannot persist', () {
      final storage = MockAuthStorage()..degradedValue = true;
      final service = AuthService(storage: storage);

      expect(service.storageDegraded, isTrue);
    });
  });
}
