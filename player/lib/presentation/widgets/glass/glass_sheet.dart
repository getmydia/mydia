import 'package:flutter/material.dart';

import '../../../core/theme/liquid_glass/liquid_glass_support.dart';
import '../../../core/ui/reduced_motion.dart';
import '../glass_surface.dart';
import 'glass_emergence.dart';

/// [showModalBottomSheet] on iOS and macOS modal glass, growing out of
/// [origin] when given. Elsewhere it is the plain sheet with the caller's
/// [backgroundColor] and [shape], exactly as before.
Future<T?> showGlassSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  BuildContext? origin,
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool? showDragHandle,
  ShapeBorder? shape,
  bool useRootNavigator = false,
}) {
  if (!LiquidGlassSupport.platformEligible) {
    return showModalBottomSheet<T>(
      context: context,
      builder: builder,
      backgroundColor: backgroundColor,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      shape: shape,
      useRootNavigator: useRootNavigator,
    );
  }
  final alignment =
      origin == null ? Alignment.bottomCenter : glassEmergenceAlignment(origin);
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: isScrollControlled,
    showDragHandle: showDragHandle,
    useRootNavigator: useRootNavigator,
    builder: (sheetContext) {
      final route = ModalRoute.of(sheetContext);
      final body = GlassSurface.modal(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: Material(
          type: MaterialType.transparency,
          child: builder(sheetContext),
        ),
      );
      final animation = route?.animation;
      if (animation == null) return body;
      return glassEmergence(
        animation: animation,
        alignment: alignment,
        reduceMotion: ReducedMotion.of(sheetContext),
        child: body,
      );
    },
  );
}
