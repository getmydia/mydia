import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/palette.dart';

/// A miniature of a theme for the settings grid: its ground, two surface
/// bars and a dot of its accent.
class ThemePresetPreview extends StatelessWidget {
  const ThemePresetPreview({super.key, required this.palette});

  final MydiaPalette palette;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: palette.background,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Bar(color: palette.surface),
                  const SizedBox(height: 6),
                  _Bar(color: palette.surfaceHigh, widthFactor: 0.65),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: palette.primary,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.color, this.widthFactor = 1});

  final Color color;
  final double widthFactor;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: widthFactor,
        child: Container(
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(5),
          ),
        ),
      ),
    );
  }
}
