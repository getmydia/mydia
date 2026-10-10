import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/presentation/screens/detail/detail_sections.dart';

Future<void> _pump(WidgetTester tester, Widget child, {double width = 1000}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

void main() {
  group('DetailHeroBody', () {
    Widget body() => DetailHeroBody(
          actionColumn: (compact) =>
              Text(compact ? 'compact' : 'full', key: const Key('actions')),
          tagColumn: const Text('tags', key: Key('tags')),
        );

    testWidgets('sits side by side, compact, at or above the breakpoint',
        (tester) async {
      await _pump(tester, body(), width: kDetailHeroBreakpoint);

      expect(find.text('compact'), findsOneWidget);
      final actions = tester.getRect(find.byKey(const Key('actions')));
      final tags = tester.getRect(find.byKey(const Key('tags')));
      expect(tags.left, greaterThan(actions.right));
    });

    testWidgets('stacks, full, below the breakpoint', (tester) async {
      await _pump(tester, body(), width: kDetailHeroBreakpoint - 1);

      expect(find.text('full'), findsOneWidget);
      final actions = tester.getRect(find.byKey(const Key('actions')));
      final tags = tester.getRect(find.byKey(const Key('tags')));
      expect(tags.top, greaterThan(actions.bottom));
    });
  });

  group('DetailTagColumn', () {
    testWidgets('shows leading, tags, overview and rating', (tester) async {
      await _pump(
        tester,
        const DetailTagColumn(
          leading: Text('leading'),
          tags: ['1h 52m', '4K', 'Drama'],
          overview: 'A lighthouse keeper inherits an orchard.',
          rating: '7.9',
        ),
      );

      expect(find.text('leading'), findsOneWidget);
      expect(find.text('4K'), findsOneWidget);
      expect(find.text('A lighthouse keeper inherits an orchard.'),
          findsOneWidget);
      expect(find.text('7.9'), findsOneWidget);
      expect(find.text('TMDB'), findsOneWidget);
    });

    testWidgets('omits empty parts', (tester) async {
      await _pump(tester, const DetailTagColumn(tags: []));

      expect(find.byType(Wrap), findsNothing);
      expect(find.text('TMDB'), findsNothing);
    });
  });

  group('DetailMetadataChip', () {
    testWidgets('uses the unified chip values', (tester) async {
      await _pump(
        tester,
        const DetailMetadataChip(label: 'Ended'),
      );

      final box = tester.widget<Container>(find.byType(Container));
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.color, AppColors.textSecondary.withValues(alpha: 0.15));
      expect(
          box.padding, const EdgeInsets.symmetric(horizontal: 12, vertical: 6));
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('shows an icon in the chip colour', (tester) async {
      await _pump(
        tester,
        const DetailMetadataChip(
          label: 'Watched',
          icon: Icons.check_circle_rounded,
          color: AppColors.success,
        ),
      );

      final icon = tester.widget<Icon>(find.byIcon(Icons.check_circle_rounded));
      expect(icon.color, AppColors.success);
      expect(icon.size, 16);
    });
  });

  group('DetailMetadataWrap', () {
    testWidgets('renders nothing without chips', (tester) async {
      await _pump(tester, const DetailMetadataWrap(chips: []));

      expect(find.byType(Wrap), findsNothing);
    });

    testWidgets('spaces chips by 8', (tester) async {
      await _pump(
        tester,
        const DetailMetadataWrap(chips: [Text('a'), Text('b')]),
      );

      final wrap = tester.widget<Wrap>(find.byType(Wrap));
      expect(wrap.spacing, 8);
      expect(wrap.runSpacing, 8);
    });
  });

  testWidgets('DetailOverview shows the heading and text', (tester) async {
    await _pump(
      tester,
      const DetailOverview(overview: 'Rain on the tin roofs.'),
    );

    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Rain on the tin roofs.'), findsOneWidget);
  });
}
