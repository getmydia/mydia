import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/presentation/widgets/glass/glass_icon_button.dart';
import 'package:player/presentation/widgets/glass/glass_interaction.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

Widget _host(VoidCallback onPressed) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: GlassIconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Back',
            onPressed: onPressed,
          ),
        ),
      ),
    );

void main() {
  tearDown(() => LiquidGlassSupport.debugPlatformOverride = null);

  testWidgets('on iOS and macOS it is a glass circle that still taps',
      (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    var taps = 0;
    await tester.pumpWidget(_host(() => taps++));
    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(GlassInteraction), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    await tester.tap(find.byType(GlassIconButton));
    expect(taps, 1);
  });

  testWidgets('elsewhere it is the plain IconButton', (tester) async {
    LiquidGlassSupport.debugPlatformOverride = false;
    await tester.pumpWidget(_host(() {}));
    expect(find.byType(GlassSurface), findsNothing);
    expect(find.byType(IconButton), findsOneWidget);
  });
}
