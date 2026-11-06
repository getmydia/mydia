// A source library remembers its place on a television: the poster grid and
// the sort/filter chip bar above it each return focus to the item that last
// had it, keyed by the item (the poster's ref, the chip's option id), so
// moving between the bar and the grid never lands on "whatever is nearest".
//
// The real SourceLibraryScreen inside the shell's real content region (see
// `tv_shell_harness.dart`), at 1920x1080.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/sources/source_library_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/tv_shell_harness.dart';
import 'fake_media_source.dart';

void main() {
  group('Source library focus memory (requires MYDIA_FORCE_TV=true)', () {
    Key poster(int n) => ValueKey('source-poster-m$n');
    const titleSort = Key('source-sort-title');
    const unwatched = Key('source-filter-unwatched');

    Future<void> pumpLibrary(WidgetTester tester) async {
      final fake = FakeMediaSource(movieCount: 60);
      await TvShell().pump(
        tester,
        const SourceLibraryScreen(library: FakeMediaSource.movies),
        overrides: [
          mediaSourceProvider(fakeSourceId).overrideWithValue(fake),
          coreSettingsServiceProvider
              .overrideWithValue(SettingsService(storage: MockAuthStorage())),
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
      await pumpLibrary(tester);
      // The last chip, so the poster below it is not the first one.
      await focusIn(tester, unwatched);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectFocusIn(poster(1));
    });

    testWidgets('the chip bar is re-entered on the chip that left it',
        (tester) async {
      await pumpLibrary(tester);
      await focusIn(tester, titleSort);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(poster(1));
      for (var i = 0; i < 4; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expectFocusIn(poster(5));

      await press(tester, LogicalKeyboardKey.arrowUp);

      expectFocusIn(titleSort);
    });

    testWidgets(
        'UP then DOWN returns to the poster that left, with the grid scrolled',
        (tester) async {
      await pumpLibrary(tester);
      await focusIn(tester, titleSort);
      await press(tester, LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < 4; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expectFocusIn(poster(5));
      await press(tester, LogicalKeyboardKey.arrowUp);
      expectFocusIn(titleSort);
      // Leave the chip the viewer arrived on, so the next DOWN is not a
      // replay of Flutter's own up/down history.
      await press(tester, LogicalKeyboardKey.arrowRight);

      final grid = gridPosition(tester);
      grid.jumpTo(grid.pixels + 150);
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(poster(5));
    });
  }, skip: tvSkipReason);
}
