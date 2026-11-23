import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/player/subtitle_size.dart';
import '../../../../core/settings/subtitle_size_setting.dart';
import '../../../../l10n/l10n.dart';
import '../../../widgets/controls/app_segmented.dart';
import 'settings_row.dart';

/// The Playback section's subtitle size row. Reads its own provider, so it
/// works while `UserSettings` is still loading or failed: the value lives on
/// this device, not the server.
///
/// The size is chosen inline. The row has no tap action, so it is not a focus
/// stop itself: the segmented control is the row's one stop, and Left and
/// Right on it change the size.
class SubtitleSizeSettingsRow extends ConsumerWidget {
  const SubtitleSizeSettingsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size =
        ref.watch(subtitleSizeSettingProvider).value ?? SubtitleSize.medium;
    final l10n = context.l10n;
    return SettingsRow.action(
      key: const Key('subtitle-size-row'),
      icon: Icons.closed_caption,
      title: l10n.settingsSubtitleSizeTitle,
      subtitle: l10n.settingsSubtitleSizeSubtitle,
      trailing: AppSegmented<SubtitleSize>(
        key: const Key('subtitle-size-control'),
        semanticLabel: l10n.settingsSubtitleSizeTitle,
        segments: [
          for (final s in SubtitleSize.values)
            AppSegment(
              value: s,
              label: l10n.subtitleSizeShortName(s),
              semanticLabel: l10n.subtitleSizeName(s),
            ),
        ],
        selected: size,
        onChanged: (picked) =>
            ref.read(subtitleSizeSettingProvider.notifier).set(picked),
      ),
    );
  }
}
