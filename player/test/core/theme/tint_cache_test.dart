import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_colors.dart';
import 'package:player/core/theme/ambient_tint/tint_cache.dart';

AmbientTintColors _c(int v) => AmbientTintColors(
      ground: Color(0xFF000000 | v),
      surface: Color(0xFF000000 | v),
    );

void main() {
  test('evicts the least recently used entry', () {
    final cache = TintCache(capacity: 2)
      ..put('a', _c(1))
      ..put('b', _c(2));
    expect(cache.get('a'), _c(1)); // a is now most recent
    cache.put('c', _c(3));
    expect(cache.get('b'), isNull);
    expect(cache.get('a'), _c(1));
    expect(cache.get('c'), _c(3));
    expect(cache.length, 2);
  });

  test('defaults to 200 entries', () {
    final cache = TintCache();
    for (var i = 0; i < 250; i++) {
      cache.put('$i', _c(i));
    }
    expect(cache.length, 200);
    expect(cache.get('0'), isNull);
    expect(cache.get('249'), isNotNull);
  });
}
