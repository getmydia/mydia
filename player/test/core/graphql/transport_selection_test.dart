import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/graphql_provider.dart';

void main() {
  group('isInstanceHostedWeb', () {
    test('is false on native, where transport is always p2p or direct URL', () {
      // kIsWeb is false in the VM test runner, so this pins the native branch.
      expect(isInstanceHostedWeb, isFalse);
    });
  });
}
