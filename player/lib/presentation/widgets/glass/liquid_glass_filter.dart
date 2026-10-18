import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../../core/theme/depth_tokens.dart';
import '../../../core/theme/liquid_glass/liquid_glass_support.dart';
import '../../../core/theme/liquid_glass/liquid_glass_uniforms.dart';
import 'glass_pointer.dart';

/// The Liquid Glass backdrop: bends, frosts and lights what is behind
/// [child]. Must sit inside a clip shaped like the surface (`GlassSurface`
/// puts it in a `ClipRRect`), or the backdrop pass covers the screen.
///
/// Without a loaded shader (tests, or a load failure) it pushes the blur
/// alone, so the structure is the same on every path.
class LiquidGlassFilter extends SingleChildRenderObjectWidget {
  const LiquidGlassFilter({
    super.key,
    required this.radius,
    required this.tint,
    this.grouped = false,
    super.child,
  });

  /// Corner radius, logical pixels.
  final double radius;

  /// Tint colour with its opacity in alpha.
  final Color tint;

  /// Share one backdrop pass with the enclosing `BackdropGroup`.
  final bool grouped;

  LiquidGlassUniforms _uniforms(BuildContext context) {
    final pointer = GlassPointer.maybeOf(context);
    final boost = switch (pointer) {
      GlassPointer(pressed: true) => DepthTokens.liquidPressSpecularBoost,
      GlassPointer(hovered: true) => DepthTokens.liquidHoverSpecularBoost,
      _ => 0.0,
    };
    return LiquidGlassUniforms(
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      radius: radius,
      tint: tint,
      light: pointer?.light ?? DepthTokens.liquidLightRest,
      specularBoost: boost,
    );
  }

  BackdropKey? _key(BuildContext context) =>
      grouped ? BackdropGroup.of(context)?.backdropKey : null;

  @override
  RenderLiquidGlass createRenderObject(BuildContext context) =>
      RenderLiquidGlass(
          uniforms: _uniforms(context), backdropKey: _key(context));

  @override
  void updateRenderObject(
      BuildContext context, RenderLiquidGlass renderObject) {
    renderObject
      ..uniforms = _uniforms(context)
      ..backdropKey = _key(context);
  }
}

class RenderLiquidGlass extends RenderProxyBox {
  RenderLiquidGlass({
    required LiquidGlassUniforms uniforms,
    BackdropKey? backdropKey,
  })  : _uniforms = uniforms,
        _backdropKey = backdropKey;

  LiquidGlassUniforms get uniforms => _uniforms;
  LiquidGlassUniforms _uniforms;
  set uniforms(LiquidGlassUniforms value) {
    if (value == _uniforms) return;
    _uniforms = value;
    markNeedsPaint();
  }

  BackdropKey? _backdropKey;
  set backdropKey(BackdropKey? value) {
    if (value == _backdropKey) return;
    _backdropKey = value;
    markNeedsPaint();
  }

  ui.FragmentShader? _shader;

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  BackdropFilterLayer? get layer => super.layer as BackdropFilterLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) {
      layer = null;
      return;
    }
    final backdrop = layer ??= BackdropFilterLayer();
    backdrop
      ..filter = _filter()
      ..backdropKey = _backdropKey;
    context.pushLayer(backdrop, super.paint, offset);
  }

  ui.ImageFilter _filter() {
    final blur = ui.ImageFilter.blur(
      sigmaX: DepthTokens.liquidBlurSigma,
      sigmaY: DepthTokens.liquidBlurSigma,
    );
    final program = LiquidGlassSupport.program;
    if (program == null) return blur;
    final shader = _shader ??= program.fragmentShader();
    _uniforms.applyTo(shader, size);
    return ui.ImageFilter.compose(
      outer: ui.ImageFilter.shader(shader),
      inner: blur,
    );
  }

  @override
  void dispose() {
    _shader?.dispose();
    _shader = null;
    super.dispose();
  }
}
