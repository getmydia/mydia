/// The rail's one geometry, shared by every entry in it.
///
/// A rail entry is a fixed-height row laid out at the expanded width. Its
/// 48x48 icon box sits at the same place whether the rail is collapsed or
/// expanded, and the label sits to the right of it. Expanding only widens the
/// clip around the rows and fades the labels in, so nothing ever moves under
/// the pointer.
library;

import 'package:flutter/material.dart';

import '../../../core/theme/depth_tokens.dart';
import '../../../core/ui/reduced_motion.dart';

/// Marks the subtree as the floating rail's content. Rows, the server switcher
/// and Back to Mydia read it to pick their rail geometry; the mobile drawer and
/// edit mode do not provide it and keep the full-width layout.
class RailScope extends InheritedWidget {
  const RailScope({
    super.key,
    required this.labelsVisible,
    required super.child,
  });

  /// Whether the rail is expanded, so labels show and tooltips are redundant.
  final bool labelsVisible;

  /// Side of the square icon box.
  static const double iconBox = 48;

  /// Height of every rail entry.
  static const double rowHeight = 48;

  /// Space between the icon box and the label.
  static const double labelGap = 12;

  /// Labels fade out this fast on collapse, while the width shrinks.
  static const Duration fadeOut = Duration(milliseconds: 100);

  static RailScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RailScope>();

  @override
  bool updateShouldNotify(RailScope oldWidget) =>
      labelsVisible != oldWidget.labelsVisible;
}

/// Fades its child with the rail's labels: in over the latter part of the
/// width animation, out quickly on collapse.
class RailLabel extends StatelessWidget {
  const RailLabel({super.key, required this.visible, required this.child});

  final bool visible;
  final Widget child;

  static const Curve fadeInCurve = Interval(0.4, 1.0);

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: context.reducedMotionDuration(
        visible ? DepthTokens.motionMedium : RailScope.fadeOut,
      ),
      curve: visible ? fadeInCurve : Curves.linear,
      child: child,
    );
  }
}

/// One rail row: a 48x48 [iconBox], then a [label] that fades with the rail.
///
/// The row always lays out at whatever width it is given (the expanded width),
/// so the collapsed rail simply clips the label.
class RailEntry extends StatelessWidget {
  const RailEntry({
    super.key,
    required this.iconBox,
    required this.label,
    required this.tooltip,
    required this.labelsVisible,
    this.onTap,
  });

  /// The icon box's content. Sized to 48x48 here.
  final Widget iconBox;

  /// Shown to the right of the icon box.
  final Widget label;

  /// Names the entry while the labels are hidden.
  final String tooltip;

  final bool labelsVisible;

  /// Tapping anywhere on the row, label included.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: RailScope.rowHeight,
        child: Row(
          children: [
            Tooltip(
              message: labelsVisible ? '' : tooltip,
              child: SizedBox(
                width: RailScope.iconBox,
                height: RailScope.iconBox,
                child: iconBox,
              ),
            ),
            const SizedBox(width: RailScope.labelGap),
            Expanded(
              child: RailLabel(visible: labelsVisible, child: label),
            ),
          ],
        ),
      ),
    );
  }
}
