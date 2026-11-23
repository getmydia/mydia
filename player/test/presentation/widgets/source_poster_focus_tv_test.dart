// SourcePoster is the poster a television viewer actually moves across: every
// home rail, library, listing, search and collection grid is made of them. On
// the television tier a focused one grows by the poster class (1.1) with the
// accent ring outside it, and neither the rail nor the grid may cut that ring
// off, at the first card or in the middle.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/breakpoints.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/sources/source_poster_row.dart';
import 'package:player/presentation/widgets/browse_grid.dart';
import 'package:player/presentation/widgets/focus_emphasis.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
import 'package:player/presentation/widgets/horizontal_rail.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../test_utils/mock_network_images.dart';
import '../../test_utils/tv_shell_harness.dart';
import '../screens/sources/fake_media_source.dart';

/// A Chromecast's logical size, as the TV shell harness lays out.
void _tvView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

final _items = [for (var n = 1; n <= 12; n++) fakeMovie(n)];

Key _posterKey(ItemSummary item) =>
    ValueKey('source-poster-${item.ref.externalId}');

Future<void> _pump(WidgetTester tester, Widget body) async {
  await mockNetworkImages(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaSourceProvider(fakeSourceId)
              .overrideWithValue(FakeMediaSource()),
        ],
        child: MaterialApp(
          theme: AppTheme.darkTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: body),
        ),
      ),
    );
    await tester.pump();
  });
}

Widget _row() => ListView(
  children: [SourcePosterRow(title: 'Shelf', railId: 'shelf', items: _items)],
);

Widget _grid() => BrowseGrid(
  itemCount: _items.length,
  // What BrowseScaffold hands its body under a toolbar-height bar.
  scrollTopPadding: kToolbarHeight + 8,
  itemId: (index) => _items[index].ref,
  itemBuilder: (context, index) => SourcePoster(
    key: _posterKey(_items[index]),
    item: _items[index],
    onTap: () {},
  ),
);

/// Runs focus, scroll and scale animations to rest. Not pumpAndSettle: a
/// poster's loading placeholder animates for as long as its artwork is out.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _focus(WidgetTester tester, Finder card) async {
  Focus.of(
    tester.element(
      find.descendant(of: card, matching: find.byKey(FocusHighlight.ringKey)),
    ),
  ).requestFocus();
  await _settle(tester);
}

/// The key, among [keys], of the card holding primary focus.
Key? _focusedCard(List<Key> keys) {
  Key? found;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
    final key = e.widget.key;
    if (keys.contains(key)) {
      found = key;
      return false;
    }
    return true;
  });
  return found;
}

/// Asserts [card] is focused, grown by the poster class, and that its ring
/// lies inside the viewport that clips it, on all four sides.
void _expectRingInside(WidgetTester tester, Finder card) {
  final emphasis = find.descendant(
    of: card,
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
  expect(scale, FocusSize.poster.scale);
  final ringPaint = find.descendant(
    of: emphasis,
    matching: find.byKey(FocusEmphasis.ringKey),
  );
  final painter =
      tester.widget<CustomPaint>(ringPaint).foregroundPainter!
          as FocusEmphasisPainter;
  expect(painter.visible, isTrue);

  // The growth is painted, not laid out, so getRect is the unscaled card:
  // grow it about its centre, then add the gap and ring, which scale too.
  final laidOut = tester.getRect(ringPaint);
  final ring = Rect.fromCenter(
    center: laidOut.center,
    width: laidOut.width * scale,
    height: laidOut.height * scale,
  ).inflate((painter.gap + FocusEmphasis.ringWidth) * scale);
  final viewport = tester.getRect(
    find.ancestor(of: card, matching: find.byType(Viewport)).first,
  );
  const tolerance = 0.01;
  expect(ring.top, greaterThanOrEqualTo(viewport.top - tolerance));
  expect(ring.bottom, lessThanOrEqualTo(viewport.bottom + tolerance));
  expect(ring.left, greaterThanOrEqualTo(viewport.left - tolerance));
  expect(ring.right, lessThanOrEqualTo(viewport.right + tolerance));
}

void main() {
  group('SourcePoster focus on the television tier', () {
    testWidgets('the first poster of a home rail is not clipped', (
      tester,
    ) async {
      _tvView(tester);
      await _pump(tester, _row());
      final card = find.byKey(_posterKey(_items[0]));
      await _focus(tester, card);

      _expectRingInside(tester, card);
    });

    testWidgets('a middle poster of a home rail is not clipped', (
      tester,
    ) async {
      _tvView(tester);
      await _pump(tester, _row());
      final card = find.byKey(_posterKey(_items[2]));
      await _focus(tester, card);

      _expectRingInside(tester, card);
    });

    testWidgets('D-pad traversal across a home rail is unchanged', (
      tester,
    ) async {
      _tvView(tester);
      await _pump(tester, _row());
      final keys = [for (final item in _items.take(4)) _posterKey(item)];
      await _focus(tester, find.byKey(keys[0]));

      final visited = <Key?>[_focusedCard(keys)];
      for (final key in [
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowLeft,
      ]) {
        await tester.sendKeyEvent(key);
        await _settle(tester);
        visited.add(_focusedCard(keys));
      }
      expect(visited, [keys[0], keys[1], keys[2], keys[3], keys[2], keys[1]]);
    });

    testWidgets('the rail grows by the focus bleed, the posters do not', (
      tester,
    ) async {
      _tvView(tester);
      await _pump(tester, _row());

      final bleed = FocusEmphasis.bleed(
        SourcePosterRow.rowHeight,
        FocusSize.poster,
      ).ceilToDouble();
      expect(
        tester
            .getSize(
              find.descendant(
                of: find.byType(HorizontalRail),
                matching: find.byType(Viewport),
              ),
            )
            .height,
        SourcePosterRow.rowHeight + bleed * 2,
      );
      expect(
        tester.getSize(find.byKey(_posterKey(_items[0]))).height,
        SourcePosterRow.rowHeight,
      );
    });

    for (final (label, index) in [
      ('the first cell', 0),
      ('a middle cell', 6),
    ]) {
      testWidgets('$label of a poster grid is not clipped', (tester) async {
        _tvView(tester);
        await _pump(tester, _grid());
        final card = find.byKey(_posterKey(_items[index]));
        // Focus alone: the emphasis scrolls its own ring into view.
        await _focus(tester, card);

        _expectRingInside(tester, card);
      });
    }

    testWidgets('the last cell of a poster grid, reached by D-pad, is not '
        'clipped', (tester) async {
      _tvView(tester);
      await _pump(tester, _grid());
      // Five columns at this width: 0-4, 5-9, then 10 and 11.
      expect(libraryCrossAxisCount(960), 5);
      await _focus(tester, find.byKey(_posterKey(_items[0])));
      for (final key in [
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowRight,
      ]) {
        await tester.sendKeyEvent(key);
        await _settle(tester);
      }
      final last = _posterKey(_items[11]);
      expect(_focusedCard([last]), last);

      _expectRingInside(tester, find.byKey(last));
    });

    testWidgets('D-pad traversal across a poster grid row is unchanged', (
      tester,
    ) async {
      _tvView(tester);
      await _pump(tester, _grid());
      final keys = [for (final item in _items) _posterKey(item)];
      await _focus(tester, find.byKey(keys[0]));

      final visited = <Key?>[_focusedCard(keys)];
      for (final key in [
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowLeft,
      ]) {
        await tester.sendKeyEvent(key);
        await _settle(tester);
        visited.add(_focusedCard(keys));
      }
      expect(visited, [keys[0], keys[1], keys[2], keys[1]]);
    });
  }, skip: tvSkipReason);
}
