import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/domain/navigation/nav_destination.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';
import 'package:player/presentation/screens/filter/filter_editor_sheet.dart';
import 'package:player/presentation/screens/library/library_sort.dart';

const _existingFilter = FilterDestination(
  id: 'f_existing',
  label: 'Anime Movies',
  filter: MediaFilter(
    kind: MediaKind.movies,
    category: MediaCategoryFilter.animeMovie,
    watch: WatchScope.all,
    sort: LibrarySort.defaultSort,
  ),
);

Future<void> _pumpEditor(
  WidgetTester tester, {
  required SidebarLayoutStore store,
  MediaFilter? initialFilter,
  FilterDestination? editing,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sidebarLayoutStoreProvider.overrideWithValue(store),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              onPressed: () => showFilterEditor(
                context: context,
                ref: ref,
                initialFilter: initialFilter,
                editing: editing,
              ),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('creating a filter adds it to the layout', (tester) async {
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults);

    await _pumpEditor(
      tester,
      store: store,
      initialFilter: MediaFilter.allMovies,
    );

    await tester.enterText(
      find.byKey(const Key('filter-editor-name')),
      'My Movies',
    );
    await tester.tap(find.byKey(const Key('filter-editor-save')));
    await tester.pumpAndSettle();

    final layout = store.get()!;
    expect(layout.filters.length, 1);
    final filter = layout.filters.values.first;
    expect(filter.label, 'My Movies');
    expect(filter.filter.kind, MediaKind.movies);
    expect(filter.id.startsWith('f_'), isTrue);
  });

  testWidgets('the category picker only offers categories for the chosen kind',
      (tester) async {
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults);

    await _pumpEditor(
      tester,
      store: store,
      initialFilter: MediaFilter(
        kind: MediaKind.movies,
        category: MediaCategoryFilter.animeMovie,
        watch: WatchScope.all,
        sort: LibrarySort.defaultSort,
      ),
    );

    expect(find.text('Anime Movies'), findsOneWidget);

    await tester.tap(find.text('TV Shows'));
    await tester.pumpAndSettle();

    expect(find.text('Anime Movies'), findsNothing);

    await tester.tap(find.byKey(const Key('filter-editor-category')));
    await tester.pumpAndSettle();

    expect(find.text('Anime Series'), findsOneWidget);
    expect(find.text('Anime Movies'), findsNothing);
  });

  testWidgets('editing an existing filter preserves its id', (tester) async {
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults.withFilter(_existingFilter));

    await _pumpEditor(
      tester,
      store: store,
      initialFilter: _existingFilter.filter,
      editing: _existingFilter,
    );

    await tester.enterText(
      find.byKey(const Key('filter-editor-name')),
      'Renamed Filter',
    );
    await tester.tap(find.byKey(const Key('filter-editor-save')));
    await tester.pumpAndSettle();

    final layout = store.get()!;
    expect(layout.filters.containsKey('f_existing'), isTrue);
    expect(layout.filters['f_existing']!.label, 'Renamed Filter');
    expect(layout.filters.length, 1);
  });

  testWidgets('a blank name is rejected', (tester) async {
    final store = InMemorySidebarLayoutStore();
    await store.save(SidebarLayout.defaults);

    await _pumpEditor(
      tester,
      store: store,
      initialFilter: MediaFilter.allMovies,
    );

    await tester.tap(find.byKey(const Key('filter-editor-save')));
    await tester.pumpAndSettle();

    expect(store.get()!.filters, isEmpty);
    expect(find.byKey(const Key('filter-editor-name')), findsOneWidget);
    expect(find.text('Name is required'), findsOneWidget);
  });
}
