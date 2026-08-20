import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/presentation/widgets/video_controls/chrome_top_bar.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.white)),
            child,
          ],
        ),
      ),
    );

void main() {
  group('ChromeTopBar', () {
    testWidgets('renders a back pill that fires', (tester) async {
      var backed = false;
      await tester.pumpWidget(
        _host(
          ChromeTopBar(
            tier: PlayerGlassTier.full,
            onBack: () => backed = true,
          ),
        ),
      );

      expect(find.byKey(ChromeTopBar.backKey), findsOneWidget);
      await tester.tap(find.byKey(ChromeTopBar.backKey));
      expect(backed, isTrue);
    });

    testWidgets(
        'the back pill is present but inert when onBack is null, so the '
        'title stays optically centered rather than the pill vanishing',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const ChromeTopBar(
            tier: PlayerGlassTier.full,
            title: 'Silo',
          ),
        ),
      );

      // Rendered...
      expect(find.byKey(ChromeTopBar.backKey), findsOneWidget);
      // ...but tapping it does nothing observable and does not throw. There
      // is no GestureDetector/MouseRegion wrapper to find when onTap is null
      // (GlassPill skips it), so assert on that directly rather than relying
      // on the tap silently no-op'ing.
      expect(
        find.descendant(
          of: find.byKey(ChromeTopBar.backKey),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });

    testWidgets('shows the title when supplied', (tester) async {
      await tester.pumpWidget(
        _host(
          const ChromeTopBar(
            tier: PlayerGlassTier.full,
            title: 'Pride & Prejudice',
          ),
        ),
      );

      expect(find.byKey(ChromeTopBar.titleKey), findsOneWidget);
      expect(find.text('Pride & Prejudice'), findsOneWidget);
    });

    testWidgets('omits the title pill when no title is supplied',
        (tester) async {
      await tester.pumpWidget(
        _host(const ChromeTopBar(tier: PlayerGlassTier.full)),
      );
      expect(find.byKey(ChromeTopBar.titleKey), findsNothing);
    });

    testWidgets('omits the cast pill when no action is supplied',
        (tester) async {
      await tester.pumpWidget(
        _host(const ChromeTopBar(tier: PlayerGlassTier.full)),
      );
      expect(find.byKey(ChromeTopBar.castKey), findsNothing);
    });

    testWidgets('shows the cast pill when an action is supplied',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const ChromeTopBar(
            tier: PlayerGlassTier.full,
            castAction: Icon(Icons.cast_rounded),
          ),
        ),
      );
      expect(find.byKey(ChromeTopBar.castKey), findsOneWidget);
    });

    testWidgets('the cast pill fires onCastTap across its whole surface',
        (tester) async {
      // The tap target has to be the pill, not the glyph. An 18px icon in a
      // 36px pill leaves most of the affordance dead to touch, so this taps
      // the pill itself rather than the icon inside it.
      var casted = false;
      await tester.pumpWidget(
        _host(
          ChromeTopBar(
            tier: PlayerGlassTier.full,
            castAction: const Icon(Icons.cast_rounded),
            onCastTap: () => casted = true,
          ),
        ),
      );

      await tester.tap(find.byKey(ChromeTopBar.castKey));
      expect(casted, isTrue);
    });

    testWidgets('the cast pill is inert when onCastTap is null, like back',
        (tester) async {
      await tester.pumpWidget(
        _host(
          const ChromeTopBar(
            tier: PlayerGlassTier.full,
            castAction: Icon(Icons.cast_rounded),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byKey(ChromeTopBar.castKey),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });

    testWidgets(
        'title carries a small targeted shadow — measured (see '
        'pill_legibility_test.dart) to be load-bearing at this pill height, '
        'not a stylistic flourish', (tester) async {
      await tester.pumpWidget(
        _host(
          const ChromeTopBar(
            tier: PlayerGlassTier.full,
            title: 'Silo',
          ),
        ),
      );

      final text = tester.widget<Text>(find.text('Silo'));
      final shadows = text.style?.shadows;
      expect(shadows, isNotNull);
      expect(shadows, isNotEmpty);
    });

    testWidgets('truncates a long title to one line', (tester) async {
      await tester.pumpWidget(
        _host(
          const ChromeTopBar(
            tier: PlayerGlassTier.full,
            title: 'An Extremely Long Episode Title That Cannot Possibly Fit '
                'Inside The Available Horizontal Space Without Truncation',
          ),
        ),
      );

      final text = tester.widget<Text>(find.textContaining('Extremely'));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);

      // Real geometry, not just the property assertion above: the title
      // pill must not overflow the row nor push the other pills off-screen.
      final rowWidth = tester.getSize(find.byType(ChromeTopBar)).width;
      final titleRect = tester.getRect(find.byKey(ChromeTopBar.titleKey));
      expect(titleRect.left, greaterThanOrEqualTo(0));
      expect(titleRect.right, lessThanOrEqualTo(rowWidth + 0.5));
    });

    testWidgets(
        'the title pill is centered on the row when a cast action is '
        'present (symmetric flanks)', (tester) async {
      await tester.pumpWidget(
        _host(
          ChromeTopBar(
            tier: PlayerGlassTier.full,
            onBack: () {},
            title: 'Silo',
            castAction: const Icon(Icons.cast_rounded),
          ),
        ),
      );

      final rowRect = tester.getRect(find.byType(ChromeTopBar));
      final titleRect = tester.getRect(find.byKey(ChromeTopBar.titleKey));
      expect(
        titleRect.center.dx,
        closeTo(rowRect.center.dx, 1.0),
      );
    });

    testWidgets(
        'the title pill stays centered on the row even when there is no '
        'cast action (asymmetric content, symmetric flex allocation)',
        (tester) async {
      await tester.pumpWidget(
        _host(
          ChromeTopBar(
            tier: PlayerGlassTier.full,
            onBack: () {},
            title: 'Silo',
          ),
        ),
      );

      final rowRect = tester.getRect(find.byType(ChromeTopBar));
      final titleRect = tester.getRect(find.byKey(ChromeTopBar.titleKey));
      expect(
        titleRect.center.dx,
        closeTo(rowRect.center.dx, 1.0),
      );
    });

    testWidgets('stays sane with no title, no onBack, no castAction',
        (tester) async {
      await tester.pumpWidget(
        _host(const ChromeTopBar(tier: PlayerGlassTier.full)),
      );

      expect(find.byKey(ChromeTopBar.backKey), findsOneWidget);
      expect(find.byKey(ChromeTopBar.titleKey), findsNothing);
      expect(find.byKey(ChromeTopBar.castKey), findsNothing);
      // Still renders without throwing and the back pill keeps its height.
      expect(
        tester.getSize(find.byKey(ChromeTopBar.backKey)).height,
        GlassPill.defaultHeight,
      );
    });

    testWidgets(
        'all three pills are the same height even though their content '
        'differs (icon+label, text, icon-only)', (tester) async {
      await tester.pumpWidget(
        _host(
          ChromeTopBar(
            tier: PlayerGlassTier.full,
            onBack: () {},
            title: 'Silo',
            castAction: const Icon(Icons.cast_rounded),
          ),
        ),
      );

      final backHeight =
          tester.getSize(find.byKey(ChromeTopBar.backKey)).height;
      final titleHeight =
          tester.getSize(find.byKey(ChromeTopBar.titleKey)).height;
      final castHeight =
          tester.getSize(find.byKey(ChromeTopBar.castKey)).height;

      expect(backHeight, GlassPill.defaultHeight);
      expect(titleHeight, GlassPill.defaultHeight);
      expect(castHeight, GlassPill.defaultHeight);
    });
  });

  group('GlassPill', () {
    testWidgets('is 36px tall', (tester) async {
      await tester.pumpWidget(
        _host(
          const Align(
            alignment: Alignment.topLeft,
            child: GlassPill(
              tier: PlayerGlassTier.full,
              child: Text('Back'),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byType(GlassPill)).height, 36);
    });

    testWidgets('fires onTap when supplied', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          Align(
            alignment: Alignment.topLeft,
            child: GlassPill(
              tier: PlayerGlassTier.full,
              onTap: () => tapped = true,
              child: const Text('Tap me'),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(GlassPill));
      expect(tapped, isTrue);
    });
  });

  group('GlassPill height', () {
    testWidgets('defaults to defaultHeight', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: GlassPill(
                key: Key('default-pill'),
                tier: PlayerGlassTier.faux,
                child: Text('Back'),
              ),
            ),
          ),
        ),
      );

      expect(
        tester.getSize(find.byKey(const Key('default-pill'))).height,
        GlassPill.defaultHeight,
      );
    });

    testWidgets('honors an explicit height', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: GlassPill(
                key: Key('tall-pill'),
                tier: PlayerGlassTier.faux,
                height: 44,
                child: Text('Next up'),
              ),
            ),
          ),
        ),
      );

      expect(
        tester.getSize(find.byKey(const Key('tall-pill'))).height,
        44.0,
      );
    });
  });
}
