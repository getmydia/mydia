import 'package:flutter/material.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_profile.dart';
import 'package:player/presentation/widgets/glass/liquid_glass_filter.dart';

/// A Liquid Glass sample: [LiquidGlassFilter] clipped to [radius], tinted
/// with [base] at [opacity].
Widget labGlass(
  double radius,
  Color base,
  double opacity, {
  double? adaptiveMax,
  LiquidGlassProfile profile = LiquidGlassProfile.lens,
  Widget child = const SizedBox.expand(),
}) =>
    ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: LiquidGlassFilter(
        radius: radius,
        tint: base.withValues(alpha: opacity),
        adaptiveTintMax: adaptiveMax,
        profile: profile,
        child: child,
      ),
    );

/// An icon and a white label, centred, as on the Play button.
Widget labLabel(IconData icon, String text, {double fontSize = 16}) => Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: Colors.white, size: 22),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: fontSize,
          ),
        ),
      ],
    );

/// A small caption naming a sample.
Widget labTag({
  required double top,
  required double left,
  required String text,
}) =>
    Positioned(
      top: top,
      left: left,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        color: Colors.black.withValues(alpha: 0.6),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 10),
        ),
      ),
    );
