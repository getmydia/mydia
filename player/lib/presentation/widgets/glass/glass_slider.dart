import 'dart:math' as math;

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

  /// Track height Material falls back to when no theme sets one.
  static const double _defaultTrackHeight = 4;

  bool _dragging = false;
  bool _focused = false;

  /// Distance from the start edge to the knob's left edge in a slider
  /// [width] wide, in the slider's own text direction. The theme pads the
  /// track by half a knob each side. The rest mirrors the Material slider's
  /// thumb placement (`_calcThumbCenter`): a rounded track keeps the thumb a
  /// track radius inside each end, and a discrete one travels
  /// `trackWidth - trackHeight`.
  double _knobStart(BuildContext context, double width) {
    final span = widget.max - widget.min;
    final t =
        span <= 0 ? 0.0 : ((widget.value - widget.min) / span).clamp(0.0, 1.0);
    final theme = SliderTheme.of(context);
    final rounded =
        (theme.trackShape ?? const RoundedRectSliderTrackShape()).isRounded;
    final trackHeight = theme.trackHeight ?? _defaultTrackHeight;
    final inset = rounded ? trackHeight : 0.0;
    final trackStart = _knobWidth / 2;
    final trackWidth = width - _knobWidth;
    final discrete = (widget.divisions ?? 0) > 0;
    final position = discrete
        ? trackStart + t * (trackWidth - inset) + inset / 2
        : trackStart + t * trackWidth;
    final lo = trackStart + inset / 2;
    final hi = trackStart + trackWidth - inset / 2;
    final centre = hi < lo ? position : position.clamp(lo, hi);
    return centre - _knobWidth / 2;
  }

  Widget _slider(BuildContext context,
      {required bool glass, bool unbounded = false}) {
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
    final theme = SliderTheme.of(context);
    final themed = SliderTheme(
      data: theme.copyWith(
        thumbShape: SliderComponentShape.noThumb,
        overlayShape: SliderComponentShape.noOverlay,
        padding: const EdgeInsets.symmetric(horizontal: _knobWidth / 2),
      ),
      child: slider,
    );
    if (!unbounded) return themed;
    // Under a padded theme the Material slider sizes itself from its thumb,
    // which is hidden, and ignores a minimum height. Without a bounded height
    // it would shrink to its track and squash the knob, so give it the touch
    // height its overlay used to (never less than the knob).
    final overlay = (theme.overlayShape ?? const RoundSliderOverlayShape())
        .getPreferredSize(true, false);
    return SizedBox(
      height: math.max(overlay.height, _knobHeight),
      child: themed,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!GlassStyle.of(context)) return _slider(context, glass: false);
    final opaque = GlassAccessibilityScope.of(context).reduceTransparency;
    final ring = _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    // Focus reports from the slider below; this node never takes focus.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          alignment: AlignmentDirectional.centerStart,
          children: [
            _slider(
              context,
              glass: true,
              unbounded: !constraints.hasBoundedHeight,
            ),
            PositionedDirectional(
              start: _knobStart(context, constraints.maxWidth),
              top: 0,
              bottom: 0,
              width: _knobWidth,
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedScale(
                      scale: _dragging ? DepthTokens.liquidPressScale : 1.0,
                      duration: DepthTokens.liquidPressDuration,
                      curve: DepthTokens.liquidPressCurve,
                      child: _Knob(opaque: opaque, ring: ring),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Knob extends StatelessWidget {
  const _Knob({required this.opaque, required this.ring});

  /// Reduce Transparency: no lens, a flat white knob.
  final bool opaque;

  /// Keyboard focus: the same white ring `FocusHighlight` draws.
  final bool ring;

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
      child: DecoratedBox(
        key: ring ? const Key('glass-slider-focus-ring') : null,
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: ring
              ? Border.all(color: Colors.white.withValues(alpha: 0.6), width: 2)
              : null,
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
