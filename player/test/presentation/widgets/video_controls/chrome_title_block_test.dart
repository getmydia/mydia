import 'package:flutter_test/flutter_test.dart';
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
    }
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
