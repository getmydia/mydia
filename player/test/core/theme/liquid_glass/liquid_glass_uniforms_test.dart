import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_uniforms.dart';

void main() {
  test('packs uniforms in shader order, scaled to physical pixels', () {
    const tint = Color(0x80102030);
    const u = LiquidGlassUniforms(
      devicePixelRatio: 2,
      radius: 20,
      tint: tint,
      light: Offset(0.5, 1),
      specularBoost: 0.1,
    );
    expect(u.toFloats(const Size(100, 40)).sublist(0, 16), [
      200, 80, // uSurface
      40, // uRadius
      DepthTokens.liquidEdgeBand * 2,
      DepthTokens.liquidRefraction * 2,
      DepthTokens.liquidDispersion,
      DepthTokens.liquidSaturation,
      DepthTokens.liquidBrightness,
      DepthTokens.liquidSpecular + 0.1,
      DepthTokens.liquidRimWidth * 2,
      0.5, 1, // uLight
      tint.r, tint.g, tint.b, tint.a,
    ]);
  });

  test('appends glow, adaptive, press and rim uniforms after the tint', () {
    const tint = Color(0x80102030);
    const u = LiquidGlassUniforms(
      devicePixelRatio: 2,
      radius: 20,
      tint: tint,
      adaptiveMax: 0.7,
      glow: 0.3,
    );
    final floats = u.toFloats(const Size(100, 40));
    expect(floats, hasLength(25));
    expect(floats.sublist(16), [
      DepthTokens.liquidInnerGlow,
      0.7,
      DepthTokens.liquidAdaptiveLumaLow,
      DepthTokens.liquidAdaptiveLumaHigh,
      0.3,
      DepthTokens.liquidPressGlowRadius,
      DepthTokens.liquidAdaptiveRadius * 2, // uAdaptRadius
      DepthTokens.liquidRimHairline,
      DepthTokens.liquidBottomLight,
    ]);
  });

  test('a null adaptiveMax keeps the tint alpha fixed', () {
    const tint = Color(0x80102030);
    const u = LiquidGlassUniforms(devicePixelRatio: 1, radius: 8, tint: tint);
    final floats = u.toFloats(const Size(10, 10));
    expect(floats[17], tint.a);
    expect(floats[20], 0);
  });

  test('equality covers adaptiveMax and glow', () {
    const base = LiquidGlassUniforms(
        devicePixelRatio: 2, radius: 8, tint: Color(0xFF000000));
    const same = LiquidGlassUniforms(
        devicePixelRatio: 2, radius: 8, tint: Color(0xFF000000));
    const adapt = LiquidGlassUniforms(
        devicePixelRatio: 2,
        radius: 8,
        tint: Color(0xFF000000),
        adaptiveMax: 0.5);
    const glow = LiquidGlassUniforms(
        devicePixelRatio: 2, radius: 8, tint: Color(0xFF000000), glow: 0.2);
    expect(base, same);
    expect(base.hashCode, same.hashCode);
    expect(base, isNot(adapt));
    expect(base, isNot(glow));
    expect(adapt.hashCode, isNot(base.hashCode));
    expect(glow.hashCode, isNot(base.hashCode));
  });

  test('writes after the engine-owned uSize', () {
    expect(LiquidGlassUniforms.firstIndex, 2);
  });

  test('value equality drives repaint decisions', () {
    const a = LiquidGlassUniforms(
        devicePixelRatio: 2, radius: 8, tint: Color(0xFF000000));
    const b = LiquidGlassUniforms(
        devicePixelRatio: 2, radius: 8, tint: Color(0xFF000000));
    const c = LiquidGlassUniforms(
        devicePixelRatio: 3, radius: 8, tint: Color(0xFF000000));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(c));
  });
}
