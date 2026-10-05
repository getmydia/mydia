import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';

void main() {
  ArtworkRequest? resolve(String path) =>
      absoluteArtworkRequest(SourceId.legacyMydia, ArtworkRef(path), 300);

  test('an absolute artwork URL resolves with no headers', () {
    final r = resolve('https://media.example.test/p/1.jpg');
    expect(r!.url, 'https://media.example.test/p/1.jpg');
    expect(r.headers, isEmpty);
    expect(r.cacheKey, 'mydia|https://media.example.test/p/1.jpg|300');
  });

  test('an artwork URL carrying credentials resolves to nothing', () {
    expect(resolve('https://user:pw@media.example.test/p.jpg'), isNull);
  });

  test('a relative path resolves to nothing', () {
    expect(resolve('/p/1.jpg'), isNull);
  });
}
