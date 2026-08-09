import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../../../../core/connection/connection_summary.dart';
import '../../../../core/theme/colors.dart';
import '../../../../core/theme/depth_tokens.dart';
import '../../../widgets/connection_tone_color.dart';
import 'settings_section.dart';

/// Placeholder for a value that is not known yet. An en dash, not a hyphen, so
/// it reads as "no value" rather than as a minus sign.
const _unknown = '–';

/// The settings header: who you are, where you are connected, what you are
/// running.
///
/// Everything here is read-only except sign out. Separating these facts from
/// the controls below is the whole point of the redesign: the old screen gave a
/// relay URL and a logout button identical tiles.
///
/// Takes plain values rather than reading providers, so it pumps without a
/// `ProviderScope` and the screen stays the only place that wires state.
class SettingsHero extends StatelessWidget {
  final String username;
  final String serverUrl;
  final ConnectionSummary connection;

  /// Null renders the unknown placeholder. The screen maps `UpdateState`'s
  /// empty-string default onto null.
  final String? version;

  final VoidCallback onSignOut;

  const SettingsHero({
    super.key,
    required this.username,
    required this.serverUrl,
    required this.connection,
    required this.version,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          AppColors.primary.withValues(alpha: 0.10),
          DepthTokens.surfaceHigh.withValues(alpha: 0.70),
        ],
        stops: const [0.0, 0.52],
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
          child: Column(
            children: [
              Row(
                children: [
                  _Avatar(username: username),
                  const SizedBox(width: 14),
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
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    key: const Key('settings-sign-out'),
                    onPressed: onSignOut,
                    child: const Text('Sign out'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _StatStrip(connection: connection, version: version),
            ],
          ),
        ),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.username});

  final String username;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary, AppColors.primaryFocus],
        ),
      ),
      child: username.isEmpty
          ? const Icon(Icons.person, size: 22, color: AppColors.onPrimary)
          : Text(
              username.substring(0, 1).toUpperCase(),
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.onPrimary,
              ),
            ),
    );
  }
}

class _StatStrip extends StatelessWidget {
  const _StatStrip({required this.connection, required this.version});

  final ConnectionSummary connection;
  final String? version;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.background.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: DepthTokens.rimColor),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            Expanded(
              child: _Stat(
                label: 'Connection',
                value: connection.label,
                dotColor: connectionToneColor(connection.tone),
              ),
            ),
            VerticalDivider(width: 1, thickness: 1, color: AppColors.divider),
            Expanded(
              child: _Stat(label: 'Version', value: version ?? _unknown),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.dotColor});

  final String label;
  final String value;
  final Color? dotColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
              color: AppColors.textDisabled,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (dotColor != null) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dotColor,
                  ),
                ),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    fontFeatures: [FontFeature.tabularFigures()],
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
