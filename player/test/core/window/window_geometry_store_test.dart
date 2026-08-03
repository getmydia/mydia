import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/window/window_geometry.dart';
import 'package:player/core/window/window_geometry_store.dart';

void main() {
  const geometry = WindowGeometry(
    bounds: Rect.fromLTWH(100, 200, 1280, 800),
    maximized: false,
  );

  group('InMemoryWindowGeometryStore', () {
    test('starts empty', () {
      expect(InMemoryWindowGeometryStore().get(), isNull);
    });

    test('returns what was saved', () async {
      final store = InMemoryWindowGeometryStore();
      await store.save(geometry);

      expect(store.get()!.bounds, geometry.bounds);
      expect(store.get()!.maximized, isFalse);
    });

    test('a later save replaces an earlier one', () async {
      final store = InMemoryWindowGeometryStore();
      await store.save(geometry);
      await store.save(geometry.copyWith(maximized: true));

      expect(store.get()!.maximized, isTrue);
    });
  });

  group('HiveWindowGeometryStore', () {
    late Directory tempDir;
    late Box<Map> box;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('window_geometry_test');
      Hive.init(tempDir.path);
      box = await Hive.openBox<Map>('window_geometry_test');
    });

    tearDown(() async {
      await box.deleteFromDisk();
      await Hive.close();
      await tempDir.delete(recursive: true);
    });

    test('returns null before anything is saved', () {
      expect(HiveWindowGeometryStore(box).get(), isNull);
    });

    test('round-trips through the box', () async {
      final store = HiveWindowGeometryStore(box);
      await store.save(geometry);

      expect(store.get()!.bounds, geometry.bounds);
      expect(store.get()!.maximized, isFalse);
    });

    test('survives a fresh store over the same box', () async {
      await HiveWindowGeometryStore(box).save(geometry);

      // A new instance is what the next launch sees.
      expect(HiveWindowGeometryStore(box).get()!.bounds, geometry.bounds);
    });

    test('discards an unreadable record instead of throwing', () async {
      await box.put('main', {'x': 0.0, 'nonsense': true});

      final store = HiveWindowGeometryStore(box);

      expect(store.get(), isNull);
      expect(
        box.get('main'),
        isNull,
        reason: 'a record that can never be read should not be kept',
      );
    });
  });
}
