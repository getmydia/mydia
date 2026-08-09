import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
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
}
