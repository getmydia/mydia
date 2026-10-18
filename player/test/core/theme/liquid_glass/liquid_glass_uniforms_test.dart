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
    expect(u.toFloats(const Size(100, 40)), [
      200, 80, // uSurface
      40, // uRadius
      DepthTokens.liquidEdgeBand * 2,
      DepthTokens.liquidRefraction * 2,
      DepthTokens.liquidDispersion,
      DepthTokens.liquidSaturation,
      DepthTokens.liquidBrightness,
      DepthTokens.liquidSpecular + 0.1,
      DepthTokens.liquidEdgeShade,
      DepthTokens.liquidRimWidth * 2,
      0.5, 1, // uLight
      tint.r, tint.g, tint.b, tint.a,
    ]);
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
