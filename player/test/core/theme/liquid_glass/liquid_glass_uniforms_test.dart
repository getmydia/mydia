import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_profile.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_uniforms.dart';

void main() {
  test('packs uniforms in shader order, scaled to physical pixels', () {
    const tint = Color(0x80102030);
    const p = LiquidGlassProfile.lens;
    const u = LiquidGlassUniforms(
      devicePixelRatio: 2,
      radius: 20,
      tint: tint,
      light: Offset(0.5, 1),
      specularBoost: 0.1,
    );
    final band = LiquidGlassUniforms.edgeBandFor(p, 20, const Size(100, 40));
    expect(band, p.depth * 20);
    expect(u.toFloats(const Size(100, 40)).sublist(0, 16), [
      200, 80, // uSurface
      40, // uRadius
      band * 2, // uEdge
      p.distortion * band * 2, // uRefraction
      p.dispersion,
      p.saturation,
      p.brightness,
      p.specular + 0.1,
      p.rimWidth * 2,
      0.5, 1, // uLight
      tint.r, tint.g, tint.b, tint.a,
    ]);
  });

  test('edge band is capped at half the short side', () {
    expect(
      LiquidGlassUniforms.edgeBandFor(
          LiquidGlassProfile.panel, 1000, const Size(300, 40)),
      20,
    );
  });

  test('appends the kit lighting terms after the existing uniforms', () {
    const p = LiquidGlassProfile.panel;
    const u = LiquidGlassUniforms(
        devicePixelRatio: 1, radius: 34, tint: Color(0x80000000), profile: p);
    final floats = u.toFloats(const Size(300, 200));
    expect(floats.sublist(25), [
      p.sideLight,
      p.volumeSide,
      p.volumeEnds,
      p.lumaTarget,
      p.lumaMix,
    ]);
  });

  test('appends glow, adaptive, press and rim uniforms after the tint', () {
    const tint = Color(0x80102030);
    const p = LiquidGlassProfile.lens;
    const u = LiquidGlassUniforms(
      devicePixelRatio: 2,
      radius: 20,
      tint: tint,
      adaptiveMax: 0.7,
      glow: 0.3,
    );
    final floats = u.toFloats(const Size(100, 40));
    expect(floats, hasLength(30));
    expect(floats.sublist(16, 25), [
      p.innerGlow,
      0.7,
      DepthTokens.liquidAdaptiveLumaLow,
      DepthTokens.liquidAdaptiveLumaHigh,
      0.3,
      DepthTokens.liquidPressGlowRadius,
      DepthTokens.liquidAdaptiveRadius * 2, // uAdaptRadius
      p.rimHairline,
      p.bottomLight,
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

  test('the panel profile refracts but is not interactive', () {
    const p = LiquidGlassProfile.panel;
    const u = LiquidGlassUniforms(
      devicePixelRatio: 2,
      radius: 20,
      tint: Color(0x80102030),
      profile: p,
    );
    final f = u.toFloats(const Size(100, 40));
    expect(f, hasLength(30));
    expect(p.distortion, greaterThan(0));
    expect(p.interactive, isFalse);
    expect(f[4], greaterThan(0)); // uRefraction
    expect(f[6], p.saturation);
    expect(f[7], p.brightness);
    expect(f[8], p.specular);
    expect(f[16], p.innerGlow);
    expect(f[23], p.rimHairline);
    expect(f[24], p.bottomLight);
  });

  test('the lens keeps the frosted pre-kit material', () {
    const p = LiquidGlassProfile.lens;
    // Frosted, not clear: the kit's blur 3 let backdrop text show through.
    expect(p.blurSigma, 20);
    // Lit at the top and bottom only: lit sides drew a white outline.
    expect(p.sideLight, 0);
    expect(p.rimHairline, 0.12);
    expect(p.volumeSide, 0);
    expect(p.volumeEnds, 0);
  });

  test('the lens profile is the default', () {
    const u = LiquidGlassUniforms(
        devicePixelRatio: 1, radius: 8, tint: Color(0xFF000000));
    expect(u.profile, same(LiquidGlassProfile.lens));
  });

  test('equality covers the profile', () {
    const lens = LiquidGlassUniforms(
        devicePixelRatio: 2, radius: 8, tint: Color(0xFF000000));
    const panel = LiquidGlassUniforms(
        devicePixelRatio: 2,
        radius: 8,
        tint: Color(0xFF000000),
        profile: LiquidGlassProfile.panel);
    expect(lens, isNot(panel));
    expect(lens.hashCode, isNot(panel.hashCode));
  });
}
