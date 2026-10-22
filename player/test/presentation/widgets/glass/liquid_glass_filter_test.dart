import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_profile.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/presentation/widgets/glass/glass_pointer.dart';
import 'package:player/presentation/widgets/glass/liquid_glass_filter.dart';

Widget _host(Widget child) => MaterialApp(home: Center(child: child));

void main() {
  testWidgets('without a shader it pushes a blur backdrop layer',
      (tester) async {
    await tester.pumpWidget(_host(const LiquidGlassFilter(
      radius: 12,
      tint: Color(0xA0000000),
      child: SizedBox(width: 80, height: 40),
    )));
    final render =
        tester.renderObject<RenderLiquidGlass>(find.byType(LiquidGlassFilter));
    final layer = render.debugLayer;
    expect(layer, isA<BackdropFilterLayer>());
    expect(
      (layer! as BackdropFilterLayer).filter,
      ui.ImageFilter.blur(
        sigmaX: DepthTokens.liquidBlurSigma,
        sigmaY: DepthTokens.liquidBlurSigma,
      ),
    );
    // No shader program: no nested lens layer anywhere under the blur.
    var nested = false;
    for (Layer? child = layer.firstChild;
        child != null;
        child = child.nextSibling) {
      if (child is BackdropFilterLayer) nested = true;
      if (child is ContainerLayer && child.firstChild != null) {
        for (Layer? c = child.firstChild; c != null; c = c.nextSibling) {
          if (c is BackdropFilterLayer) nested = true;
        }
      }
    }
    expect(nested, isFalse);
  });

  testWidgets('hover alone gives the hover specular boost', (tester) async {
    await tester.pumpWidget(_host(const GlassPointer(
      hovered: true,
      child: LiquidGlassFilter(
        radius: 12,
        tint: Color(0xA0000000),
        child: SizedBox(width: 80, height: 40),
      ),
    )));
    final render =
        tester.renderObject<RenderLiquidGlass>(find.byType(LiquidGlassFilter));
    expect(render.uniforms.specularBoost, DepthTokens.liquidHoverSpecularBoost);
  });

  testWidgets('reads light, hover and press from GlassPointer', (tester) async {
    await tester.pumpWidget(_host(const GlassPointer(
      light: Offset(0.9, 0.1),
      pressed: true,
      child: LiquidGlassFilter(
        radius: 12,
        tint: Color(0xA0000000),
        child: SizedBox(width: 80, height: 40),
      ),
    )));
    final render =
        tester.renderObject<RenderLiquidGlass>(find.byType(LiquidGlassFilter));
    expect(render.uniforms.light, const Offset(0.9, 0.1));
    expect(render.uniforms.specularBoost, DepthTokens.liquidPressSpecularBoost);
  });

  testWidgets('passes the adaptive ceiling and a press glow', (tester) async {
    await tester.pumpWidget(_host(const GlassPointer(
      pressed: true,
      child: LiquidGlassFilter(
        radius: 12,
        tint: Color(0xA0000000),
        adaptiveTintMax: 0.7,
        child: SizedBox(width: 80, height: 40),
      ),
    )));
    final render =
        tester.renderObject<RenderLiquidGlass>(find.byType(LiquidGlassFilter));
    expect(render.uniforms.adaptiveMax, 0.7);
    expect(render.uniforms.glow, DepthTokens.liquidPressGlow);
  });

  testWidgets('has no glow and no adaptation by default', (tester) async {
    await tester.pumpWidget(_host(const LiquidGlassFilter(
      radius: 12,
      tint: Color(0xA0000000),
      child: SizedBox(width: 80, height: 40),
    )));
    final render =
        tester.renderObject<RenderLiquidGlass>(find.byType(LiquidGlassFilter));
    expect(render.uniforms.adaptiveMax, isNull);
    expect(render.uniforms.glow, 0);
  });

  testWidgets('rests at the default light with no GlassPointer',
      (tester) async {
    await tester.pumpWidget(_host(const LiquidGlassFilter(
      radius: 12,
      tint: Color(0xA0000000),
      child: SizedBox(width: 80, height: 40),
    )));
    final render =
        tester.renderObject<RenderLiquidGlass>(find.byType(LiquidGlassFilter));
    expect(render.uniforms.light, DepthTokens.liquidLightRest);
    expect(render.uniforms.specularBoost, 0);
  });

  group('inside a BackdropGroup', () {
    Widget grouped() => _host(BackdropGroup(
          child: const LiquidGlassFilter(
            radius: 12,
            tint: Color(0xA0000000),
            grouped: true,
            child: SizedBox(width: 80, height: 40),
          ),
        ));

    BackdropKey? blurKey(WidgetTester tester) => (tester
            .renderObject<RenderLiquidGlass>(find.byType(LiquidGlassFilter))
            .debugLayer! as BackdropFilterLayer)
        .backdropKey;

    tearDown(() => LiquidGlassSupport.debugProgram = null);

    testWidgets('the frosted blur still shares the group pass', (tester) async {
      await tester.pumpWidget(grouped());
      expect(blurKey(tester), isNotNull);
    });

    // A grouped blur reads the group's shared backdrop, so the lens nested in
    // it no longer gets the surface centred in its input and draws its rim
    // and highlights against the wrong bounds (washed out, pinned in place
    // while the surface scrolls). With a lens, every surface keeps its own
    // backdrop.
    testWidgets('with the lens loaded, the blur leaves the group',
        (tester) async {
      final program = await tester.runAsync(
          () => ui.FragmentProgram.fromAsset(LiquidGlassSupport.assetKey));
      LiquidGlassSupport.debugProgram = program;
      await tester.pumpWidget(grouped());
      // flutter test has no Impeller, so painting the lens itself throws.
      expect(tester.takeException(), isUnsupportedError);
      expect(blurKey(tester), isNull);
    });
  });

  testWidgets('the panel profile blurs at its own sigma', (tester) async {
    await tester.pumpWidget(_host(const LiquidGlassFilter(
      radius: 20,
      tint: Color(0xA0000000),
      profile: LiquidGlassProfile.panel,
      child: SizedBox(width: 200, height: 120),
    )));
    final render =
        tester.renderObject<RenderLiquidGlass>(find.byType(LiquidGlassFilter));
    expect(
      (render.debugLayer! as BackdropFilterLayer).filter,
      ui.ImageFilter.blur(
        sigmaX: DepthTokens.liquidPanelBlurSigma,
        sigmaY: DepthTokens.liquidPanelBlurSigma,
      ),
    );
    expect(render.uniforms.profile, same(LiquidGlassProfile.panel));
  });

  testWidgets('a panel ignores hover and press', (tester) async {
    await tester.pumpWidget(_host(const GlassPointer(
      light: Offset(0.9, 0.1),
      hovered: true,
      pressed: true,
      child: LiquidGlassFilter(
        radius: 20,
        tint: Color(0xA0000000),
        profile: LiquidGlassProfile.panel,
        child: SizedBox(width: 200, height: 120),
      ),
    )));
    final render =
        tester.renderObject<RenderLiquidGlass>(find.byType(LiquidGlassFilter));
    expect(render.uniforms.specularBoost, 0);
    expect(render.uniforms.glow, 0);
  });
}
