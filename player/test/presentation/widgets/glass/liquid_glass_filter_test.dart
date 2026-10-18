import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
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
}
