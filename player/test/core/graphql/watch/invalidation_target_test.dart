import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/invalidation_target.dart';
import 'package:player/core/graphql/watch/query_key.dart';

void main() {
  group('KeyTarget', () {
    test('two targets over equal keys are equal', () {
      expect(
        KeyTarget(QueryKeys.showDetail('7')),
        KeyTarget(QueryKeys.showDetail('7')),
      );
    });

    test('two targets over different keys are not equal', () {
      expect(
        KeyTarget(QueryKeys.showDetail('7')),
        isNot(KeyTarget(QueryKeys.showDetail('8'))),
      );
    });

    test('equal targets collapse in a set, as the rules rely on', () {
      final targets = {
        KeyTarget(QueryKeys.home),
        KeyTarget(QueryKeys.home),
      };

      expect(targets, hasLength(1));
    });
  });

  group('FamilyTarget', () {
    test('two targets over the same operation are equal', () {
      expect(
        FamilyTarget('CollectionItems'),
        const FamilyTarget('CollectionItems'),
      );
    });

    test('two targets over different operations are not equal', () {
      expect(
        const FamilyTarget('CollectionItems'),
        isNot(const FamilyTarget('Collections')),
      );
    });

    test('equal targets collapse in a set', () {
      final targets = {
        const FamilyTarget('CollectionItems'),
        FamilyTarget('CollectionItems'),
      };

      expect(targets, hasLength(1));
    });
  });

  test('a key target and a family target never compare equal', () {
    expect(
      KeyTarget(QueryKeys.collectionItems('c1')),
      isNot(const FamilyTarget('CollectionItems')),
    );
  });

  test('the target extension wraps the key it was called on', () {
    expect(QueryKeys.home.target, KeyTarget(QueryKeys.home));
  });

  test('the collection items family names the CollectionItems operation', () {
    expect(Families.collectionItems.operationName, 'CollectionItems');
    expect(
      QueryKeys.collectionItems('c1').operationName,
      Families.collectionItems.operationName,
      reason: 'the family must name the same operation the key declares',
    );
  });
}
