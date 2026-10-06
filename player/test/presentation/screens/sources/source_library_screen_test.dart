import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/filter/filter_editor_sheet.dart';
import 'package:player/presentation/screens/library/library_sort.dart';
import 'package:player/presentation/screens/sources/source_library_screen.dart';
import 'package:player/presentation/widgets/media_poster.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/mock_auth_storage.dart';
import 'fake_capable_source.dart';
import 'fake_media_source.dart';

Widget _libraryApp(FakeMediaSource fake,
        {BrowseQuery? initialQuery, MockAuthStorage? storage}) =>
    ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(fake),
        coreSettingsServiceProvider.overrideWithValue(
            SettingsService(storage: storage ?? MockAuthStorage())),
        // No artwork requests: a poster with a URL spins until the blocked
        // test HTTP client answers, which pumpAndSettle never outlasts.
        sourceArtworkProvider.overrideWith((ref, key) async => null),
      ],
      child: MaterialApp(
        home: SourceLibraryScreen(
          library: FakeMediaSource.movies,
          initialQuery: initialQuery,
        ),
      ),
    );

Future<void> pumpLibrary(WidgetTester tester, FakeMediaSource fake,
    {BrowseQuery? initialQuery, MockAuthStorage? storage}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
      _libraryApp(fake, initialQuery: initialQuery, storage: storage));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the direction toggle flips descending in the query',
      (tester) async {
    final fake = FakeMediaSource();
    await pumpLibrary(tester, fake);
    // Title sorts ascending by default.
    expect(fake.browseCalls.last.$1.descending, isNull);

    await tester.tap(find.byKey(const Key('source-sort-direction')));
    await tester.pumpAndSettle();
    expect(fake.browseCalls.last.$1.descending, isTrue);

    await tester.tap(find.byKey(const Key('source-sort-direction')));
    await tester.pumpAndSettle();
    expect(fake.browseCalls.last.$1.descending, isFalse);
  });

  testWidgets('changing the sort keeps the filters and resets direction',
      (tester) async {
    final fake = FakeMediaSource();
    await pumpLibrary(tester, fake,
        initialQuery: const BrowseQuery(
            sortId: 'title', descending: true, filterIds: {'unwatched'}));
    await tester.tap(find.byKey(const Key('source-sort-added')));
    await tester.pumpAndSettle();
    final query = fake.browseCalls.last.$1;
    expect(query.sortId, 'added');
    expect(query.descending, isNull);
    expect(query.filterIds, {'unwatched'});
  });

  testWidgets('a plain library remembers its sort across visits',
      (tester) async {
    final storage = MockAuthStorage();
    var fake = FakeMediaSource();
    await pumpLibrary(tester, fake, storage: storage);
    await tester.tap(find.byKey(const Key('source-sort-added')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('source-sort-direction')));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox());
    fake = FakeMediaSource();
    await tester.pumpWidget(_libraryApp(fake, storage: storage));
    await tester.pumpAndSettle();
    expect(fake.browseCalls.first.$1.sortId, 'added');
    expect(fake.browseCalls.first.$1.descending, isFalse);
  });

  testWidgets('a saved filter ignores the remembered sort', (tester) async {
    final storage = MockAuthStorage();
    await SettingsService(storage: storage)
        .setLibrarySort('${fakeSourceId.value}/movies', 'added|desc');
    final fake = FakeMediaSource();
    await pumpLibrary(tester, fake,
        storage: storage, initialQuery: const BrowseQuery(sortId: 'title'));
    expect(fake.browseCalls.first.$1.sortId, 'title');
  });

  testWidgets('save as filter opens the editor on the kind and sort',
      (tester) async {
    await pumpLibrary(tester, FakeCapableSource(),
        initialQuery: const BrowseQuery(sortId: 'YEAR', descending: false));
    await tester.tap(find.byKey(const Key('source-library-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save this view as a filter'));
    await tester.pumpAndSettle();

    final sheet =
        tester.widget<FilterEditorSheet>(find.byType(FilterEditorSheet));
    expect(sheet.initialFilter.kind, MediaKind.movies);
    expect(sheet.initialFilter.watch, WatchScope.all);
    expect(sheet.initialFilter.sort,
        const LibrarySort(field: SortField.year, direction: SortDirection.asc));
  });

  testWidgets('a source without saved filters has no save menu',
      (tester) async {
    await pumpLibrary(tester, FakeMediaSource());
    expect(find.byKey(const Key('source-library-menu')), findsNothing);
  });

  testWidgets('initialQuery applies on first build only', (tester) async {
    final fake = FakeMediaSource();
    const initial = BrowseQuery(sortId: 'added', filterIds: {'unwatched'});
    await pumpLibrary(tester, fake, initialQuery: initial);
    expect(fake.browseCalls.first.$1, initial);
    expect(
        tester
            .widget<FilterChip>(
                find.byKey(const Key('source-filter-unwatched')))
            .selected,
        isTrue);

    await tester.tap(find.byKey(const Key('source-sort-title')));
    await tester.pumpAndSettle();
    expect(fake.browseCalls.last.$1.sortId, 'title');

    // The same screen pumped again keeps the chip the viewer chose.
    await tester.pumpWidget(_libraryApp(fake, initialQuery: initial));
    await tester.pumpAndSettle();
    expect(fake.browseCalls.last.$1.sortId, 'title');
  });

  testWidgets('the view toggle swaps the grid for a list', (tester) async {
    await pumpLibrary(tester, FakeMediaSource());
    expect(find.byType(GridView), findsOneWidget);

    await tester.tap(find.byKey(const Key('source-view-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsNothing);
    expect(find.byKey(const ValueKey('source-list-m1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('source-view-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);
  });

  testWidgets('loads the next page as the grid nears its end', (tester) async {
    final fake = FakeMediaSource(movieCount: 130);
    await pumpLibrary(tester, fake);
    expect(fake.browseCalls, hasLength(1));
    // The sort and filter chip row is also a Scrollable, and comes first.
    await tester.drag(
      find.descendant(
          of: find.byType(GridView), matching: find.byType(Scrollable)),
      const Offset(0, -20000),
    );
    await tester.pumpAndSettle();
    expect(fake.browseCalls.length, greaterThan(1));
    // A drag this long keeps loading until the end; the first follow-up
    // call resumes after the first page.
    expect(fake.browseCalls[1].$2?.value, '60');
  });

  testWidgets('sort and filter come from the library', (tester) async {
    final fake = FakeMediaSource();
    await pumpLibrary(tester, fake);
    await tester.tap(find.byKey(const Key('source-sort-added')));
    await tester.pumpAndSettle();
    expect(fake.browseCalls.last.$1.sortId, 'added');
    await tester.tap(find.byKey(const Key('source-filter-unwatched')));
    await tester.pumpAndSettle();
    expect(fake.browseCalls.last.$1.filterIds, {'unwatched'});
  });

  testWidgets('directional keys move between posters', (tester) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic);
    await pumpLibrary(tester, FakeMediaSource());

    final first = find.byKey(const ValueKey('source-poster-m1'));
    final second = find.byKey(const ValueKey('source-poster-m2'));
    // The nearest Focus above the MediaPoster is SourcePoster's
    // FocusHighlight.
    Focus.of(tester.element(
            find.descendant(of: first, matching: find.byType(MediaPoster))))
        .requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      find.descendant(
          of: second, matching: find.byElementPredicate((e) => e == focused)),
      findsOneWidget,
    );
  });
}
