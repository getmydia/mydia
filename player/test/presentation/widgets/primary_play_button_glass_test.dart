import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/presentation/widgets/glass/glass_interaction.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/primary_play_button.dart';

Widget _host(VoidCallback? onPressed) => MaterialApp(
      home: Scaffold(
        body: Center(child: PrimaryPlayButton(onPressed: onPressed)),
      ),
    );

void main() {
  tearDown(() => LiquidGlassSupport.debugPlatformOverride = null);

  testWidgets('iOS and macOS: a white glass capsule that plays',
      (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    var taps = 0;
    await tester.pumpWidget(_host(() => taps++));
    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(GlassInteraction), findsOneWidget);
    expect(find.byKey(PrimaryPlayButton.pillKey), findsOneWidget);
    await tester.tap(find.byKey(PrimaryPlayButton.pillKey));
    expect(taps, 1);
  });

  testWidgets('disabled on iOS and macOS keeps the solid disabled pill',
      (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    await tester.pumpWidget(_host(null));
    expect(find.byType(GlassSurface), findsNothing);
  });

  testWidgets('elsewhere it is the solid white pill', (tester) async {
    LiquidGlassSupport.debugPlatformOverride = false;
    await tester.pumpWidget(_host(() {}));
    expect(find.byType(GlassSurface), findsNothing);
    final pill = tester.widget<Material>(find.byKey(PrimaryPlayButton.pillKey));
    expect(pill.color, Colors.white);
  });
}
