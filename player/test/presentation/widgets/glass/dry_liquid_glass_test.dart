import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_profile.dart';
import 'package:player/presentation/widgets/glass/dry_liquid_glass.dart';
import 'package:player/presentation/widgets/glass/glass_pointer.dart';

final _tint = DepthTokens.osdTint.withValues(
  alpha: DepthTokens.osdDryTintOpacity,
);
const _radius = BorderRadius.all(Radius.circular(18));

Widget _host(Widget child) => MaterialApp(home: Center(child: child));

Widget _glass({
  LiquidGlassProfile profile = LiquidGlassProfile.lens,
  bool increaseContrast = false,
  Color? tint,
}) => DryLiquidGlass(
  borderRadius: _radius,
  tint: tint ?? _tint,
  profile: profile,
  increaseContrast: increaseContrast,
  child: const SizedBox(width: 80, height: 40),
);

DryGlassPainter _painter(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(DryLiquidGlass),
      matching: find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is DryGlassPainter,
      ),
    ),
  );
  return paint.painter! as DryGlassPainter;
}

void main() {
  testWidgets('pushes no backdrop layer', (tester) async {
    await tester.pumpWidget(_host(_glass()));
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('paints the passed tint', (tester) async {
    await tester.pumpWidget(_host(_glass(tint: const Color(0x99123456))));
    expect(_painter(tester).tint, const Color(0x99123456));
  });

  testWidgets('the catch light peaks at the OSD token, not the profile', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_glass()));
    expect(_painter(tester).catchLightAlpha, DepthTokens.osdDryCatchLightAlpha);
  });

  testWidgets('clips to the border radius', (tester) async {
    await tester.pumpWidget(_host(_glass()));
    final clip = tester.widget<ClipRRect>(
      find.descendant(
        of: find.byType(DryLiquidGlass),
        matching: find.byType(ClipRRect),
      ),
    );
    expect(clip.borderRadius, _radius);
  });

  testWidgets('increase contrast boosts the tint and shows the rim', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_glass()));
    expect(_painter(tester).rimAlpha, LiquidGlassProfile.lens.rimHairline);

    await tester.pumpWidget(_host(_glass(increaseContrast: true)));
    // The tint carries its opacity in alpha, as for LiquidGlassFilter.
    final p = _painter(tester);
    expect(
      p.tint.a,
      closeTo(
        (DepthTokens.osdDryTintOpacity +
                DepthTokens.liquidHighContrastTintBoost)
            .clamp(0.0, 1.0),
        1e-3,
      ),
    );
    expect(p.rimAlpha, DepthTokens.liquidHighContrastRimAlpha);
  });

  testWidgets('press glow follows the pointer on an interactive profile', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        GlassPointer(
          pressed: true,
          light: const Offset(0.3, 0.6),
          child: _glass(),
        ),
      ),
    );
    final p = _painter(tester);
    expect(p.glow, DepthTokens.osdDryPressGlow);
    expect(p.light, const Offset(0.3, 0.6));
  });

  testWidgets('a panel is not pressable: no glow', (tester) async {
    await tester.pumpWidget(
      _host(
        GlassPointer(
          pressed: true,
          child: _glass(profile: LiquidGlassProfile.panel),
        ),
      ),
    );
    expect(_painter(tester).glow, 0.0);
  });

  testWidgets('no glow when not pressed', (tester) async {
    await tester.pumpWidget(_host(_glass()));
    expect(_painter(tester).glow, 0.0);
  });
}
