import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

const _a = SourceId('acc1:owner:srv1');
const _b = SourceId('acc2:owner:srv2');

void main() {
  test('keys carry the source in the operation name', () {
    final key = SourceKeys.item(
        const ItemRef(sourceId: _a, kind: ItemKind.movie, externalId: '42'));
    expect(key.operationName, 'acc1:owner:srv1/item');
    expect(key.canonical, 'acc1:owner:srv1/item({"id":"42","kind":"movie"})');
  });

  test('the same item on two sources gives two keys', () {
    ItemRef ref(SourceId id) =>
        ItemRef(sourceId: id, kind: ItemKind.movie, externalId: '42');
    expect(SourceKeys.item(ref(_a)), isNot(SourceKeys.item(ref(_b))));
  });

  test('browse keys ignore filter order', () {
    const library = LibraryRef(sourceId: _a, id: '3');
    expect(
      SourceKeys.browse(library, const BrowseQuery(filterIds: {'x', 'y'})),
      SourceKeys.browse(library, const BrowseQuery(filterIds: {'y', 'x'})),
    );
    expect(
      SourceKeys.browse(library, const BrowseQuery(pageSize: 20)),
      isNot(SourceKeys.browse(library, const BrowseQuery())),
    );
  });

  test('a family matches the operation name of its keys', () {
    final key = SourceKeys.children(
        const ItemRef(sourceId: _a, kind: ItemKind.show, externalId: 's1'));
    expect(SourceKeys.family(_a, SourceOps.children).operationName,
        key.operationName);
  });
}
