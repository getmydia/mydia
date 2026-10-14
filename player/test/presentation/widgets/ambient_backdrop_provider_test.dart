import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/ambient_backdrop_provider.dart';

void main() {
  test('equality includes headers and cacheKey', () {
    const a = BackdropSource(
      imageUrl: 'https://art/x.jpg',
      id: 'x',
      headers: {'X-Token': 'a'},
      cacheKey: 'k',
    );
    expect(
      a,
      const BackdropSource(
        imageUrl: 'https://art/x.jpg',
        id: 'x',
        headers: {'X-Token': 'a'},
        cacheKey: 'k',
      ),
    );
    expect(
      a == const BackdropSource(imageUrl: 'https://art/x.jpg', id: 'x'),
      isFalse,
    );
    expect(
      a.hashCode,
      const BackdropSource(
        imageUrl: 'https://art/x.jpg',
        id: 'x',
        headers: {'X-Token': 'a'},
        cacheKey: 'k',
      ).hashCode,
    );
  });
}
