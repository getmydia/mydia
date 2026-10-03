import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';

void main() {
  test('accepts letters, digits, dash and underscore', () {
    expect(isValidSourceIdComponent('owner'), isTrue);
    expect(isValidSourceIdComponent('a1b2-C3_d4'), isTrue);
    expect(
      isValidSourceIdComponent('0f3c9a7e1b2d4c5f6a7b8c9d0e1f2a3b4c5d6e7f'),
      isTrue,
    );
  });

  test('rejects separators, path characters and the empty string', () {
    for (final bad in ['', 'a:b', 'a/b', 'a b', 'a%3Ab', 'a.b']) {
      expect(isValidSourceIdComponent(bad), isFalse, reason: bad);
    }
  });
}
