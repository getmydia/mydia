import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/glass_material.dart';
import '../../../../core/theme/palette.dart';
import '../../../../core/theme/theme_providers.dart';
import '../../../../l10n/l10n.dart';
import 'settings_choice_grid.dart';
import 'settings_grid_heading.dart';

/// The Appearance section's material picker (Liquid Glass or Frosted).
/// Device-local like the theme. Absent where only Frosted is offered (TV).
class GlassMaterialSettingsRow extends ConsumerWidget {
  const GlassMaterialSettingsRow({
    super.key,
    @visibleForTesting this.debugIsTv,
  });

  /// Forces the TV answer in tests; null asks `InputCapabilities`.
  final bool? debugIsTv;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!GlassMaterial.liquid.isAvailableOn(
      defaultTargetPlatform,
      isTv: debugIsTv,
    )) {
      return const SizedBox.shrink();
    }
    final material = ref.watch(glassMaterialSettingProvider);
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsGridHeading(title: l10n.settingsMaterialTitle),
          SettingsChoiceGrid<GlassMaterial>(
            key: const Key('glass-material-row'),
            label: l10n.settingsMaterialTitle,
            columns: 2,
            layout: SettingsChoiceLayout.inline,
            selected: material,
            choices: [
              SettingsChoice<GlassMaterial>(
                value: GlassMaterial.liquid,
                label: l10n.glassMaterialName(GlassMaterial.liquid),
                preview: const _MaterialPreview(liquid: true),
              ),
              SettingsChoice<GlassMaterial>(
                value: GlassMaterial.frosted,
                label: l10n.glassMaterialName(GlassMaterial.frosted),
                preview: const _MaterialPreview(liquid: false),
              ),
            ],
            onSelected: (picked) =>
                ref.read(glassMaterialSettingProvider.notifier).set(picked),
          ),
        ],
      ),
    );
  }
}

/// A static stand-in for the material: a two-tone gradient behind a
/// translucent pill for Liquid, a flat pill for Frosted. No blur.
class _MaterialPreview extends StatelessWidget {
  const _MaterialPreview({required this.liquid});

  final bool liquid;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: liquid ? null : palette.surfaceHigh,
        gradient: liquid
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [palette.primary, palette.surfaceBright],
              )
            : null,
      ),
      child: Center(
        child: Container(
          width: 28,
          height: 14,
          decoration: BoxDecoration(
            color: liquid
                ? palette.textPrimary.withValues(alpha: 0.35)
                : palette.surfaceBright,
            borderRadius: BorderRadius.circular(7),
          ),
        ),
      ),
    );
  }
}
