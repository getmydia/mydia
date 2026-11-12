// A collection's poster grid remembers its place on a television: entering it
// from the header lands on its first poster on a first visit and on the
// poster that left it afterwards, keyed by the item's ref. The grid is the
// screen's own `GridView` rather than `BrowseGrid`, so it opts in by hand.
//
// The real CollectionDetailScreen inside the shell's real content region
// (see `tv_shell_harness.dart`), at 1920x1080.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/material.dart' hide Page;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/collections/collection_detail_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/tv_shell_harness.dart';
import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';

void main() {
  group('Collection detail focus memory (requires MYDIA_FORCE_TV=true)', () {
    Key poster(int n) => ValueKey('source-poster-m$n');

    Future<void> pumpCollection(WidgetTester tester) async {
      final source = FakeCapableSource()
        ..collectionItemPages = [
          Page(items: [for (var n = 1; n <= 40; n++) fakeMovie(n)]),
        ];
      await TvShell().pump(
        tester,
        const CollectionDetailScreen(
            sourceId: fakeSourceId, collectionId: 'c1'),
        overrides: [
          mediaSourceProvider(source.id).overrideWithValue(source),
          sourceArtworkProvider.overrideWith((ref, key) async => null),
        ],
      );
    }

    ScrollPosition gridPosition(WidgetTester tester) => tester
        .state<ScrollableState>(find
            .ancestor(
              of: find.byKey(poster(1), skipOffstage: false),
              matching: find.byType(Scrollable),
            )
            .first)
        .position;

    testWidgets('the grid entered for the first time lands on its first poster',
        (tester) async {
      await pumpCollection(tester);
      // A television has no cast button, so the back button is the header
      // control the viewer comes down from.
      await focusIn(tester, CollectionDetailScreen.backKey);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectFocusIn(poster(1));
    });

    testWidgets(
        'the grid is re-entered on the poster that left it, after scrolling',
        (tester) async {
      await pumpCollection(tester);
      await focusIn(tester, CollectionDetailScreen.backKey);
      await press(tester, LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < 3; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expectFocusIn(poster(4));

      // Back up to the header, then onto the back button by hand, so the
      // next DOWN is not a replay of Flutter's own up/down history. The back
      // button sits above the first poster, so geometry alone would pick
      // poster 1: landing on poster 4 is the memory at work.
      await press(tester, LogicalKeyboardKey.arrowUp);
      await focusIn(tester, CollectionDetailScreen.backKey);

      final grid = gridPosition(tester);
      grid.jumpTo(grid.pixels + 150);
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(poster(4));
    });
  }, skip: tvSkipReason);
}
