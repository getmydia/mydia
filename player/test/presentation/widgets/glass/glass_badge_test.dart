import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/glass_badge.dart';
import 'package:player/presentation/widgets/glass/glass_interaction.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

Widget _host({required bool liquid}) => MaterialApp(
      theme: AppTheme.build(Palettes.projectionBooth, liquid: liquid),
      home: const Scaffold(
        body: Center(
          child: GlassBadge(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            fallbackDecoration: BoxDecoration(color: Color(0xFF222222)),
            child: Text('S1 · E3'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('on Liquid Glass it is a glass capsule with no press',
      (tester) async {
    await tester.pumpWidget(_host(liquid: true));
    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(GlassInteraction), findsNothing);
    expect(find.text('S1 · E3'), findsOneWidget);
  });

  testWidgets('on Frosted it paints the fallback decoration', (tester) async {
    await tester.pumpWidget(_host(liquid: false));
    expect(find.byType(GlassSurface), findsNothing);
    final box = tester.widget<DecoratedBox>(find
        .ancestor(of: find.text('S1 · E3'), matching: find.byType(DecoratedBox))
        .first);
    expect(box.decoration, const BoxDecoration(color: Color(0xFF222222)));
  });
}
