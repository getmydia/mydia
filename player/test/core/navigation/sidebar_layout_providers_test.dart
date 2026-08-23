import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/domain/navigation/nav_destination.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';

ProviderContainer _container(SidebarLayoutStore store) {
  final container = ProviderContainer(
    overrides: [sidebarLayoutStoreProvider.overrideWithValue(store)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('an empty store yields the defaults', () async {
    final container = _container(InMemorySidebarLayoutStore());

    expect(
      await container.read(sidebarLayoutProvider.future),
      SidebarLayout.defaults,
    );
  });

  test('hiding a destination persists and is reflected on next read', () async {
    final store = InMemorySidebarLayoutStore();
    final container = _container(store);

    await container.read(sidebarLayoutProvider.future);
    await container.read(sidebarLayoutControllerProvider).hide('movies');

    expect(store.get()?.hidden, contains('movies'));
    final reread = await container.read(sidebarLayoutProvider.future);
    expect(reread.hidden, contains('movies'));
  });

  test('an anchored destination cannot be hidden', () async {
    final store = InMemorySidebarLayoutStore();
    final container = _container(store);

    await container.read(sidebarLayoutProvider.future);
    await container.read(sidebarLayoutControllerProvider).hide('settings');

    final destinations =
        await container.read(sidebarDestinationsProvider.future);
    expect(destinations.map((d) => d.id), contains('settings'));
  });

  test('resetToDefaults clears a customised layout', () async {
    final store = InMemorySidebarLayoutStore();
    final container = _container(store);

    await container.read(sidebarLayoutProvider.future);
    final controller = container.read(sidebarLayoutControllerProvider);
    await controller.hide('movies');
    await controller.resetToDefaults();

    expect(
      await container.read(sidebarLayoutProvider.future),
      SidebarLayout.defaults,
    );
  });

  group('sidebarEditMode', () {
    test('starts off, toggles, and exits', () {
      final container = ProviderContainer(
        overrides: [
          sidebarLayoutStoreProvider
              .overrideWithValue(InMemorySidebarLayoutStore()),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(sidebarEditModeProvider), isFalse);

      container.read(sidebarEditModeProvider.notifier).toggle();
      expect(container.read(sidebarEditModeProvider), isTrue);

      container.read(sidebarEditModeProvider.notifier).exit();
      expect(container.read(sidebarEditModeProvider), isFalse);
    });

    test('exit is idempotent', () {
      final container = ProviderContainer(
        overrides: [
          sidebarLayoutStoreProvider
              .overrideWithValue(InMemorySidebarLayoutStore()),
        ],
      );
      addTearDown(container.dispose);

      container.read(sidebarEditModeProvider.notifier).exit();
      expect(container.read(sidebarEditModeProvider), isFalse);
    });
  });

  group('sidebarEditRows', () {
    test('includes hidden rows that sidebarDestinations drops', () async {
      final store = InMemorySidebarLayoutStore();
      await store.save(SidebarLayout.defaults.withHidden('collections'));

      final container = ProviderContainer(
        overrides: [sidebarLayoutStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      final destinations =
          await container.read(sidebarDestinationsProvider.future);
      expect(
        destinations.map((d) => d.id),
        isNot(contains('collections')),
      );

      final rows = await container.read(sidebarEditRowsProvider.future);
      final collections =
          rows.firstWhere((r) => r.destination.id == 'collections');
      expect(collections.hidden, isTrue);
    });
  });

  group('resetToDefaults', () {
    test('restores order and unhides without deleting saved filters', () async {
      final filter = FilterDestination(
        id: 'filter_keep_me',
        label: 'Keep me',
        filter: MediaFilter.allMovies,
      );

      final store = InMemorySidebarLayoutStore();
      await store.save(
        SidebarLayout.defaults.withFilter(filter).withHidden('collections'),
      );

      final container = ProviderContainer(
        overrides: [sidebarLayoutStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      await container.read(sidebarLayoutControllerProvider).resetToDefaults();

      final after = store.get()!;
      expect(after.hidden, isEmpty);
      expect(after.filters.keys, contains('filter_keep_me'));

      final destinations =
          await container.read(sidebarDestinationsProvider.future);
      expect(destinations.map((d) => d.id), contains('filter_keep_me'));
      expect(destinations.map((d) => d.id), contains('collections'));
    });
  });
}
