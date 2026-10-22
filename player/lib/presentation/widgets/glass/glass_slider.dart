import 'package:flutter/material.dart';

import '../../../core/theme/depth_tokens.dart';
import '../../../core/theme/liquid_glass/glass_accessibility.dart';
import '../../../core/theme/liquid_glass/glass_style.dart';
import '../../../core/theme/liquid_glass/liquid_geometry.dart';
import '../../../core/theme/liquid_glass/liquid_glass_profile.dart';
import '../../../core/theme/liquid_glass/liquid_glass_support.dart';
import 'liquid_glass_filter.dart';

/// A slider whose knob is a clear Liquid Glass lens. Elsewhere it is the
/// plain Material [Slider], with the same arguments.
///
/// On Liquid Glass the Material slider still owns the track and every
/// gesture, with its thumb and overlay hidden. The knob is painted over it
/// and ignores pointers.
class GlassSlider extends StatefulWidget {
  const GlassSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.activeColor,
    this.inactiveColor,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final Color? activeColor;
  final Color? inactiveColor;

  @override
  State<GlassSlider> createState() => _GlassSliderState();
}

class _GlassSliderState extends State<GlassSlider> {
  static const double _knobWidth = LiquidGeometry.sliderKnobWidth;
  static const double _knobHeight = LiquidGeometry.sliderKnobHeight;
  static const double _knobRadius = _knobHeight / 2;

  bool _dragging = false;

  /// Left edge of the knob inside a slider [width] wide. The theme pads the
  /// track by half a knob each side, so the knob stays inside the bounds at
  /// both ends and travels `width - knobWidth`.
  double _knobLeft(double width) {
    final span = widget.max - widget.min;
    final t =
        span <= 0 ? 0.0 : ((widget.value - widget.min) / span).clamp(0.0, 1.0);
    return t * (width - _knobWidth);
  }

  Widget _slider(BuildContext context, {required bool glass}) {
    final slider = Slider(
      value: widget.value,
      onChanged: widget.onChanged,
      onChangeStart: glass
          ? (v) {
              setState(() => _dragging = true);
              widget.onChangeStart?.call(v);
            }
          : widget.onChangeStart,
      onChangeEnd: glass
          ? (v) {
              setState(() => _dragging = false);
              widget.onChangeEnd?.call(v);
            }
          : widget.onChangeEnd,
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      label: widget.label,
      activeColor: widget.activeColor,
      inactiveColor: widget.inactiveColor,
    );
    if (!glass) return slider;
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        thumbShape: SliderComponentShape.noThumb,
        overlayShape: SliderComponentShape.noOverlay,
        padding: const EdgeInsets.symmetric(horizontal: _knobWidth / 2),
      ),
      child: slider,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!GlassStyle.of(context)) return _slider(context, glass: false);
    final opaque = GlassAccessibilityScope.of(context).reduceTransparency;
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        alignment: Alignment.centerLeft,
        children: [
          _slider(context, glass: true),
          Positioned(
            left: _knobLeft(constraints.maxWidth),
            top: 0,
            bottom: 0,
            width: _knobWidth,
            child: IgnorePointer(
              child: Center(
                child: AnimatedScale(
                  scale: _dragging ? DepthTokens.liquidPressScale : 1.0,
                  duration: DepthTokens.liquidPressDuration,
                  curve: DepthTokens.liquidPressCurve,
                  child: _Knob(opaque: opaque),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Knob extends StatelessWidget {
  const _Knob({required this.opaque});

  /// Reduce Transparency: no lens, a flat white knob.
  final bool opaque;

  @override
  Widget build(BuildContext context) {
    const radius =
        BorderRadius.all(Radius.circular(_GlassSliderState._knobRadius));
    final filled = opaque || LiquidGlassSupport.program == null;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: LiquidGlassProfile.clear.shadow,
      ),
      child: SizedBox(
        width: _GlassSliderState._knobWidth,
        height: _GlassSliderState._knobHeight,
        child: ClipRRect(
          borderRadius: radius,
          child: opaque
              ? const _KnobFill()
              : LiquidGlassFilter(
                  radius: _GlassSliderState._knobRadius,
                  tint: const Color(0x00FFFFFF),
                  profile: LiquidGlassProfile.clear,
                  child: filled ? const _KnobFill() : null,
                ),
        ),
      ),
    );
  }
}

class _KnobFill extends StatelessWidget {
  const _KnobFill();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        key: Key('glass-slider-knob-fill'),
        decoration: BoxDecoration(color: Color.fromRGBO(255, 255, 255, 0.85)),
        child: SizedBox.expand(),
      );
}
