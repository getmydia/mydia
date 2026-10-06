import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/collection.dart';
import 'package:player/domain/sources/item.dart';

void main() {
  test('SourceCollection survives a JSON round trip', () {
    const c = SourceCollection(
      sourceId: SourceId('acc1:owner:aa11'),
      id: 'c7',
      name: 'Harbor Nights',
      description: 'Rainy films',
      smart: true,
      itemCount: 12,
      posters: [ArtworkRef('/p/1.jpg'), ArtworkRef('/p/2.jpg')],
    );
    final json = jsonDecode(jsonEncode(c.toJson())) as Map<String, Object?>;
    expect(SourceCollection.fromJson(json).toJson(), c.toJson());
  });
}
