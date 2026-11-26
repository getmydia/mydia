import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_profile.dart';
import 'package:player/presentation/widgets/glass/glass_pointer.dart';

/// Liquid Glass without a backdrop pass: for surfaces whose backdrop cannot be
/// sampled, such as the macOS native video surface. It paints a fixed tint,
/// the rim, the top and bottom catch light and the press glow from the same
/// [LiquidGlassProfile] as `LiquidGlassFilter`. No blur, no bend, no adaptive
/// tint.
///
/// The shadow is not painted here: `GlassSurface` owns it.
class DryLiquidGlass extends StatelessWidget {
  const DryLiquidGlass({
    super.key,
    required this.borderRadius,
    required this.tint,
    required this.profile,
    this.increaseContrast = false,
    this.child,
  });

  final BorderRadius borderRadius;

  /// Tint colour with its opacity in alpha (`DepthTokens.osdDryTintOpacity`
  /// for the OSD).
  final Color tint;
  final LiquidGlassProfile profile;

  /// Adds `liquidHighContrastTintBoost` to the tint and draws the visible rim.
  final bool increaseContrast;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    // A panel is not pressable: no press glow.
    final pointer = profile.interactive ? GlassPointer.maybeOf(context) : null;
    final pressed = pointer?.pressed == true;
    return ClipRRect(
      borderRadius: borderRadius,
      child: CustomPaint(
        painter: DryGlassPainter(
          borderRadius: borderRadius,
          tint: increaseContrast
              ? tint.withValues(
                  alpha: (tint.a + DepthTokens.liquidHighContrastTintBoost)
                      .clamp(0.0, 1.0),
                )
              : tint,
          profile: profile,
          rimAlpha: increaseContrast
              ? DepthTokens.liquidHighContrastRimAlpha
              : profile.rimHairline,
          glow: pressed ? DepthTokens.liquidPressGlow : 0.0,
          light: pointer?.light ?? DepthTokens.liquidLightRest,
        ),
        child: child,
      ),
    );
  }
}

/// Paints the dry glass layers. Public so tests can read its inputs.
class DryGlassPainter extends CustomPainter {
  const DryGlassPainter({
    required this.borderRadius,
    required this.tint,
    required this.profile,
    required this.rimAlpha,
    required this.glow,
    required this.light,
  });

  final BorderRadius borderRadius;
  final Color tint;
  final LiquidGlassProfile profile;

  /// White alpha of the rim stroke.
  final double rimAlpha;

  /// Press glow alpha, 0 when not pressed.
  final double glow;

  /// Glow centre as a fraction of the surface.
  final Offset light;

  /// Peak alpha of the catch light.
  double get catchLightAlpha => DepthTokens.osdDryCatchLightAlpha;

  /// Fraction of the height each catch light fades over.
  @visibleForTesting
  static const double catchLightFraction = 0.3;

  /// How much white the rim gains at the top and bottom, scaled by the
  /// profile's specular.
  @visibleForTesting
  static const double rimLitBoost = 0.25;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = borderRadius.toRRect(rect);

    canvas.drawRRect(rrect, Paint()..color = tint);

    // Top and bottom catch light, fading over 30% of the height from each end.
    final catchLight = const Color(0xFFFFFFFF)
        .withValues(alpha: catchLightAlpha);
    final clear = catchLight.withValues(alpha: 0);
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [catchLight, clear, clear, catchLight],
          stops: const [0, catchLightFraction, 1 - catchLightFraction, 1],
        ).createShader(rect),
    );

    if (glow > 0) {
      final center = Offset(light.dx * size.width, light.dy * size.height);
      final radius =
          DepthTokens.liquidPressGlowRadius * math.min(size.width, size.height);
      final white = const Color(0xFFFFFFFF);
      canvas.drawRRect(
        rrect,
        Paint()
          ..shader = RadialGradient(
            colors: [
              white.withValues(alpha: glow),
              white.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    // Rim, inset by half its width so the stroke stays inside the clip. Lit at
    // the top and bottom like the shader's specular rim, and a faint hairline
    // between. The lit ends sit at the edge of the glass, under no content.
    final half = profile.rimWidth / 2;
    final base = const Color(0xFFFFFFFF).withValues(alpha: rimAlpha);
    final lit = const Color(0xFFFFFFFF).withValues(
      alpha: (rimAlpha + rimLitBoost * profile.specular).clamp(0.0, 1.0),
    );
    canvas.drawRRect(
      rrect.deflate(half),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = profile.rimWidth
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [lit, base, base, lit],
          stops: const [0, catchLightFraction, 1 - catchLightFraction, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(DryGlassPainter old) =>
      old.borderRadius != borderRadius ||
      old.tint != tint ||
      old.profile != profile ||
      old.rimAlpha != rimAlpha ||
      old.glow != glow ||
      old.light != light;
}
