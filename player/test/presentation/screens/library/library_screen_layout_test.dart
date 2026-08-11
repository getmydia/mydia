import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is not re-exported by the main `flutter_riverpod.dart` barrel in
// Riverpod 3.x; it lives in the `misc.dart` sub-library.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/graphql/watch/freshness.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/presentation/screens/library/library_controller.dart';
import 'package:player/presentation/screens/library/library_screen.dart';
import 'package:player/presentation/widgets/media_poster.dart';
import 'package:player/presentation/widgets/rating_badge.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/stub_graphql_client.dart';

/// The status bar inset every test in this file runs with.
const double kStatusBarTop = 47;

/// What the screen intends between the app bar's bottom edge and the first
/// row of content.
const double kContentGap = 8;

/// A desktop width (>= Breakpoints.tablet, so the search row is always shown).
const Size kDesktopSize = Size(1200, 900);

/// A mobile width. Deliberately not narrower: at 400px the app bar's `Row`
/// overflows by 20px on a pre-existing responsive bug unrelated to layout
/// padding, and the test would fail for the wrong reason.
const Size kMobileSize = Size(600, 900);

/// Every object needs `__typename`, the root included: `gql()` injects a
/// `__typename` selection into every selection set, and the normalized cache
/// refuses to write data that lacks a matching one. A miss surfaces as a
/// spurious `hasException`, not as an obvious error.
Map<String, dynamic> moviesPage(List<String> ids, {double? rating}) => {
      '__typename': 'Query',
      'movies': {
        '__typename': 'MovieConnection',
        'edges': [
          for (final id in ids)
            {
              '__typename': 'MovieEdge',
              'cursor': 'c-$id',
              'node': {
                '__typename': 'Movie',
                'id': id,
                'title': 'Movie $id',
                'year': 2026,
                'overview': null,
                'runtime': null,
                'genres': <String>[],
                'contentRating': null,
                'rating': rating,
                'artwork': {
                  '__typename': 'Artwork',
                  'posterUrl': null,
                  'backdropUrl': null,
                  'thumbnailUrl': null,
                },
                'progress': null,
                'isFavorite': false,
              },
            }
        ],
        'pageInfo': {
          '__typename': 'PageInfo',
          'hasNextPage': false,
          'hasPreviousPage': false,
          'startCursor': 'c-${ids.first}',
          'endCursor': 'c-${ids.last}',
        },
        'totalCount': ids.length,
      },
    };

/// The TV shows connection, whose node shape differs from a movie's: no
/// `progress`, plus `status`, `seasonCount`, `episodeCount` and `nextEpisode`.
Map<String, dynamic> tvShowsPage(List<String> ids, {double? rating}) => {
      '__typename': 'Query',
      'tvShows': {
        '__typename': 'TvShowConnection',
        'edges': [
          for (final id in ids)
            {
              '__typename': 'TvShowEdge',
              'cursor': 'c-$id',
              'node': {
                '__typename': 'TvShow',
                'id': id,
                'title': 'Show $id',
                'year': 2026,
                'overview': null,
                'status': null,
                'genres': <String>[],
                'contentRating': null,
                'rating': rating,
                'seasonCount': 1,
                'episodeCount': 8,
                'artwork': {
                  '__typename': 'Artwork',
                  'posterUrl': null,
                  'backdropUrl': null,
                  'thumbnailUrl': null,
                },
                'isFavorite': false,
                'nextEpisode': null,
              },
            }
        ],
        'pageInfo': {
          '__typename': 'PageInfo',
          'hasNextPage': false,
          'hasPreviousPage': false,
          'startCursor': 'c-${ids.first}',
          'endCursor': 'c-${ids.last}',
        },
        'totalCount': ids.length,
      },
    };

/// Mounts the real [LibraryScreen] over a scripted GraphQL link.
///
/// [settle] must be false whenever the freshness in-flight line will be
/// showing: it renders a `LinearProgressIndicator`, whose animation never
/// ends, so `pumpAndSettle` would time out. The bounded loop advances enough
/// frames for the async client override to resolve and for the 200ms search
/// row animation to finish.
Future<void> pumpLibrary(
  WidgetTester tester, {
  required Size size,
  LibraryType libraryType = LibraryType.movies,
  int itemCount = 40,
  double? rating,
  List<Override> extraOverrides = const [],
  bool settle = true,
  double bottomInset = 0,
  Widget Function(Widget child)? wrap,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding =
      FakeViewPadding(top: kStatusBarTop, bottom: bottomInset);
  addTearDown(tester.view.reset);

  final ids = List.generate(itemCount, (i) => '$i');
  final page = libraryType == LibraryType.movies
      ? moviesPage(ids, rating: rating)
      : tvShowsPage(ids, rating: rating);

  await mockNetworkImages(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          asyncGraphqlClientProvider.overrideWith(
            (ref) async => stubClient(StubLink.responses([page])),
          ),
          castCapabilitiesProvider
              .overrideWithValue(const CastCapabilities.full()),
          ...extraOverrides,
        ],
        child: wrap == null
            ? MaterialApp(home: LibraryScreen(libraryType: libraryType))
            : wrap(LibraryScreen(libraryType: libraryType)),
      ),
    );

    if (settle) {
      await tester.pumpAndSettle();
    } else {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
  });
}

/// The y coordinate where the app bar stops covering the body.
double appBarBottom(WidgetTester tester) {
  final box = tester.renderObject<RenderBox>(find.byType(PreferredSize).first);
  return box.localToGlobal(Offset.zero).dy + box.size.height;
}

double firstPosterTop(WidgetTester tester) =>
    tester.getTopLeft(find.byType(MediaPoster).first).dy;

/// Pins the freshness state for the whole test.
///
/// `build()` alone is not enough: the screen's real `LibraryController`
/// creates a watcher that calls `publish` as soon as its fetch resolves, which
/// would immediately overwrite the state under test with
/// `isRefreshing: false`. Both mutators are no-ops so the pinned map wins.
class _PinnedFreshnessRegistry extends FreshnessRegistry {
  _PinnedFreshnessRegistry(this._pinned);

  final Map<QueryKey, Freshness> _pinned;

  @override
  Map<QueryKey, Freshness> build() => _pinned;

  @override
  void publish(QueryKey key, Freshness freshness) {}

  @override
  void clear(QueryKey key) {}
}

/// `FreshnessHeader` renders nothing at all in offline mode, so the auth state
/// has to be pinned to authenticated for the in-flight line to show.
class _StubAuthState extends AuthStateNotifier {
  _StubAuthState(this._status);

  final AuthStatus _status;

  @override
  AsyncValue<AuthStatus> build() => AsyncValue.data(_status);
}

List<Override> refreshingOverrides() => [
      authStateProvider
          .overrideWith(() => _StubAuthState(AuthStatus.authenticated)),
      freshnessRegistryProvider.overrideWith(
        () => _PinnedFreshnessRegistry({
          QueryKeys.moviesList: Freshness(
            fetchedAt: DateTime(2026, 8, 4),
            isRefreshing: true,
          ),
        }),
      ),
    ];

void main() {
  // LibraryScreen now awaits LibrarySortController before querying, and that
  // controller reads flutter_secure_storage. Without the mock, the read never
  // completes in widget tests, the sort spinner spins forever, and
  // pumpAndSettle times out. StubLink scripting is unchanged: still one
  // library page response after the sort resolves.
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('grid starts just below the app bar on desktop', (tester) async {
    await pumpLibrary(tester, size: kDesktopSize);

    expect(firstPosterTop(tester), appBarBottom(tester) + kContentGap);
  });

  testWidgets('tv shows grid starts just below the app bar too',
      (tester) async {
    await pumpLibrary(
      tester,
      size: kDesktopSize,
      libraryType: LibraryType.tvShows,
    );

    expect(firstPosterTop(tester), appBarBottom(tester) + kContentGap);
  });

  testWidgets('grid starts just below the app bar on mobile', (tester) async {
    await pumpLibrary(tester, size: kMobileSize);

    expect(firstPosterTop(tester), appBarBottom(tester) + kContentGap);
  });

  testWidgets('list view starts at the same offset as the grid',
      (tester) async {
    await pumpLibrary(tester, size: kDesktopSize);

    final gridTop = tester.widget<GridView>(find.byType(GridView)).padding;

    // In grid mode the toggle button shows the *list* icon.
    await tester.tap(find.byIcon(Icons.view_list_rounded));
    await tester.pumpAndSettle();

    final listTop = tester.widget<ListView>(find.byType(ListView)).padding;

    expect(listTop, gridTop);
  });

  testWidgets('a refresh in flight does not move the grid', (tester) async {
    await pumpLibrary(
      tester,
      size: kDesktopSize,
      extraOverrides: refreshingOverrides(),
      settle: false,
    );

    expect(find.byKey(const Key('freshness-inflight')), findsOneWidget);
    expect(firstPosterTop(tester), appBarBottom(tester) + kContentGap);
  });

  testWidgets('the grid still scrolls while the refresh line shows',
      (tester) async {
    await pumpLibrary(
      tester,
      size: kDesktopSize,
      extraOverrides: refreshingOverrides(),
      settle: false,
    );

    final before = firstPosterTop(tester);
    await tester.drag(find.byType(GridView), const Offset(0, -120));
    await tester.pump();

    expect(before - firstPosterTop(tester), 120);
  });

  testWidgets('the grid hands each poster its TMDB rating', (tester) async {
    await pumpLibrary(
      tester,
      size: kDesktopSize,
      itemCount: 1,
      rating: 8.4,
    );

    final poster = tester.widget<MediaPoster>(find.byType(MediaPoster).first);
    expect(poster.rating, 8.4);
    expect(find.text('8.4'), findsOneWidget);
  });

  testWidgets('a TV shows grid hands its posters the rating too',
      (tester) async {
    await pumpLibrary(
      tester,
      size: kDesktopSize,
      libraryType: LibraryType.tvShows,
      itemCount: 1,
      rating: 9.1,
    );

    final poster = tester.widget<MediaPoster>(find.byType(MediaPoster).first);
    expect(poster.rating, 9.1);
    expect(find.text('9.1'), findsOneWidget);
  });

  testWidgets(
      'an unvoted title shows no chip, since TMDB reports 0.0 for no votes',
      (tester) async {
    await pumpLibrary(
      tester,
      size: kDesktopSize,
      itemCount: 1,
      rating: 0,
    );

    expect(find.byType(RatingBadge), findsNothing);
  });

  testWidgets('list view omits the rating chip even when the data has one',
      (tester) async {
    await pumpLibrary(
      tester,
      size: kDesktopSize,
      itemCount: 1,
      rating: 8.4,
    );

    // In grid mode the toggle button shows the *list* icon.
    await tester.tap(find.byIcon(Icons.view_list_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(RatingBadge), findsNothing);
  });
}
