// Pins a LAYOUT CONTRACT for `detailHeroAppBar`, the shared hero builder the
// movie, show and episode detail screens all use: the hero art runs to the
// window's true top edge (behind the traffic lights / Linux buttons), and
// the back button plus cast button sit in the title-bar band drawn on top of
// it. `_detailScreenLike` reproduces the `CustomScrollView` + pinned
// `SliverAppBar` shape each real screen builds via `detailHeroAppBar`, but
// pumps that shared function directly rather than mounting a screen: the
// screens need a provider graph, a GraphQL client and a router location this
// suite does not construct, while the header layout contract is the same
// function call in each of them.

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/presentation/screens/episode/episode_detail_screen.dart';
import 'package:player/presentation/screens/movie/movie_detail_screen.dart';
import 'package:player/presentation/screens/show/show_detail_screen.dart';
import 'package:player/presentation/widgets/detail_hero_app_bar.dart';
import 'package:player/presentation/widgets/window_chrome/window_title_row.dart';

import '../../helpers/cast_test_overrides.dart';

const Key _backKey = Key('detail-back');
const Key _heroKey = Key('detail-hero');

/// The structure every detail screen shares: a `CustomScrollView` whose first
/// sliver is `detailHeroAppBar`, pinned, carrying the back button in its
/// title row and the hero art in its flexible space. Mirrors
/// `movie_detail_screen.dart`, `show_detail_screen.dart` and
/// `episode_detail_screen.dart`, none of which can be mounted here without
/// their provider graphs.
Widget _detailScreenLike({
  required WindowChromeInsets insets,
  double statusBar = 0,
}) =>
    ProviderScope(
      overrides: castCapableOverrides(),
      child: MediaQuery(
        data: MediaQueryData(
          size: const Size(1300, 800),
          padding: EdgeInsets.only(top: statusBar + insets.height),
        ),
        child: WindowChromeInsets.scope(
          insets: insets,
          child: MaterialApp(
            home: WindowChromeInsets.removeBand(
              child: Builder(
                builder: (context) => Scaffold(
                  body: CustomScrollView(
                    slivers: [
                      detailHeroAppBar(
                        context: context,
                        expandedHeight: 380,
                        back:
                            const Icon(Icons.arrow_back_rounded, key: _backKey),
                        background:
                            const ColoredBox(color: Colors.blue, key: _heroKey),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 2000)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

const _mac = WindowChromeInsets(height: 40, leading: 80, trailing: 0);

/// Resizes the real test surface to 1300x800 before pumping.
///
/// `flutter_test`'s default surface is a fixed 800x600, independent of
/// whatever `MediaQueryData` a widget tree nests further down -- nesting
/// only changes what `MediaQuery.of(context)` *reports*, not the real
/// constraints the render tree lays out with. `Breakpoints` and
/// `WindowTitleRow.endGutter` read the former; `Scaffold`'s actual pixel
/// width comes from the latter, which is why the two would disagree on
/// where the trailing edge actually is without this. Mirrors
/// `window_title_row_test.dart`'s `_pump` helper.
Future<void> _pump(
  WidgetTester tester, {
  required WindowChromeInsets insets,
  double statusBar = 0,
}) async {
  tester.view.physicalSize = const Size(1300, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    _detailScreenLike(insets: insets, statusBar: statusBar),
  );
}

void main() {
  group('detailHeroAppBar under the macOS traffic lights', () {
    testWidgets(
        'the hero runs to the window top edge and the back button centers '
        'in the band, clear of the lights', (tester) async {
      await _pump(tester, insets: _mac);

      // Full-bleed: the hero paints from the window's true top, behind the
      // band, not below a reserved strip.
      expect(tester.getRect(find.byKey(_heroKey)).top, 0);

      final backRect = tester.getRect(find.byKey(_backKey));
      expect(backRect.left, greaterThanOrEqualTo(80));
      // Vertically centered in the 40pt band (center at y=20).
      expect((backRect.center.dy - 20).abs(), lessThan(1));
    });

    testWidgets('the cast button lands at the shared trailing gutter',
        (tester) async {
      await _pump(tester, insets: _mac);

      final cast = tester.getRect(find.byKey(WindowTitleRow.castKey));
      expect(cast.right, 1300 - 24);
    });

    testWidgets(
        'the pinned title row keeps the back button clear of the lights '
        'once the hero collapses under scroll', (tester) async {
      await _pump(tester, insets: _mac);

      // The scroll view fills the viewport; its center sits well below the
      // 40pt band, so this drag never touches the drag band underneath the
      // title row.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      // Drains the drag band's double-tap recognizer in case the drag's
      // start or end point ever lands inside the band; harmless when it
      // didn't.
      await tester.pump(kDoubleTapTimeout);

      final backRect = tester.getRect(find.byKey(_backKey));
      expect(backRect.left, greaterThanOrEqualTo(80));
      expect(backRect.top, inInclusiveRange(0, 40));
    });
  });

  group('detailHeroAppBar with no window chrome', () {
    testWidgets('the back button clears a phone status bar', (tester) async {
      await _pump(tester, insets: WindowChromeInsets.zero, statusBar: 24);

      expect(
          tester.getRect(find.byKey(_backKey)).top, greaterThanOrEqualTo(24));
    });
  });

  group('loading and error states clear the macOS traffic lights', () {
    // Regression coverage: before this fix, `_buildLoadingState` and
    // `_buildErrorState` in all three screens put the back button in a bare
    // `SliverAppBar`'s `leading` slot, padded by a flat `EdgeInsets.all(8)`.
    // That relied on `AppBar` folding the ambient `MediaQuery.padding.top`
    // into its own top offset to clear the traffic lights -- the same
    // padding `WindowChromeInsets.removeBand` (needed so the *loaded* hero
    // can draw its own title row into the band) strips out for these states
    // too, so the flat `Padding(8)` leading landed the back icon squarely
    // under the lights (measured: (8,8)-(48,48), inside the lights' own
    // (12,13)-(71,26)). Routing these states through `detailHeroAppBar`,
    // like the loaded hero, is the fix; this pins the contract for every
    // screen's loading and error branches via each screen's
    // `@visibleForTesting` seam, rather than mirroring the shape (a plain
    // `Object error` stands in for a real GraphQL failure since only the
    // header, not the error message body, is under test).
    final cases = <String, Widget Function(BuildContext, WidgetRef)>{
      'MovieDetailScreen loading': (context, ref) =>
          const MovieDetailScreen(id: 'm1').loadingStateForTest(context),
      'MovieDetailScreen error': (context, ref) =>
          const MovieDetailScreen(id: 'm1')
              .errorStateForTest(context, ref, 'boom'),
      'ShowDetailScreen loading': (context, ref) =>
          const ShowDetailScreen(id: 's1').loadingStateForTest(context),
      'ShowDetailScreen error': (context, ref) =>
          const ShowDetailScreen(id: 's1')
              .errorStateForTest(context, ref, 'boom'),
      'EpisodeDetailScreen loading': (context, ref) =>
          const EpisodeDetailScreen(id: 'e1').loadingStateForTest(context),
      'EpisodeDetailScreen error': (context, ref) =>
          const EpisodeDetailScreen(id: 'e1')
              .errorStateForTest(context, ref, 'boom'),
    };

    for (final MapEntry(key: name, value: builder) in cases.entries) {
      testWidgets(name, (tester) async {
        tester.view.physicalSize = const Size(1300, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(
            overrides: castCapableOverrides(),
            child: MediaQuery(
              data: MediaQueryData(
                size: const Size(1300, 800),
                padding: EdgeInsets.only(top: _mac.height),
              ),
              child: WindowChromeInsets.scope(
                insets: _mac,
                child: MaterialApp(
                  home: WindowChromeInsets.removeBand(
                    child: Consumer(
                      builder: (context, ref, _) =>
                          Scaffold(body: builder(context, ref)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        final backRect = tester.getRect(find.byIcon(Icons.arrow_back_rounded));
        expect(backRect.left, greaterThanOrEqualTo(80));
        // Vertically centered in the 40pt band (center at y=20), same as the
        // loaded hero's back button.
        expect((backRect.center.dy - 20).abs(), lessThan(1));
      });
    }
  });
}
