import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/invalidation_target.dart';
import 'package:player/core/cache/query_key.dart';

final _home = QueryKey('HomeScreen');
QueryKey _showDetail(String id) => QueryKey('TvShowDetail', {'id': id});
QueryKey _collectionItems(String id) =>
    QueryKey('CollectionItems', {'collectionId': id});

void main() {
  group('KeyTarget', () {
    test('two targets over equal keys are equal', () {
      expect(
        KeyTarget(_showDetail('7')),
        KeyTarget(_showDetail('7')),
      );
    });

    test('two targets over different keys are not equal', () {
      expect(
        KeyTarget(_showDetail('7')),
        isNot(KeyTarget(_showDetail('8'))),
      );
    });

    test('equal targets collapse in a set, as the rules rely on', () {
      final targets = {
        KeyTarget(_home),
        KeyTarget(_home),
      };

      expect(targets, hasLength(1));
    });
  });

  group('FamilyTarget', () {
    test('two targets over the same operation are equal', () {
      expect(
        // ignore: prefer_const_constructors, a runtime instance exercises == rather than identity
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
        // ignore: prefer_const_constructors, a runtime instance exercises hashCode and == rather than identity
        FamilyTarget('CollectionItems'),
      };

      expect(targets, hasLength(1));
    });
  });

  test('a key target and a family target never compare equal', () {
    expect(
      KeyTarget(_collectionItems('c1')),
      isNot(const FamilyTarget('CollectionItems')),
    );
  });

  test('the target extension wraps the key it was called on', () {
    expect(_home.target, KeyTarget(_home));
  });
}
