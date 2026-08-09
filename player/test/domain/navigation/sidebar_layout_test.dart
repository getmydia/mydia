import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/domain/navigation/nav_destination.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';
import 'package:player/presentation/screens/library/library_sort.dart';

const _filter = FilterDestination(
  id: 'f_1',
  label: 'Unwatched Anime',
  filter: MediaFilter(
    kind: MediaKind.shows,
    category: MediaCategoryFilter.animeSeries,
    watch: WatchScope.unwatched,
    sort: LibrarySort.defaultSort,
  ),
);

void main() {
  group('defaults', () {
    test('contain every builtin in defaultIndex order', () {
      final resolved =
          SidebarLayout.defaults.reconcile(downloadSupported: true);
      final expected = (List.of(builtinDestinations)
            ..sort((a, b) => a.defaultIndex.compareTo(b.defaultIndex)))
          .map((d) => d.id);

      expect(resolved.map((d) => d.id), expected);
    });

    test('omit Downloads where downloads are unsupported', () {
      final resolved =
          SidebarLayout.defaults.reconcile(downloadSupported: false);
      expect(resolved.map((d) => d.id), isNot(contains('downloads')));
      expect(resolved.map((d) => d.id), contains('settings'));
    });
  });

  group('reconcile', () {
    test('rule 1: drops ids matching no builtin and no filter', () {
      const layout = SidebarLayout(
        order: ['home', 'ghost_destination', 'movies'],
        hidden: {},
        filters: {},
      );

      final ids = layout.reconcile(downloadSupported: true).map((d) => d.id);
      expect(ids, isNot(contains('ghost_destination')));
      expect(ids, containsAll(['home', 'movies']));
    });

    test('rule 2: inserts an absent builtin at its defaultIndex', () {
      // A stored order from a release that predates Continue Watching.
      const layout = SidebarLayout(
        order: ['search', 'home', 'movies', 'shows', 'downloads', 'settings'],
        hidden: {},
        filters: {},
      );

      final ids =
          layout.reconcile(downloadSupported: true).map((d) => d.id).toList();

      // defaultIndex 110 sits between home (100) and movies (120).
      expect(
        ids.indexOf('continue_watching'),
        greaterThan(ids.indexOf('home')),
      );
      expect(
        ids.indexOf('continue_watching'),
        lessThan(ids.indexOf('movies')),
      );
    });

    test('rule 3: a stored filter missing from order lands in the middle', () {
      const layout = SidebarLayout(
        order: ['home'],
        hidden: {},
        filters: {'f_1': _filter},
      );

      final ids =
          layout.reconcile(downloadSupported: true).map((d) => d.id).toList();

      // Rule 3 appends to `order`, but anchors are pinned to the edges
      // afterwards, so the filter is last in the *reorderable* region rather
      // than last overall. It must sit above Downloads and Settings: the
      // approved layout puts saved filters in the middle, never below the
      // bottom anchors.
      expect(ids, contains('f_1'));
      expect(ids.indexOf('f_1'), greaterThan(ids.indexOf('home')));
      expect(ids.indexOf('f_1'), lessThan(ids.indexOf('downloads')));
      expect(ids.indexOf('f_1'), lessThan(ids.indexOf('settings')));
      expect(ids.last, 'settings');
    });

    test('rule 4: a stale hidden id cannot hide a later destination', () {
      const layout = SidebarLayout(
        order: ['home', 'movies'],
        hidden: {'ghost_destination'},
        filters: {},
      );

      final reconciled = layout.reconcileLayout(downloadSupported: true);
      expect(reconciled.hidden, isEmpty);
    });

    test('hidden destinations are excluded from the resolved list', () {
      const layout = SidebarLayout(
        order: ['home', 'movies', 'shows'],
        hidden: {'movies'},
        filters: {},
      );

      final ids = layout.reconcile(downloadSupported: true).map((d) => d.id);
      expect(ids, isNot(contains('movies')));
      expect(ids, contains('shows'));
    });

    test('anchored destinations cannot be hidden', () {
      const layout = SidebarLayout(
        order: ['home', 'settings'],
        hidden: {'settings', 'search', 'downloads'},
        filters: {},
      );

      final ids = layout.reconcile(downloadSupported: true).map((d) => d.id);
      expect(ids, containsAll(['settings', 'search', 'downloads']));
    });

    test('anchors sort to the edges regardless of stored order', () {
      const layout = SidebarLayout(
        order: ['settings', 'movies', 'search', 'downloads', 'home'],
        hidden: {},
        filters: {},
      );

      final ids =
          layout.reconcile(downloadSupported: true).map((d) => d.id).toList();

      expect(ids.first, 'search');
      expect(ids.last, 'settings');
      expect(ids[ids.length - 2], 'downloads');
    });
  });

  group('json', () {
    test('round-trips', () {
      const layout = SidebarLayout(
        order: ['home', 'f_1', 'movies'],
        hidden: {'collections'},
        filters: {'f_1': _filter},
      );

      expect(SidebarLayout.fromJson(layout.toJson()), layout);
    });

    test('rule 5: malformed json yields defaults', () {
      expect(
        SidebarLayout.fromJson(const {'order': 42, 'filters': 'nonsense'}),
        SidebarLayout.defaults,
      );
    });
  });

  group('mutators', () {
    test('withFilter adds and withoutFilter removes from both order and map',
        () {
      final added = SidebarLayout.defaults.withFilter(_filter);
      expect(added.filters, contains('f_1'));
      expect(added.order, contains('f_1'));

      final removed = added.withoutFilter('f_1');
      expect(removed.filters, isNot(contains('f_1')));
      expect(removed.order, isNot(contains('f_1')));
    });

    test('withHidden and withUnhidden are inverses', () {
      final hidden = SidebarLayout.defaults.withHidden('movies');
      expect(hidden.hidden, contains('movies'));
      expect(hidden.withUnhidden('movies').hidden, isNot(contains('movies')));
    });
  });
}
