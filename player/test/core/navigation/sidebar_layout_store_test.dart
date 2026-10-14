import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';

void main() {
  late Box<Map<dynamic, dynamic>> box;

  setUp(() async {
    Hive.init('./.dart_tool/test_hive_sidebar');
    box = await Hive.openBox<Map<dynamic, dynamic>>(
        HiveSidebarLayoutStore.boxName);
    await box.clear();
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk(HiveSidebarLayoutStore.boxName);
  });

  test('returns null when nothing is stored', () {
    expect(HiveSidebarLayoutStore(box).get(), isNull);
  });

  test('round-trips a saved layout', () async {
    final store = HiveSidebarLayoutStore(box);
    final layout = SidebarLayout.defaults.withHidden('movies');

    await store.save(layout);

    expect(store.get(), layout);
  });

  test('discards an unreadable record instead of throwing', () async {
    await box.put('layout', {'order': 42});

    // fromJson already degrades to defaults, so the store must not throw and
    // must not hand back a half-parsed object.
    expect(HiveSidebarLayoutStore(box).get(), SidebarLayout.defaults);
  });

  test('the in-memory store round-trips without a box', () async {
    final store = InMemorySidebarLayoutStore();
    expect(store.get(), isNull);

    final layout = SidebarLayout.defaults.withHidden('collections');
    await store.save(layout);

    expect(store.get(), layout);
  });

  test('the in-memory store remembers the rail pin', () async {
    final store = InMemorySidebarLayoutStore();
    expect(store.railPinned, isFalse);

    await store.saveRailPinned(true);

    expect(store.railPinned, isTrue);
  });

  test('the hive store round-trips the rail pin beside the layout', () async {
    final store = HiveSidebarLayoutStore(box);
    final layout = SidebarLayout.defaults.withHidden('movies');
    expect(store.railPinned, isFalse);

    await store.save(layout);
    await store.saveRailPinned(true);

    expect(store.railPinned, isTrue);
    expect(store.get(), layout);

    await store.saveRailPinned(false);
    expect(store.railPinned, isFalse);
  });

  test('a stored pin alone leaves the layout unset', () async {
    final store = HiveSidebarLayoutStore(box);
    await store.saveRailPinned(true);

    expect(store.get(), isNull);
  });
}
