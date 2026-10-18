import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/presentation/widgets/glass/glass_button.dart';
import 'package:player/presentation/widgets/glass/glass_interaction.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

const _key = Key('glass-button-under-test');

Widget _host(VoidCallback? onPressed) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: GlassButton(
            label: 'All episodes',
            onPressed: onPressed,
            buttonKey: _key,
          ),
        ),
      ),
    );

void main() {
  tearDown(() => LiquidGlassSupport.debugPlatformOverride = null);

  testWidgets('on iOS and macOS it is a glass capsule that taps by key',
      (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    var taps = 0;
    await tester.pumpWidget(_host(() => taps++));
    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(GlassInteraction), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.text('All episodes'), findsOneWidget);
    await tester.tap(find.byKey(_key));
    expect(taps, 1);
    expect(tester.getSize(find.byType(GlassSurface)).height, 48);
  });

  testWidgets('elsewhere it is the OutlinedButton, keyed', (tester) async {
    LiquidGlassSupport.debugPlatformOverride = false;
    var taps = 0;
    await tester.pumpWidget(_host(() => taps++));
    expect(find.byType(GlassSurface), findsNothing);
    expect(find.byType(OutlinedButton), findsOneWidget);
    await tester.tap(find.byKey(_key));
    expect(taps, 1);
  });

  testWidgets('a null onPressed disables the glass press', (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    await tester.pumpWidget(_host(null));
    final interaction =
        tester.widget<GlassInteraction>(find.byType(GlassInteraction));
    expect(interaction.enabled, isFalse);
  });
}
