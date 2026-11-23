// On a television a focused poster grows by its size class (1.1) and a
// focused episode tile by its own (1.05), with the accent ring drawn outside
// the grown card. A rail clips at its own bounds, so the rail has to leave
// room above and below for that growth and the ring, or the viewer sees the
// top and bottom of the ring cut off on exactly the card they are on.
//
// Also pins that the emphasis adds no focus stop: D-pad Right and Left across
// a rail visit the same cards in the same order as before.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/domain/detail/detail_views.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/episode_rail.dart';
import 'package:player/presentation/widgets/focus_emphasis.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
import 'package:player/presentation/widgets/horizontal_rail.dart';
import 'package:player/presentation/widgets/media_card.dart';

import '../../test_utils/episode_views.dart';
import '../../test_utils/mock_network_images.dart';
import '../../test_utils/tv_shell_harness.dart';

/// A Chromecast's logical size, as the TV shell harness lays out.
void _tvView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1920, 1080);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

Widget _host(Widget child, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [child],
          ),
        ),
      ),
    );

const _cardKeys = [Key('card-0'), Key('card-1'), Key('card-2')];

/// Three poster cards with invented titles, in a rail sized and built the
/// way `SourcePosterRow` builds its rails.
Widget _posterRail() => HorizontalRail(
  itemCount: _cardKeys.length,
  height: 250,
  focusSize: FocusSize.poster,
  leftFadeKey: const ValueKey('poster-rail-left'),
  rightFadeKey: const ValueKey('poster-rail-right'),
  itemBuilder: (context, index) => SizedBox(
    width: 140,
    child: MediaCard(
      key: _cardKeys[index],
      title: [
        'Harbor of Lanterns',
        'The Quiet Orchard',
        'Glass Meridian',
      ][index],
      action: MediaCardAction.open,
      width: 130,
      height: 195,
      onTap: () {},
    ),
  ),
);

List<EpisodeView> _episodes() => [
  for (var n = 0; n < 3; n++)
    testEpisodeView(
      id: 'ep-$n',
      episodeNumber: n + 1,
      title: 'Lantern Keeper $n',
      thumbnailUrl: 'https://example.test/$n.jpg',
    ),
];

Future<void> _pumpEpisodeRail(
  WidgetTester tester, {
  bool watchedMenu = false,
}) async {
  final episodes = _episodes();
  await mockNetworkImages(() async {
    await tester.pumpWidget(
      _host(
        EpisodeRail(
          episodes: episodes,
          onEpisodeTap: (_) {},
          onWatchedAction: watchedMenu ? (_, _) async {} : null,
        ),
        overrides: [
          for (final e in episodes)
            isItemDownloadedProvider(e.target.ref).overrideWith((ref) => false),
        ],
      ),
    );
    await tester.pump();
  });
}

/// Moves focus onto the card under [card], the way traversal would land.
Future<void> _focus(WidgetTester tester, Finder card) async {
  Focus.of(
    tester.element(
      find.descendant(of: card, matching: find.byKey(FocusHighlight.ringKey)),
    ),
  ).requestFocus();
  await tester.pumpAndSettle();
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

/// Right twice, then Left twice, recording the focused card after each move.
Future<List<Key?>> _walk(WidgetTester tester, List<Key> keys) async {
  final visited = <Key?>[_focusedCard(keys)];
  for (final key in [
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowLeft,
  ]) {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
    visited.add(_focusedCard(keys));
  }
  return visited;
}

/// Asserts the focused card's ring, grown with the card, lies inside the
/// rail's viewport: the viewport is what clips.
void _expectRingInsideRail(WidgetTester tester, Finder card) {
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
  expect(scale, greaterThan(1.0), reason: 'the focused card should grow');
  final painter =
      tester
              .widget<CustomPaint>(
                find.descendant(
                  of: emphasis,
                  matching: find.byKey(FocusEmphasis.ringKey),
                ),
              )
              .foregroundPainter!
          as FocusEmphasisPainter;
  expect(painter.visible, isTrue);

  // The growth is painted, not laid out, so getRect is the unscaled card:
  // grow it about its centre.
  final laidOut = tester.getRect(
    find.descendant(of: emphasis, matching: find.byKey(FocusEmphasis.ringKey)),
  );
  final grown = Rect.fromCenter(
    center: laidOut.center,
    width: laidOut.width * scale,
    height: laidOut.height * scale,
  );
  // The ring's outer edge, also scaled with the card.
  final ring = grown.inflate((painter.gap + FocusEmphasis.ringWidth) * scale);
  final rail = tester.getRect(
    find.ancestor(of: card, matching: find.byType(Viewport)),
  );
  const tolerance = 0.01;
  expect(ring.top, greaterThanOrEqualTo(rail.top - tolerance));
  expect(ring.bottom, lessThanOrEqualTo(rail.bottom + tolerance));
  expect(ring.left, greaterThanOrEqualTo(rail.left - tolerance));
  expect(ring.right, lessThanOrEqualTo(rail.right + tolerance));
}

void main() {
  group('rails of emphasized cards on the television tier', () {
    testWidgets('a focused MediaCard grows by the poster class', (
      tester,
    ) async {
      _tvView(tester);
      await tester.pumpWidget(_host(_posterRail()));
      await _focus(tester, find.byKey(_cardKeys[1]));

      final scale = tester
          .widget<FocusPaintScale>(
            find.descendant(
              of: find.byKey(_cardKeys[1]),
              matching: find.byKey(FocusEmphasis.scaleKey),
            ),
          )
          .scale;
      expect(scale, FocusSize.poster.scale);
    });

    testWidgets('a MediaCard focused in a rail is not clipped', (tester) async {
      _tvView(tester);
      await tester.pumpWidget(_host(_posterRail()));
      await _focus(tester, find.byKey(_cardKeys[1]));

      _expectRingInsideRail(tester, find.byKey(_cardKeys[1]));
    });

    testWidgets('D-pad traversal across the poster rail is unchanged', (
      tester,
    ) async {
      _tvView(tester);
      await tester.pumpWidget(_host(_posterRail()));
      await _focus(tester, find.byKey(_cardKeys[0]));

      expect(await _walk(tester, _cardKeys), [
        _cardKeys[0],
        _cardKeys[1],
        _cardKeys[2],
        _cardKeys[1],
        _cardKeys[0],
      ]);
    });

    testWidgets('a focused episode card grows by the tile class', (
      tester,
    ) async {
      _tvView(tester);
      await _pumpEpisodeRail(tester);
      await _focus(tester, find.byKey(const ValueKey('ep-1')));

      final scale = tester
          .widget<FocusPaintScale>(
            find.descendant(
              of: find.byKey(const ValueKey('ep-1')),
              matching: find.byKey(FocusEmphasis.scaleKey),
            ),
          )
          .scale;
      expect(scale, FocusSize.tile.scale);
    });

    testWidgets('an episode card focused in the episode rail is not clipped', (
      tester,
    ) async {
      _tvView(tester);
      await _pumpEpisodeRail(tester);
      await _focus(tester, find.byKey(const ValueKey('ep-1')));

      _expectRingInsideRail(tester, find.byKey(const ValueKey('ep-1')));
    });

    testWidgets('D-pad traversal across the episode rail is unchanged', (
      tester,
    ) async {
      _tvView(tester);
      await _pumpEpisodeRail(tester);
      const keys = [ValueKey('ep-0'), ValueKey('ep-1'), ValueKey('ep-2')];
      await _focus(tester, find.byKey(keys[0]));

      expect(await _walk(tester, keys), [
        keys[0],
        keys[1],
        keys[2],
        keys[1],
        keys[0],
      ]);
    });

    testWidgets(
      'with the watched menu shown, D-pad Right and Left still move card to '
      'card',
      (tester) async {
        _tvView(tester);
        await _pumpEpisodeRail(tester, watchedMenu: true);
        expect(find.byType(PopupMenuButton<String>), findsNWidgets(3));
        const keys = [ValueKey('ep-0'), ValueKey('ep-1'), ValueKey('ep-2')];
        await _focus(tester, find.byKey(keys[0]));

        // The card's own node, not anything inside it such as the menu.
        FocusNode cardNode(Key key) => Focus.of(
          tester.element(
            find.descendant(
              of: find.byKey(key),
              matching: find.byKey(FocusHighlight.ringKey),
            ),
          ),
        );

        final visited = <FocusNode?>[FocusManager.instance.primaryFocus];
        for (final key in [
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowLeft,
        ]) {
          await tester.sendKeyEvent(key);
          await tester.pumpAndSettle();
          visited.add(FocusManager.instance.primaryFocus);
        }
        expect(visited, [
          for (final i in [0, 1, 2, 1, 0]) cardNode(keys[i]),
        ]);
      },
    );
  }, skip: tvSkipReason);
}
