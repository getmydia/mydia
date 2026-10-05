import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';

void main() {
  final home =
      MydiaSource(source: Source.legacyMydia(), auth: const AsyncLoading());

  test('an absolute artwork URL resolves with no headers', () async {
    final r = await home.artwork(
        const ArtworkRef('https://media.example.test/p/1.jpg'),
        width: 300);
    expect(r!.url, 'https://media.example.test/p/1.jpg');
    expect(r.headers, isEmpty);
    expect(r.cacheKey, 'mydia|https://media.example.test/p/1.jpg|300');
  });

  test('an artwork URL carrying credentials resolves to nothing', () async {
    expect(
        await home.artwork(
            const ArtworkRef('https://user:pw@media.example.test/p.jpg'),
            width: 300),
        isNull);
  });

  test('a relative path resolves to nothing', () async {
    expect(
        await home.artwork(const ArtworkRef('/p/1.jpg'), width: 300), isNull);
  });
}
