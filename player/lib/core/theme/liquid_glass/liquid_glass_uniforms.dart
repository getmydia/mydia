import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../depth_tokens.dart';

/// The Liquid Glass shader's uniforms for one surface, in the order
/// `shaders/liquid_glass.frag` declares them after `uSize`.
@immutable
class LiquidGlassUniforms {
  const LiquidGlassUniforms({
    required this.devicePixelRatio,
    required this.radius,
    required this.tint,
    this.light = DepthTokens.liquidLightRest,
    this.specularBoost = 0,
    this.adaptiveMax,
    this.glow = 0,
  });

  /// `uSize` (floats 0 and 1) is set by the engine for `ImageFilter.shader`.
  static const int firstIndex = 2;

  final double devicePixelRatio;

  /// Corner radius, logical pixels.
  final double radius;

  /// Tint colour with its opacity in alpha.
  final Color tint;

  /// Light position as a fraction of the surface.
  final Offset light;

  /// Added to [DepthTokens.liquidSpecular] (hover, press).
  final double specularBoost;

  /// Tint alpha over a bright backdrop; null keeps the tint fixed.
  final double? adaptiveMax;

  /// Press glow under the light position.
  final double glow;

  List<double> toFloats(Size size) {
    final dpr = devicePixelRatio;
    return <double>[
      size.width * dpr,
      size.height * dpr,
      radius * dpr,
      DepthTokens.liquidEdgeBand * dpr,
      DepthTokens.liquidRefraction * dpr,
      DepthTokens.liquidDispersion,
      DepthTokens.liquidSaturation,
      DepthTokens.liquidBrightness,
      DepthTokens.liquidSpecular + specularBoost,
      DepthTokens.liquidEdgeShade,
      DepthTokens.liquidRimWidth * dpr,
      light.dx,
      light.dy,
      tint.r,
      tint.g,
      tint.b,
      tint.a,
      DepthTokens.liquidEdgeShadeWidth * dpr,
      DepthTokens.liquidInnerGlow,
      adaptiveMax ?? tint.a,
      DepthTokens.liquidAdaptiveLumaLow,
      DepthTokens.liquidAdaptiveLumaHigh,
      glow,
      DepthTokens.liquidPressGlowRadius,
    ];
  }

  void applyTo(ui.FragmentShader shader, Size size) {
    final floats = toFloats(size);
    for (var i = 0; i < floats.length; i++) {
      shader.setFloat(firstIndex + i, floats[i]);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LiquidGlassUniforms &&
      other.devicePixelRatio == devicePixelRatio &&
      other.radius == radius &&
      other.tint == tint &&
      other.light == light &&
      other.specularBoost == specularBoost &&
      other.adaptiveMax == adaptiveMax &&
      other.glow == glow;

  @override
  int get hashCode => Object.hash(
        devicePixelRatio,
        radius,
        tint,
        light,
        specularBoost,
        adaptiveMax,
        glow,
      );
}
