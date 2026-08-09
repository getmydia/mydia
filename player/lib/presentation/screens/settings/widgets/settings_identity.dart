import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';
import '../../../../core/theme/depth_tokens.dart';

/// Who you are and which server you are on.
///
/// Sits directly on the page background with no fill, border, or radius. The
/// rest of settings is a stack of cards, and giving identity a card of its own
/// is what made the status hero this replaces read as a panel bolted to the
/// top of the screen.
///
/// Horizontal padding matches `SettingsSection`'s eyebrow inset, so the avatar
/// lines up with the section label below it, and the band owns its own bottom
/// space so the screen does not emit a `SizedBox` after it.
///
/// Takes plain values rather than reading providers, so it pumps without a
/// `ProviderScope` and the screen stays the only place that wires state.
class SettingsIdentity extends StatelessWidget {
  final String username;
  final String serverUrl;

  const SettingsIdentity({
    super.key,
    required this.username,
    required this.serverUrl,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 22),
      child: Row(
        children: [
          _Avatar(username: username),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  username.isEmpty ? 'Signed in' : username,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.24,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (serverUrl.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    serverUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The initial on a flat disc.
///
/// Neutral rather than gold: `colors.dart` reserves the primary hue for main
/// actions, selected items, and links, and keeps chrome neutral so poster art
/// carries the colour. An avatar initial is none of those three.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.username});

  final String username;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.06),
        border: Border.all(
          color: DepthTokens.rimColor,
          width: DepthTokens.rimWidth,
        ),
      ),
      child: username.isEmpty
          ? const Icon(Icons.person, size: 18, color: AppColors.textSecondary)
          : Text(
              username.substring(0, 1).toUpperCase(),
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
    );
  }
}
