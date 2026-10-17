import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/palette.dart';
import '../../core/theme/system_accent.dart';
import '../../core/theme/theme_preset.dart';
import 'osd_dialog.dart';

/// Shows the presets offered here and returns the one picked, or null if the
/// viewer dismissed the dialog. Same tile shape as the subtitle size picker,
/// so it works with D-pad focus on TV.
Future<ThemePreset?> showThemePresetPicker(
  BuildContext context,
  ThemePreset current,
  List<ThemePreset> options,
) {
  return showDialog<ThemePreset>(
    context: context,
    builder: (context) {
      final palette = context.palette;
      return OsdDialog(
        title: const Text('Theme'),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        content: Material(
          type: MaterialType.transparency,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final preset in options)
                  ListTile(
                    key: Key('theme-preset-option-${preset.name}'),
                    autofocus: preset == current,
                    leading: _Swatch(preset: preset),
                    title: Text(
                      preset.label,
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontWeight: preset == current
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    trailing: preset == current
                        ? Icon(Icons.check, color: palette.primary)
                        : null,
                    onTap: () => Navigator.of(context).pop(preset),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// The preset's ground with a dot of its accent.
class _Swatch extends ConsumerWidget {
  const _Swatch({required this.preset});

  final ThemePreset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = preset == ThemePreset.macos
        ? preset.palette(systemAccent: ref.watch(systemAccentProvider))
        : preset.palette();
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: p.background,
        shape: BoxShape.circle,
        border: Border.all(color: p.border),
      ),
      alignment: Alignment.center,
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(color: p.primary, shape: BoxShape.circle),
      ),
    );
  }
}
