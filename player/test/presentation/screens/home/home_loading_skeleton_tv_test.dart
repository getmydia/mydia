// On the television tier each skeleton rail leaves the same focus room as the
// loaded rail it stands in for: Continue Watching's landscape row the tile
// class, the library rows the poster class. Otherwise the home screen jumps
// when the rows load.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/presentation/screens/home/home_loading_skeleton.dart';
import 'package:player/presentation/screens/sources/continue_watching_card.dart';
import 'package:player/presentation/screens/sources/source_poster_row.dart';
import 'package:player/presentation/widgets/focus_emphasis.dart';
import 'package:player/presentation/widgets/horizontal_rail.dart';

void main() {
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
            'InputCapabilities.directionalPrimary; CI runs it in the '
            '"Run television-tier tests" step.';

  testWidgets('skeleton rails leave tile room, then poster room', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HomeLoadingSkeleton())),
    );
    await tester.pump();

    double railExtent(int index) => tester
        .getSize(
          find
              .descendant(
                of: find.byKey(HomeLoadingSkeleton.railKey).at(index),
                matching: find.byWidgetPredicate(
                  (w) => w is ListView && w.scrollDirection == Axis.horizontal,
                ),
              )
              .first,
        )
        .height;

    final context = tester.element(find.byType(HomeLoadingSkeleton));
    final landscape = ContinueWatchingCard.heightFor(context, hasCaption: true);
    final tileBleed = HorizontalRail.focusBleed(landscape, FocusSize.tile);
    expect(tileBleed, greaterThan(0));
    expect(
      tileBleed,
      lessThan(HorizontalRail.focusBleed(landscape, FocusSize.poster)),
    );
    expect(railExtent(0), landscape + tileBleed * 2);
    expect(
      railExtent(1),
      SourcePosterRow.rowHeight +
          HorizontalRail.focusBleed(
                SourcePosterRow.rowHeight,
                FocusSize.poster,
              ) *
              2,
    );
  }, skip: skipReason != false);
}
