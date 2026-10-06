import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/query_keys.dart';

void main() {
  test('the collection items family names the CollectionItems operation', () {
    expect(Families.collectionItems.operationName, 'CollectionItems');
    expect(
      QueryKeys.collectionItems('c1').operationName,
      Families.collectionItems.operationName,
      reason: 'the family must name the same operation the key declares',
    );
  });
}
