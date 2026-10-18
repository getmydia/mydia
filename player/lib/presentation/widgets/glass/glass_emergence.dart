import 'package:flutter/widgets.dart';

/// Grows a sheet or popover out of the control that opened it: a scale
/// from 0.9 anchored at [alignment] plus a fade. With Reduce Motion it is
/// the fade alone.
Widget glassEmergence({
  required Animation<double> animation,
  required Alignment alignment,
  required bool reduceMotion,
  required Widget child,
}) {
  final curved = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  final faded = FadeTransition(opacity: curved, child: child);
  if (reduceMotion) return faded;
  return ScaleTransition(
    scale: Tween<double>(begin: 0.9, end: 1).animate(curved),
    alignment: alignment,
    child: faded,
  );
}

/// [origin]'s centre on screen, as an [Alignment] over the whole screen.
/// The centre of the screen when [origin] has no laid-out box.
Alignment glassEmergenceAlignment(BuildContext origin) {
  final box = origin.findRenderObject();
  final screen = MediaQuery.sizeOf(origin);
  if (box is! RenderBox || !box.hasSize || screen.isEmpty) {
    return Alignment.center;
  }
  final centre = box.localToGlobal(box.size.center(Offset.zero));
  return Alignment(
    (centre.dx / screen.width) * 2 - 1,
    (centre.dy / screen.height) * 2 - 1,
  );
}
