import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is not re-exported by the main `flutter_riverpod.dart` barrel in
// Riverpod 3.x; it lives in the `misc.dart` sub-library.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/freshness.dart';
import 'package:player/core/cache/query_key.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/current_source_status.dart';
import 'package:player/core/sources/media_source.dart'
    show SourceConnectionStatus;
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/sources/source_library_screen.dart';
import 'package:player/presentation/widgets/media_poster.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import 'fake_media_source.dart';

/// The status bar inset every test in this file runs with.
const double kStatusBarTop = 47;

/// What the screen intends between the app bar's bottom edge and the first
/// row of content.
const double kContentGap = 8;

const Size kDesktopSize = Size(1200, 900);

/// Deliberately not narrower: at 400px the app bar's `Row` overflows on a
/// pre-existing responsive limit unrelated to layout padding.
const Size kMobileSize = Size(600, 900);

/// Mounts the real [SourceLibraryScreen] over a fake source.
///
/// [settle] must be false whenever the freshness in-flight line will be
/// showing: it renders a `LinearProgressIndicator`, whose animation never
/// ends, so `pumpAndSettle` would time out.
Future<void> pumpLibrary(
  WidgetTester tester, {
  required Size size,
  LibraryRef library = FakeMediaSource.movies,
  int itemCount = 40,
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

  final screen = SourceLibraryScreen(library: library);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId)
            .overrideWithValue(FakeMediaSource(movieCount: itemCount)),
        sourceArtworkProvider.overrideWith((ref, key) async => null),
        castCapabilitiesProvider
            .overrideWithValue(const CastCapabilities.full()),
        ...extraOverrides,
      ],
      child: wrap == null ? MaterialApp(home: screen) : wrap(screen),
    ),
  );

  if (settle) {
    await tester.pumpAndSettle();
  } else {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}

/// The y coordinate where the app bar stops covering the body.
double appBarBottom(WidgetTester tester) {
  final box = tester.renderObject<RenderBox>(find.byType(PreferredSize).first);
  return box.localToGlobal(Offset.zero).dy + box.size.height;
}

double firstPosterTop(WidgetTester tester) =>
    tester.getTopLeft(find.byType(MediaPoster).first).dy;

/// Pins the freshness state for the whole test: the screen's own watcher
/// would otherwise overwrite it as soon as its fetch resolves.
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

List<Override> refreshingOverrides() => [
      // `FreshnessHeader` renders nothing at all when the source is
      // unreachable, so the status is pinned for the in-flight line to show.
      currentSourceStatusProvider
          .overrideWithValue(SourceConnectionStatus.remote),
      freshnessRegistryProvider.overrideWith(
        () => _PinnedFreshnessRegistry({
          SourceKeys.browse(FakeMediaSource.movies, const BrowseQuery()):
              Freshness(
            fetchedAt: DateTime(2026, 8, 4),
            isRefreshing: true,
          ),
        }),
      ),
    ];

void main() {
  testWidgets('grid starts just below the app bar on desktop', (tester) async {
    await pumpLibrary(tester, size: kDesktopSize);

    expect(firstPosterTop(tester), appBarBottom(tester) + kContentGap);
  });

  testWidgets('shows grid starts just below the app bar too', (tester) async {
    await pumpLibrary(
      tester,
      size: kDesktopSize,
      library: FakeMediaSource.shows,
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

    await tester.tap(find.byKey(const Key('source-view-toggle')));
    await tester.pumpAndSettle();

    final listTop = tester
        .widget<ListView>(find.byKey(const Key('source-library-list')))
        .padding;

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
}
