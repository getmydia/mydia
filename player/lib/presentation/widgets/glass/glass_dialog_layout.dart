/// Layout for the Frosted branch of `GlassDialog`: the card body and the
/// action stack. Both measure their children by width only.
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Sizes and stacks the Frosted card's sections (icon, title, content,
/// actions), each full width.
///
/// The width is [minWidth] for ordinary content, wider (up to [maxWidth])
/// only when a section cannot be narrower, as a form or picker of fixed
/// width. Text wraps rather than
/// widening the card, because its minimum intrinsic width is its longest
/// word. Only widths are measured: a [Flex] with a flexible child would ask
/// that child for intrinsic heights, which a [LayoutBuilder] in the content
/// refuses.
///
/// Limit: the widths are still minimum intrinsic widths, so content whose
/// width comes from a [LayoutBuilder] or a viewport needs a fixed-width
/// ancestor (a `SizedBox(width: ...)`), as it did under the old
/// intrinsic-width dialog. The intrinsic heights this box reports are only
/// estimates for a parent that asks; the dialog route never does.
///
/// The [scrolling] child, the content's scroll view, takes whatever height
/// the other sections leave, so tall content scrolls and the actions stay.
/// When the other sections alone are taller than that, the body lays out
/// taller than the dialog, and the dialog scrolls it whole: put it in a
/// vertical scroll view and pass the height that view shows as
/// [viewportHeight], since the scroll view itself sets no height limit.
class FrostedDialogBody extends MultiChildRenderObjectWidget {
  const FrostedDialogBody({
    super.key,
    required this.scrolling,
    required this.minWidth,
    required this.maxWidth,
    this.viewportHeight = double.infinity,
    required super.children,
  });

  /// Index of the child that shrinks to fit, or null.
  final int? scrolling;

  /// Width of the body for ordinary content.
  final double minWidth;

  /// Widest the body grows for content that cannot be narrower.
  final double maxWidth;

  /// The height the sections share when the incoming constraints are
  /// unbounded, as inside a scroll view. Infinite when nothing bounds it.
  final double viewportHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderFrostedDialogBody(scrolling, minWidth, maxWidth, viewportHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderFrostedDialogBody renderObject,
  ) => renderObject
    ..scrolling = scrolling
    ..minWidth = minWidth
    ..maxWidth = maxWidth
    ..viewportHeight = viewportHeight;
}

class _FrostedParentData extends ContainerBoxParentData<RenderBox> {}

/// Shared child bookkeeping for the two Frosted layouts.
mixin _FrostedChildren on RenderBox
    implements
        ContainerRenderObjectMixin<RenderBox, _FrostedParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FrostedParentData> {
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FrostedParentData) {
      child.parentData = _FrostedParentData();
    }
  }

  List<RenderBox> get childList {
    final children = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      children.add(child);
      child = childAfter(child);
    }
    return children;
  }

  double widest(double Function(RenderBox child) width) =>
      childList.fold(0, (w, child) => math.max(w, width(child)));

  Size sizeChild(RenderBox child, BoxConstraints c, {required bool dry}) {
    if (dry) return child.getDryLayout(c);
    child.layout(c, parentUsesSize: true);
    return child.size;
  }

  void place(RenderBox child, Offset offset, {required bool dry}) {
    if (!dry) (child.parentData! as _FrostedParentData).offset = offset;
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Render object for [FrostedDialogBody].
class RenderFrostedDialogBody extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FrostedParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FrostedParentData>,
        _FrostedChildren {
  RenderFrostedDialogBody(
    this._scrolling,
    this._minWidth,
    this._maxWidth, [
    this._viewportHeight = double.infinity,
  ]);

  int? _scrolling;
  set scrolling(int? value) {
    if (value == _scrolling) return;
    _scrolling = value;
    markNeedsLayout();
  }

  double _minWidth;
  set minWidth(double value) {
    if (value == _minWidth) return;
    _minWidth = value;
    markNeedsLayout();
  }

  double _maxWidth;
  set maxWidth(double value) {
    if (value == _maxWidth) return;
    _maxWidth = value;
    markNeedsLayout();
  }

  double _viewportHeight;
  set viewportHeight(double value) {
    if (value == _viewportHeight) return;
    _viewportHeight = value;
    markNeedsLayout();
  }

  /// The body's width when its widest section needs [needed].
  double _widthFor(double needed) => needed.clamp(_minWidth, _maxWidth);

  double _neededWidth() =>
      widest((child) => child.getMinIntrinsicWidth(double.infinity));

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final children = childList;
    final width = constraints.constrainWidth(_widthFor(_neededWidth()));
    final scrolling = _scrolling;
    final heights = List<double>.filled(children.length, 0);
    var fixed = 0.0;
    for (var i = 0; i < children.length; i++) {
      if (i == scrolling) continue;
      heights[i] = sizeChild(
        children[i],
        BoxConstraints.tightFor(width: width),
        dry: dry,
      ).height;
      fixed += heights[i];
    }
    if (scrolling != null && scrolling < children.length) {
      final available = constraints.hasBoundedHeight
          ? constraints.maxHeight
          : _viewportHeight;
      // The fixed sections leave room: the content takes it, and the actions
      // stay pinned. They leave none: the whole body scrolls, and the
      // content shows up to a viewport of its own on the way.
      final room = fixed < available ? available - fixed : available;
      heights[scrolling] = sizeChild(
        children[scrolling],
        BoxConstraints(minWidth: width, maxWidth: width, maxHeight: room),
        dry: dry,
      ).height;
    }
    var y = 0.0;
    for (var i = 0; i < children.length; i++) {
      place(children[i], Offset(0, y), dry: dry);
      y += heights[i];
    }
    return constraints.constrain(Size(width, y));
  }

  @override
  double computeMinIntrinsicWidth(double height) => _widthFor(_neededWidth());

  @override
  double computeMaxIntrinsicWidth(double height) => _widthFor(_neededWidth());

  double _height(double width) =>
      childList.fold(0, (h, child) => h + child.getMinIntrinsicHeight(width));

  @override
  double computeMinIntrinsicHeight(double width) => _height(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _height(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }
}

/// Lays out the Frosted actions, given in the caller's order (cancel first,
/// primary last). Stacked full width with the last on top, [gap] apart; when
/// wider than [rowMinWidth] with exactly two actions that fit side by side,
/// in a row in the caller's reading order, aligned to the end (the left
/// under a right-to-left [Directionality]).
class FrostedDialogActions extends MultiChildRenderObjectWidget {
  const FrostedDialogActions({
    super.key,
    required this.gap,
    required this.rowMinWidth,
    required super.children,
  });

  final double gap;
  final double rowMinWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderFrostedDialogActions(gap, rowMinWidth, Directionality.of(context));

  @override
  void updateRenderObject(
    BuildContext context,
    RenderFrostedDialogActions renderObject,
  ) => renderObject
    ..gap = gap
    ..rowMinWidth = rowMinWidth
    ..textDirection = Directionality.of(context);
}

/// Render object for [FrostedDialogActions].
class RenderFrostedDialogActions extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FrostedParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FrostedParentData>,
        _FrostedChildren {
  RenderFrostedDialogActions(this._gap, this._rowMinWidth, this._textDirection);

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  double _rowMinWidth;
  set rowMinWidth(double value) {
    if (value == _rowMinWidth) return;
    _rowMinWidth = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  bool _inRow(double width) {
    if (childCount != 2 || width <= _rowMinWidth) return false;
    final natural = childList.fold<double>(
      0,
      (sum, child) => sum + child.getMaxIntrinsicWidth(double.infinity),
    );
    return natural + _gap <= width;
  }

  /// Lays the children out (or measures them when [dry]) and returns the
  /// size; positions children only when not [dry].
  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final children = childList;
    if (children.isEmpty) return constraints.smallest;
    final width = constraints.maxWidth;
    Size sizeOf(RenderBox child, BoxConstraints c) =>
        sizeChild(child, c, dry: dry);

    if (_inRow(width)) {
      final loose = BoxConstraints(maxWidth: width);
      final sizes = [for (final child in children) sizeOf(child, loose)];
      final height = math.max(sizes[0].height, sizes[1].height);
      // Reading order: cancel, then the primary at the end.
      final rtl = _textDirection == TextDirection.rtl;
      final primaryLeft = rtl ? 0.0 : width - sizes[1].width;
      final cancelLeft = rtl
          ? sizes[1].width + _gap
          : primaryLeft - _gap - sizes[0].width;
      place(
        children[1],
        Offset(primaryLeft, (height - sizes[1].height) / 2),
        dry: dry,
      );
      place(
        children[0],
        Offset(cancelLeft, (height - sizes[0].height) / 2),
        dry: dry,
      );
      return constraints.constrain(Size(width, height));
    }
    final tight = BoxConstraints.tightFor(width: width);
    var y = 0.0;
    for (final child in children.reversed) {
      if (y > 0) y += _gap;
      final size = sizeOf(child, tight);
      place(child, Offset(0, y), dry: dry);
      y += size.height;
    }
    return constraints.constrain(Size(width, y));
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      widest((child) => child.getMinIntrinsicWidth(double.infinity));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      widest((child) => child.getMaxIntrinsicWidth(double.infinity));

  double _stackedHeight(double width) {
    final children = childList;
    if (children.isEmpty) return 0;
    return children.fold<double>(
          0,
          (h, child) => h + child.getMinIntrinsicHeight(width),
        ) +
        _gap * (children.length - 1);
  }

  @override
  double computeMinIntrinsicHeight(double width) => _stackedHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _stackedHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }
}
