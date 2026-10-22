import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../core/theme/liquid_glass/liquid_geometry.dart';

/// Holds a glass control at its kit [height] inside a tappable area of at
/// least 44 pt, keeping the width constraints as they were. A tap in the
/// margin above or below the glass fires [onTap] too.
/// The inner control owns the semantics, so the margin adds none.
class GlassHitTarget extends StatelessWidget {
  const GlassHitTarget({
    super.key,
    required this.height,
    required this.onTap,
    required this.child,
  });

  /// The glass's own height.
  final double height;

  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final target = _HeldHeight(height: height, child: child);
    if (onTap == null) return target;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: onTap,
      child: target,
    );
  }
}

/// Lays the glass out at exactly [height] with the parent's width
/// constraints, centered in an area at least [LiquidGeometry.minHitTarget]
/// tall. A render object rather than a LayoutBuilder so intrinsic sizing
/// (IntrinsicWidth in dialogs) keeps working.
class _HeldHeight extends SingleChildRenderObjectWidget {
  const _HeldHeight({required this.height, required super.child});

  final double height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeldHeight(height);

  @override
  void updateRenderObject(
      BuildContext context, _RenderHeldHeight renderObject) {
    renderObject.height = height;
  }
}

class _RenderHeldHeight extends RenderShiftedBox {
  _RenderHeldHeight(this._height) : super(null);

  double _height;
  set height(double value) {
    if (_height == value) return;
    _height = value;
    markNeedsLayout();
  }

  double get _areaHeight => math.max(_height, LiquidGeometry.minHitTarget);

  BoxConstraints _childConstraints(BoxConstraints c) =>
      c.copyWith(minHeight: _height, maxHeight: _height);

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(_height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(_height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) => _areaHeight;

  @override
  double computeMaxIntrinsicHeight(double width) => _areaHeight;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final childSize =
        child?.getDryLayout(_childConstraints(constraints)) ?? Size.zero;
    return constraints.constrain(Size(childSize.width, _areaHeight));
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.constrain(Size(0, _areaHeight));
      return;
    }
    child.layout(_childConstraints(constraints), parentUsesSize: true);
    size = constraints.constrain(Size(child.size.width, _areaHeight));
    (child.parentData! as BoxParentData).offset =
        Offset(0, (size.height - child.size.height) / 2);
  }
}
