import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:material_ui/material_ui.dart';
import 'package:player/presentation/widgets/video_controls/chrome_title_block.dart';
import 'package:player/presentation/widgets/video_controls/chrome_top_bar.dart';

Widget _host(Widget child, {double width = 600, double textScale = 1.0}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

void main() {
  const tiers = ChromeTitleTier.values;

  test('spec table', () {
    expect(ChromeTitleBlock.heightFor(ChromeTitleTier.pointer), 46);
    expect(ChromeTitleBlock.heightFor(ChromeTitleTier.compact), 34);
    expect(ChromeTitleBlock.heightFor(ChromeTitleTier.remote), 62);
    expect(ChromeTitleBlock.gapFor(ChromeTitleTier.pointer), 6);
    expect(ChromeTitleBlock.gapFor(ChromeTitleTier.compact), 4);
    expect(ChromeTitleBlock.kickerFontSize(ChromeTitleTier.pointer), 13);
    expect(ChromeTitleBlock.titleFontSize(ChromeTitleTier.pointer), 22);
    expect(ChromeTitleBlock.kickerFontSize(ChromeTitleTier.compact), 11);
    expect(ChromeTitleBlock.titleFontSize(ChromeTitleTier.compact), 15);
    expect(ChromeTitleBlock.kickerFontSize(ChromeTitleTier.remote), 18);
    expect(ChromeTitleBlock.titleFontSize(ChromeTitleTier.remote), 30);
  });

  testWidgets('renders title and kicker with their keys', (tester) async {
    await tester.pumpWidget(
      _host(
        const ChromeTitleBlock(
          title: 'Low Tide',
          kicker: 'The Lantern Coast',
          tier: ChromeTitleTier.pointer,
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.byKey(ChromeTopBar.titleKey)).data,
      'Low Tide',
    );
    expect(
      tester.widget<Text>(find.byKey(ChromeTitleBlock.kickerKey)).data,
      'The Lantern Coast',
    );
  });

  for (final tier in tiers) {
    for (final withKicker in [true, false]) {
      testWidgets('height is heightFor($tier), kicker: $withKicker', (
        tester,
      ) async {
        await tester.pumpWidget(
          _host(
            ChromeTitleBlock(
              title: 'Low Tide',
              kicker: withKicker ? 'The Lantern Coast' : null,
              tier: tier,
            ),
          ),
        );
        expect(
          find.byKey(ChromeTitleBlock.kickerKey),
          withKicker ? findsOneWidget : findsNothing,
        );
        expect(
          tester.getSize(find.byType(ChromeTitleBlock)).height,
          ChromeTitleBlock.heightFor(tier),
        );
        expect(
          tester.getBottomLeft(find.byKey(ChromeTopBar.titleKey)).dy,
          closeTo(tester.getBottomLeft(find.byType(ChromeTitleBlock)).dy, 0.01),
        );
      });

      testWidgets('narrow and long, $tier, kicker: $withKicker', (
        tester,
      ) async {
        final long = List.filled(120, 'x').join();
        await tester.pumpWidget(
          _host(
            ChromeTitleBlock(
              title: long,
              kicker: withKicker ? long : null,
              tier: tier,
            ),
            width: 320,
          ),
        );
        expect(tester.takeException(), isNull);
        for (final t in tester.widgetList<Text>(find.byType(Text))) {
          expect(t.maxLines, 1);
          expect(t.overflow, TextOverflow.ellipsis);
        }
        expect(
          tester.getSize(find.byType(ChromeTitleBlock)).height,
          ChromeTitleBlock.heightFor(tier),
        );
        // Laid out at the box width and ellipsized at its designed size, not
        // laid out wide and shrunk.
        final keys = [
          ChromeTopBar.titleKey,
          if (withKicker) ChromeTitleBlock.kickerKey,
        ];
        for (final key in keys) {
          final finder = find.byKey(key);
          expect(tester.getSize(finder).width, 320, reason: '$key width');
          expect(
            tester.getRect(finder).width,
            closeTo(tester.getSize(finder).width, 0.01),
            reason: '$key is not scaled down',
          );
          expect(
            tester.getRect(finder).height,
            closeTo(tester.getSize(finder).height, 0.01),
            reason: '$key is not scaled down',
          );
          expect(
            tester.renderObject<RenderParagraph>(finder).didExceedMaxLines,
            isTrue,
            reason: '$key ellipsized',
          );
        }
      });

      testWidgets('text scale 2.0, $tier, kicker: $withKicker', (tester) async {
        await tester.pumpWidget(
          _host(
            ChromeTitleBlock(
              title: 'Low Tide',
              kicker: withKicker ? 'The Lantern Coast' : null,
              tier: tier,
            ),
            textScale: 2.0,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byType(ChromeTitleBlock)).height,
          ChromeTitleBlock.heightFor(tier),
        );
      });

      testWidgets('text scale 2.0 keeps designed glyphs and the full width, '
          '$tier, kicker: $withKicker', (tester) async {
        final long = List.filled(120, 'x').join();
        await tester.pumpWidget(
          _host(
            ChromeTitleBlock(
              title: long,
              kicker: withKicker ? long : null,
              tier: tier,
            ),
            width: 320,
            textScale: 2.0,
          ),
        );
        final keys = [
          ChromeTopBar.titleKey,
          if (withKicker) ChromeTitleBlock.kickerKey,
        ];
        for (final key in keys) {
          final finder = find.byKey(key);
          expect(tester.getSize(finder).width, 320, reason: '$key width');
          expect(
            MediaQuery.textScalerOf(tester.element(finder)).scale(10),
            10,
            reason: '$key effective scale',
          );
        }
      });
    }
  }

  testWidgets('under RTL the title hangs from the right edge', (tester) async {
    await tester.pumpWidget(
      _host(
        const Directionality(
          textDirection: TextDirection.rtl,
          child: ChromeTitleBlock(
            title: 'Low Tide',
            kicker: 'The Lantern Coast',
            tier: ChromeTitleTier.pointer,
          ),
        ),
      ),
    );
    final block = tester.getRect(find.byType(ChromeTitleBlock));
    for (final key in [ChromeTopBar.titleKey, ChromeTitleBlock.kickerKey]) {
      expect(
        tester.getRect(find.byKey(key)).right,
        closeTo(block.right, 0.01),
        reason: '$key right edge',
      );
    }
  });

  for (final tier in tiers) {
    testWidgets('short title is not scaled down, $tier', (tester) async {
      await tester.pumpWidget(
        _host(
          ChromeTitleBlock(
            title: 'Low Tide',
            kicker: 'The Lantern Coast',
            tier: tier,
          ),
        ),
      );
      for (final key in [ChromeTopBar.titleKey, ChromeTitleBlock.kickerKey]) {
        final finder = find.byKey(key);
        expect(
          tester.getRect(finder).size.width,
          closeTo(tester.getSize(finder).width, 0.01),
        );
        expect(
          tester.getRect(finder).size.height,
          closeTo(tester.getSize(finder).height, 0.01),
        );
      }
    });
  }

  testWidgets('holds no Focus or gesture handler and ignores pointers', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ChromeTitleBlock(
          title: 'Low Tide',
          kicker: 'The Lantern Coast',
          tier: ChromeTitleTier.remote,
        ),
      ),
    );
    final block = find.byType(ChromeTitleBlock);
    expect(
      find.descendant(of: block, matching: find.byType(Focus)),
      findsNothing,
    );
    expect(
      find.descendant(of: block, matching: find.byType(GestureDetector)),
      findsNothing,
    );
    expect(
      find.descendant(of: block, matching: find.byType(IgnorePointer)),
      findsWidgets,
    );
  });
}
