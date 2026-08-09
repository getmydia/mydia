import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/colors.dart';
import '../../../../core/theme/depth_tokens.dart';
import '../../../widgets/glass_surface.dart';

/// A grouped container for settings rows.
///
/// Uses [GlassSurface.faux] rather than live glass: settings scrolls, and R8 in
/// `depth_tokens.dart` reserves real [BackdropFilter] passes for small fixed
/// chrome. A scrolling surface with live blur pays for a backdrop pass on every
/// frame it moves.
class SettingsCard extends StatelessWidget {
  final List<Widget> children;

  /// Optional fill for the hero variant, which uses a gradient rather than the
  /// flat container tone.
  final Gradient? gradient;

  const SettingsCard({super.key, required this.children, this.gradient});

  @override
  Widget build(BuildContext context) {
    return GlassSurface.faux(
      borderRadius: BorderRadius.circular(AppTheme.radiusCard),
      fillColor: gradient == null
          ? DepthTokens.surfaceVariant.withValues(alpha: 0.55)
          : null,
      gradient: gradient,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _withDividers(children),
      ),
    );
  }

  /// Dividers are drawn by the card, not the rows, so a row never has to know
  /// whether it is last.
  static List<Widget> _withDividers(List<Widget> children) {
    if (children.length < 2) return children;

    final result = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        result.add(
          const Divider(height: 1, thickness: 1, color: AppColors.divider),
        );
      }
      result.add(children[i]);
    }
    return result;
  }
}

/// An uppercase eyebrow label above a [SettingsCard].
class SettingsSection extends StatelessWidget {
  final String label;
  final List<Widget> children;

  const SettingsSection({
    super.key,
    required this.label,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: AppColors.textDisabled,
            ),
          ),
        ),
        SettingsCard(children: children),
      ],
    );
  }
}
