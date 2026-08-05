import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is not re-exported by the main `flutter_riverpod.dart` barrel in
// Riverpod 3.x; it lives in the `misc.dart` sub-library.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/presentation/screens/library/library_controller.dart';
import 'package:player/presentation/screens/library/library_screen.dart';
import 'package:player/presentation/widgets/media_poster.dart';

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
Map<String, dynamic> moviesPage(List<String> ids) => {
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
                'rating': null,
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
  int itemCount = 40,
  List<Override> extraOverrides = const [],
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = const FakeViewPadding(top: kStatusBarTop);
  addTearDown(tester.view.reset);

  await mockNetworkImages(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          asyncGraphqlClientProvider.overrideWith(
            (ref) async => stubClient(
              StubLink.responses([
                moviesPage(List.generate(itemCount, (i) => '$i')),
              ]),
            ),
          ),
          castCapabilitiesProvider
              .overrideWithValue(const CastCapabilities.full()),
          ...extraOverrides,
        ],
        child: const MaterialApp(
          home: LibraryScreen(libraryType: LibraryType.movies),
        ),
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

void main() {
  testWidgets('grid starts just below the app bar on desktop', (tester) async {
    await pumpLibrary(tester, size: kDesktopSize);

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
}
