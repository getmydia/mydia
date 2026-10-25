import 'package:flutter/material.dart';

import '../../core/player/subtitle_size.dart';
import '../../core/theme/palette.dart';
import '../../l10n/l10n.dart';
import 'osd_dialog.dart';

/// Shows the subtitle size choices and returns the one picked, or null if
/// the viewer dismissed the dialog. Same tile shape as the quality picker,
/// so it reads the same in Settings and works with D-pad focus on TV.
Future<SubtitleSize?> showSubtitleSizePicker(
  BuildContext context,
  SubtitleSize current,
) {
  return showDialog<SubtitleSize>(
    context: context,
    builder: (context) {
      final palette = context.palette;
      return OsdDialog(
        title: Text(context.l10n.settingsSubtitleSizeTitle),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: Material(
          type: MaterialType.transparency,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final size in SubtitleSize.values)
                  ListTile(
                    key: Key('subtitle-size-option-${size.name}'),
                    autofocus: size == current,
                    leading: Icon(
                      size == current
                          ? Icons.check_circle
                          : Icons.circle_outlined,
                      color: size == current
                          ? palette.primary
                          : palette.textSecondary,
                    ),
                    title: Text(
                      context.l10n.subtitleSizeName(size),
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontWeight: size == current
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    onTap: () => Navigator.of(context).pop(size),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
