import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/glass_material.dart';
import '../../../../core/theme/theme_providers.dart';
import '../../../../l10n/l10n.dart';
import 'settings_row.dart';

/// The Appearance section's Liquid Glass switch. Device-local like the theme
/// row. Absent where only Frosted is offered (TV).
class GlassMaterialSettingsRow extends ConsumerWidget {
  const GlassMaterialSettingsRow(
      {super.key, @visibleForTesting this.debugIsTv});

  /// Forces the TV answer in tests; null asks `InputCapabilities`.
  final bool? debugIsTv;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!GlassMaterial.liquid
        .isAvailableOn(defaultTargetPlatform, isTv: debugIsTv)) {
      return const SizedBox.shrink();
    }
    final material = ref.watch(glassMaterialSettingProvider);
    return SettingsRow.toggle(
      key: const Key('glass-material-row'),
      icon: Icons.blur_on,
      title: GlassMaterial.liquid.label,
      subtitle: context.l10n.settingsGlassMaterialSubtitle,
      value: material == GlassMaterial.liquid,
      onChanged: (on) => ref
          .read(glassMaterialSettingProvider.notifier)
          .set(on ? GlassMaterial.liquid : GlassMaterial.frosted),
    );
  }
}
