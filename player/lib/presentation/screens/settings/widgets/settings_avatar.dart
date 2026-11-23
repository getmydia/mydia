import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/palette.dart';

/// The first grapheme of a username on a flat disc, or a person icon when
/// there is no name.
///
/// Shared by the dialog's account card and `SettingsIdentity`. Neutral rather
/// than gold: `colors.dart` reserves the primary hue for main actions,
/// selected items, and links, and an avatar initial is none of those.
class SettingsAvatar extends StatelessWidget {
  const SettingsAvatar({
    super.key,
    required this.username,
    required this.size,
    required this.color,
    this.border,
  });

  final String username;
  final double size;
  final Color color;
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: border,
      ),
      child: username.isEmpty
          ? Icon(Icons.person, size: size * 0.47, color: palette.textSecondary)
          : Text(
              // characters.first keeps a whole grapheme, so a leading emoji
              // is not split into half a surrogate pair.
              username.characters.first.toUpperCase(),
              style: TextStyle(
                fontSize: size * 0.4,
                fontWeight: FontWeight.w600,
                color: palette.textPrimary,
              ),
            ),
    );
  }
}
