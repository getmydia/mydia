// Regression guard for the blank space above Collection detail's grid:
// `CollectionDetailScreen.gridTopPadding` must track the header's real
// height (`WindowTitleRow.heightOf`: the window-chrome band height on
// macOS/Linux, `kToolbarHeight` everywhere else) plus the fixed
// breathing-room gap `CollectionDetailScreen.gridTopGap`, not a flat literal
// that stops tracking the header once its height starts varying by
// platform. Mirrors `downloads_screen_layout_test.dart`, which guards the
// same class of bug for `DownloadsScreen.topSpacerHeight`.
//
// Uses `CollectionDetailScreen.header` and `CollectionDetailScreen.
// gridTopPadding` directly, in the same `Scaffold`/`GridView` shape `build`
// uses, rather than mounting the full screen: `CollectionDetailScreen.build`
// watches `collectionDetailControllerProvider(id)`, a GraphQL-backed stream,
// expensive to satisfy just to check where the first grid row lands.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/domain/models/recently_added_item.dart';
import 'package:player/presentation/screens/collections/collection_detail_screen.dart';
import 'package:player/presentation/widgets/window_chrome/window_title_row.dart';

const _markerKey = Key('first-grid-item');

/// Mounts the real header and the real top-padding formula in the same
/// shape `CollectionDetailScreen.build` uses, with a keyed marker item
/// standing in for the grid's real first poster.
Future<void> _pumpHarness(
  WidgetTester tester, {
  required WindowChromeInsets insets,
  required double statusBar,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        castCapabilitiesProvider.overrideWithValue(
          const CastCapabilities.full(),
        ),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            padding: EdgeInsets.only(top: statusBar + insets.height),
          ),
          child: WindowChromeInsets.scope(
            insets: insets,
            // Mirrors `CollectionDetailScreen.build`'s own wrap: the header
            // draws into the band itself, so the body sits under
            // `removeBand`.
            child: WindowChromeInsets.removeBand(
              child: Builder(
                builder: (context) => Scaffold(
                  extendBodyBehindAppBar: true,
                  appBar: CollectionDetailScreen.header(
                    context,
                    id: 'c1',
                    itemsData: const AsyncValue.data(<RecentlyAddedItem>[]),
                  ),
                  body: GridView.builder(
                    padding: EdgeInsets.only(
                      top: CollectionDetailScreen.gridTopPadding(context),
                    ),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 1,
                    ),
                    itemCount: 1,
                    itemBuilder: (context, index) =>
                        const SizedBox(key: _markerKey, height: 10),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'the first grid item starts at the header bottom plus the grid gap, '
      'under macOS insets', (tester) async {
    const macOS = WindowChromeInsets(height: 40, leading: 80, trailing: 0);
    await _pumpHarness(tester, insets: macOS, statusBar: 0);

    final headerBottom = tester.getRect(find.byType(WindowTitleRow)).bottom;
    final markerTop = tester.getRect(find.byKey(_markerKey)).top;

    // The header itself must be exactly the band height (40) with no status
    // bar folded in twice, otherwise the padding offset below would be right
    // for the wrong reason.
    expect(headerBottom, 40);
    expect(markerTop, headerBottom + CollectionDetailScreen.gridTopGap);
  });

  testWidgets(
      'the first grid item starts at the header bottom plus the grid gap, '
      'with a 24px status bar and no window chrome', (tester) async {
    await _pumpHarness(
      tester,
      insets: WindowChromeInsets.zero,
      statusBar: 24,
    );

    final headerBottom = tester.getRect(find.byType(WindowTitleRow)).bottom;
    final markerTop = tester.getRect(find.byKey(_markerKey)).top;

    // Before the header drew into the band, its true rendered height (its
    // own SafeArea plus kToolbarHeight) was 24 + 56 = 80, and the grid's
    // padding was a flat 100 -- a 44px gap that only matched by coincidence
    // when the status bar was 0. `gridTopPadding` now adds the real status
    // bar instead of ignoring it.
    expect(headerBottom, 24 + kToolbarHeight);
    expect(markerTop, headerBottom + CollectionDetailScreen.gridTopGap);
  });
}
