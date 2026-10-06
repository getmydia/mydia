import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/downloads/collection_sync_providers.dart';
import 'package:player/core/sources/mydia/bound_mydia.dart';
import 'package:player/core/sources/source.dart';

const _a = SourceId('acc1:owner:aa11');
const _b = SourceId('acc2:owner:bb22');

void main() {
  late Directory dir;
  late Box<Map<dynamic, dynamic>> box;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('collection_sync_test');
    Hive.init(dir.path);
    box = await Hive.openBox<Map<dynamic, dynamic>>('collection_sync');
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  ProviderContainer containerBoundTo(SourceId? bound) {
    final container = ProviderContainer(overrides: [
      collectionSyncBoxProvider.overrideWith((ref) async => box),
      boundSourceIdProvider.overrideWithValue(bound),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('two instances with the same collection id are independent', () async {
    final c = containerBoundTo(_a);
    await c.read(saveCollectionSyncProvider)(
      sourceId: _a.value,
      collectionId: '1',
      name: 'Saga',
      resolution: '720p',
    );

    expect(
        await c.read(isCollectionSyncedProvider(_a.value, '1').future), isTrue);
    expect(await c.read(isCollectionSyncedProvider(_b.value, '1').future),
        isFalse);

    await c.read(saveCollectionSyncProvider)(
      sourceId: _b.value,
      collectionId: '1',
      name: 'Other Saga',
      resolution: 'original',
    );
    final configB =
        await c.read(collectionSyncConfigProvider(_b.value, '1').future);
    expect(configB!['resolution'], 'original');
    expect(
        (await c.read(
            collectionSyncConfigProvider(_a.value, '1').future))!['resolution'],
        '720p');

    await c.read(removeCollectionSyncProvider)(_a.value, '1');
    expect(await c.read(isCollectionSyncedProvider(_a.value, '1').future),
        isFalse);
    expect(
        await c.read(isCollectionSyncedProvider(_b.value, '1').future), isTrue);
  });

  test('a collection-id-only entry belongs to the bound instance', () async {
    await box.put('1', {'name': 'Saga', 'resolution': '720p'});
    final c = containerBoundTo(_a);

    expect(
        await c.read(isCollectionSyncedProvider(_a.value, '1').future), isTrue);
    expect(await c.read(isCollectionSyncedProvider(_b.value, '1').future),
        isFalse);

    final all = await c.read(allSyncedCollectionsProvider.future);
    expect(all['1'], {
      'name': 'Saga',
      'resolution': '720p',
      'collectionId': '1',
      'sourceId': _a.value,
    });
  });

  test('saving moves a legacy entry to the source-scoped key', () async {
    await box.put('1', {'name': 'Saga', 'resolution': '720p'});
    final c = containerBoundTo(_a);

    await c.read(saveCollectionSyncProvider)(
      sourceId: _a.value,
      collectionId: '1',
      name: 'Saga',
      resolution: '1080p',
    );

    expect(box.keys, ['${_a.value}:1']);
    expect(
        (await c.read(
            collectionSyncConfigProvider(_a.value, '1').future))!['resolution'],
        '1080p');
  });

  test('a legacy entry that recorded its source stays with that source',
      () async {
    await box.put('1', {
      'name': 'Saga',
      'resolution': '720p',
      'sourceId': _b.value,
    });
    final c = containerBoundTo(_a);

    expect(await c.read(isCollectionSyncedProvider(_a.value, '1').future),
        isFalse);
    expect(
        await c.read(isCollectionSyncedProvider(_b.value, '1').future), isTrue);
  });
}
