// Off the television tier a poster row lays out exactly as it did before the
// television focus emphasis: the rail is the row height, its cards fill it,
// and no emphasis wraps a poster. The television side is in
// test/presentation/widgets/source_poster_focus_tv_test.dart.

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/sources/source_poster_row.dart';
import 'package:player/presentation/widgets/focus_emphasis.dart';
import 'package:player/presentation/widgets/horizontal_rail.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/mock_network_images.dart';
import 'fake_media_source.dart';

void main() {
  testWidgets('off the television tier a poster row keeps its layout', (
    tester,
  ) async {
    final items = [for (var n = 1; n <= 4; n++) fakeMovie(n)];
    await mockNetworkImages(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            mediaSourceProvider(fakeSourceId)
                .overrideWithValue(FakeMediaSource()),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ListView(
                children: [
                  SourcePosterRow(
                    title: 'Shelf',
                    railId: 'shelf',
                    items: items,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    });

    expect(
      HorizontalRail.focusBleed(SourcePosterRow.rowHeight, FocusSize.poster),
      0,
    );
    final rail = find.byType(HorizontalRail);
    expect(tester.getSize(rail).height, SourcePosterRow.rowHeight);
    expect(
      tester
          .getSize(find.descendant(of: rail, matching: find.byType(Viewport)))
          .height,
      SourcePosterRow.rowHeight,
    );
    expect(
      tester.getSize(find.byType(SourcePoster).first),
      const Size(SourcePosterRow.posterWidth, SourcePosterRow.rowHeight),
    );
    expect(find.byType(FocusEmphasis), findsNothing);
  }, skip: InputCapabilities.directionalPrimary);
}
