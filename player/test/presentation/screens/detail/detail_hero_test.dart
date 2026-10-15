import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_colors.dart';
import 'package:player/presentation/screens/detail/detail_hero.dart';
import 'package:player/presentation/widgets/detail_art_image.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(body: SizedBox(height: 380, child: child)),
      ),
    ),
  );
}

void main() {
  group('DetailHeroBackground', () {
    testWidgets('without art and with a fallback icon, shows the icon',
        (tester) async {
      await _pump(
        tester,
        const DetailHeroBackground(
          art: null,
          slot: ArtSlot.still,
          fallbackIcon: Icons.movie_rounded,
        ),
      );

      expect(find.byIcon(Icons.movie_rounded), findsOneWidget);
    });

    testWidgets('without art or fallback icon, shows no icon', (tester) async {
      await _pump(
        tester,
        const DetailHeroBackground(art: null, slot: ArtSlot.backdrop),
      );

      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('pins the overlay and the bottom strip', (tester) async {
      await _pump(
        tester,
        const DetailHeroBackground(
          art: null,
          slot: ArtSlot.backdrop,
          overlay: Text('overlay'),
          bottom: SizedBox(key: Key('bottom'), height: 3),
        ),
      );

      final hero = tester.getRect(find.byType(DetailHeroBackground));
      final overlay = tester.getRect(find.text('overlay'));
      final bottom = tester.getRect(find.byKey(const Key('bottom')));
      expect(overlay.left, hero.left + 20);
      expect(overlay.bottom, hero.bottom - 20);
      expect(bottom.bottom, hero.bottom);
      expect(bottom.width, hero.width);
    });
  });

  group('DetailHeroBackground tint', () {
    testWidgets('the gradient ends in the ambient ground', (tester) async {
      const warm = AmbientTintColors(
        ground: Color(0xFF2A1510),
        surface: Color(0xFF2A1510),
      );
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: AmbientTint(
              colors: warm,
              child: Scaffold(
                body: SizedBox(
                  height: 380,
                  child: DetailHeroBackground(
                    art: null,
                    slot: ArtSlot.backdrop,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final gradients = tester
          .widgetList<DecoratedBox>(find.descendant(
            of: find.byType(DetailHeroBackground),
            matching: find.byType(DecoratedBox),
          ))
          .map((d) => d.decoration)
          .whereType<BoxDecoration>()
          .map((d) => d.gradient)
          .whereType<LinearGradient>();
      expect(gradients.single.colors.last, warm.ground);
    });
  });

  group('DetailHeroTitle', () {
    testWidgets('shows title, subtitle, below and action', (tester) async {
      await _pump(
        tester,
        const DetailHeroTitle(
          title: 'The Glass Orchard',
          subtitle: '2031',
          below: Text('S1 · E2'),
          action: Icon(Icons.play_arrow_rounded),
        ),
      );

      expect(find.text('The Glass Orchard'), findsOneWidget);
      expect(find.text('2031'), findsOneWidget);
      expect(find.text('S1 · E2'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('titles in Outfit', (tester) async {
      await _pump(tester, const DetailHeroTitle(title: 'The Glass Orchard'));

      final text = tester.widget<Text>(find.text('The Glass Orchard'));
      expect(text.style?.fontFamily, 'Outfit');
    });

    testWidgets('leads with the poster at the wide breakpoint', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(
        tester,
        const DetailHeroTitle(
          title: 'The Glass Orchard',
          poster: SizedBox(key: Key('poster')),
        ),
      );

      expect(tester.getSize(find.byKey(const Key('poster'))),
          const Size(160, 240));
    });

    testWidgets('drops the poster below the breakpoint', (tester) async {
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(
        tester,
        const DetailHeroTitle(
          title: 'The Glass Orchard',
          poster: SizedBox(key: Key('poster')),
        ),
      );

      expect(find.byKey(const Key('poster')), findsNothing);
    });

    testWidgets('omits an empty subtitle', (tester) async {
      await _pump(tester, const DetailHeroTitle(title: 'The Glass Orchard'));

      expect(find.byType(Text), findsOneWidget);
    });
  });
}
