import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/palette.dart';

/// The title (and optional caption) above a [SettingsChoiceGrid], styled
/// like a row's title and subtitle.
class SettingsGridHeading extends StatelessWidget {
  const SettingsGridHeading({super.key, required this.title, this.caption});

  final String title;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final caption = this.caption;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: palette.textPrimary,
            ),
          ),
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                caption,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: palette.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
