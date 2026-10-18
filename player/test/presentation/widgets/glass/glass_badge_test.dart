import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/presentation/widgets/glass/glass_badge.dart';
import 'package:player/presentation/widgets/glass/glass_interaction.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

Widget _host() => const MaterialApp(
      home: Scaffold(
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
  tearDown(() => LiquidGlassSupport.debugPlatformOverride = null);

  testWidgets('on iOS and macOS it is a glass capsule with no press',
      (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    await tester.pumpWidget(_host());
    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(GlassInteraction), findsNothing);
    expect(find.text('S1 · E3'), findsOneWidget);
  });

  testWidgets('elsewhere it paints the fallback decoration', (tester) async {
    LiquidGlassSupport.debugPlatformOverride = false;
    await tester.pumpWidget(_host());
    expect(find.byType(GlassSurface), findsNothing);
    final box = tester.widget<DecoratedBox>(find
        .ancestor(of: find.text('S1 · E3'), matching: find.byType(DecoratedBox))
        .first);
    expect(box.decoration, const BoxDecoration(color: Color(0xFF222222)));
  });
}
