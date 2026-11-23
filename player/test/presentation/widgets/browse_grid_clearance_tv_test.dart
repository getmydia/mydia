// A browse page draws its glass bar over the top of the scroll area, and a
// focused poster on the television tier grows and rings past its cell. The
// grid's first row must start low enough that a focused first-row poster,
// ring included, sits below the bar and below any chip row above the grid,
// since a list cannot scroll down past its own top to reveal it.
//
// The real screens inside the shell's real content region, at a
// Chromecast's 960x540 logical pixels.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/all_servers/all_servers_grid_screen.dart';
import 'package:player/presentation/screens/sources/source_library_screen.dart';
import 'package:player/presentation/widgets/browse_scaffold.dart';
import 'package:player/presentation/widgets/focus_emphasis.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../domain/merged/fake_merged_source.dart';
import '../../test_utils/mock_auth_storage.dart';
import '../../test_utils/tv_shell_harness.dart';
import '../screens/sources/fake_media_source.dart';

/// The painted top of the focused poster's ring inside [poster]: the laid
/// out cell grown about its centre, then the gap and ring, which grow too.
double _ringTop(WidgetTester tester, Key poster) {
  final emphasis = find.descendant(
    of: find.byKey(poster),
    matching: find.byType(FocusEmphasis),
  );
  final scale = tester
      .widget<FocusPaintScale>(
        find.descendant(
          of: emphasis,
          matching: find.byKey(FocusEmphasis.scaleKey),
        ),
      )
      .scale;
  expect(scale, FocusSize.poster.scale, reason: 'the poster should be grown');
  final ring = find.descendant(
    of: emphasis,
    matching: find.byKey(FocusEmphasis.ringKey),
  );
  final painter =
      tester.widget<CustomPaint>(ring).foregroundPainter!
          as FocusEmphasisPainter;
  expect(painter.visible, isTrue);
  final cell = tester.getRect(ring);
  return cell.center.dy -
      cell.height * scale / 2 -
      (painter.gap + FocusEmphasis.ringWidth) * scale;
}

/// The bottom of the page's glass bar, the chrome `scrollTopPadding` clears.
double _barBottom(WidgetTester tester) => tester
    .getRect(
      find
          .descendant(
            of: find.byType(BrowseScaffold),
            matching: find.byType(PreferredSize),
          )
          .first,
    )
    .bottom;

void main() {
  group('a focused first-row poster clears the chrome above the grid', () {
    testWidgets('in a source library', (tester) async {
      await TvShell().pump(
        tester,
        const SourceLibraryScreen(library: FakeMediaSource.movies),
        overrides: [
          mediaSourceProvider(fakeSourceId)
              .overrideWithValue(FakeMediaSource(movieCount: 30)),
          coreSettingsServiceProvider.overrideWithValue(
            SettingsService(storage: MockAuthStorage()),
          ),
          sourceArtworkProvider.overrideWith((ref, key) async => null),
        ],
      );
      // The chip bar is the bar's second row here.
      await focusIn(tester, const Key('source-sort-title'));
      await press(tester, LogicalKeyboardKey.arrowDown);
      const first = ValueKey('source-poster-m1');
      expectFocusIn(first);

      expect(
        _ringTop(tester, first),
        greaterThanOrEqualTo(_barBottom(tester) - 0.01),
      );
    });

    testWidgets('in the All servers grid', (tester) async {
      final server = fakeServer('a');
      String id(int n) => 'f${n.toString().padLeft(2, '0')}';
      final source = FakeMergedSource(
        server,
        movies: [
          for (var n = 0; n < 30; n++)
            item(
              server,
              id(n),
              sortTitle: id(n),
              addedAt: DateTime.utc(2024, 1, 1 + n),
            ),
        ],
      );
      await TvShell().pump(
        tester,
        const AllServersGridScreen(kind: LibraryKind.movies),
        overrides: [
          allServersSourcesProvider.overrideWithValue([source]),
          sourcesProvider.overrideWithValue([source.source]),
          mediaSourceProvider(source.id).overrideWithValue(source),
          allServersNeedSignInProvider.overrideWithValue(const []),
          sourceArtworkProvider.overrideWith((ref, key) async => null),
        ],
      );
      const titleSort = Key('all-grid-sort-title');
      await focusIn(tester, titleSort);
      await press(tester, LogicalKeyboardKey.arrowDown);
      final first = ValueKey('all-poster-${server.id.value}-${id(0)}');
      expectFocusIn(first);

      // Here the chip row sits in the body, between the bar and the grid.
      final chipBottom = tester.getRect(find.byKey(titleSort)).bottom;
      final ringTop = _ringTop(tester, first);
      expect(ringTop, greaterThanOrEqualTo(_barBottom(tester) - 0.01));
      expect(ringTop, greaterThanOrEqualTo(chipBottom - 0.01));
    });
  }, skip: tvSkipReason);
}
