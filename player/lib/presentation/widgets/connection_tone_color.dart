import 'package:flutter/material.dart';

import '../../core/connection/connection_summary.dart';
import '../../core/theme/colors.dart';

/// Maps a [ConnectionTone] onto the palette's semantic colours.
///
/// Lives in the widget layer so [ConnectionSummary] itself stays colour-free.
/// Shared by the shell dot, the settings connection row, and the diagnostics
/// screen, so all three agree on what "relayed" looks like.
Color connectionToneColor(ConnectionTone tone) => switch (tone) {
      ConnectionTone.good => AppColors.success,
      ConnectionTone.caution => AppColors.warning,
      ConnectionTone.pending => AppColors.info,
    };
