import 'package:flutter/material.dart';

import '../../core/theme/depth_tokens.dart';
import 'glass_surface.dart';

/// [showModalBottomSheet] on the OSD material.
///
/// The sheet's own Material is transparent so [GlassSurface.osd] owns the
/// fill, hairline, blur and top-corner radius. No drop shadow: the modal
/// barrier already separates the sheet from the video.
Future<T?> showOsdBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (context) => GlassSurface.osd(
      elevation: OsdElevation.none,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(DepthTokens.radiusOsdSheet),
      ),
      child: builder(context),
    ),
  );
}
