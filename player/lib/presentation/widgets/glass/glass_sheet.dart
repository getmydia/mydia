import 'package:material_ui/material_ui.dart';

import '../../../core/theme/liquid_glass/glass_style.dart';
import '../../../core/theme/liquid_glass/liquid_geometry.dart';
import '../../../core/theme/palette.dart';
import '../../../core/theme/surface_roles.dart';
import '../../../core/ui/reduced_motion.dart';
import '../glass_surface.dart';
import 'glass_emergence.dart';

const Duration _frostedSheetDuration = Duration(milliseconds: 450);
const Curve _frostedSheetCurve = Cubic(0.32, 0.72, 0, 1);

/// Key of the Frosted drag handle, for tests.
const Key frostedSheetHandleKey = ValueKey('frosted-sheet-handle');

/// [showModalBottomSheet] on Liquid Glass modal glass, growing out of
/// [origin] when given.
///
/// On Frosted it is an opaque `surfaceHigh` sheet with a hairline top edge,
/// a 36x4 drag handle and an iOS-like 450 ms ease-out. The caller's
/// [backgroundColor] and [shape] are ignored there so every sheet matches.
/// [showDragHandle] only matters on Frosted as an opt-out: an explicit
/// `false` draws no handle, anything else draws ours.
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
  final liquid = GlassStyle.of(context);
  if (!liquid) {
    final palette = context.palette;
    final roles = context.surfaceRoles;
    final duration = ReducedMotion.duration(context, _frostedSheetDuration);
    final handle = showDragHandle != false;
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: palette.surfaceHigh,
      isScrollControlled: isScrollControlled,
      showDragHandle: false,
      useRootNavigator: useRootNavigator,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(roles.radiusModal),
        ),
        side: BorderSide(color: roles.hairline),
      ),
      sheetAnimationStyle: AnimationStyle(
        duration: duration,
        reverseDuration: duration,
        curve: _frostedSheetCurve,
      ),
      builder: (sheetContext) {
        if (!handle) return builder(sheetContext);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Container(
                key: frostedSheetHandleKey,
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: palette.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Flexible(child: builder(sheetContext)),
          ],
        );
      },
    );
  }
  final alignment = origin == null
      ? Alignment.bottomCenter
      : glassEmergenceAlignment(origin);
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
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(LiquidGeometry.sheetRadius),
        ),
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
