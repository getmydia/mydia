import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';

void main() {
  late Box<Map> box;

  setUp(() async {
    Hive.init('./.dart_tool/test_hive_sidebar');
    box = await Hive.openBox<Map>(HiveSidebarLayoutStore.boxName);
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
}
