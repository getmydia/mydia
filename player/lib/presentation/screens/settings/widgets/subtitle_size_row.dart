import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/player/subtitle_size.dart';
import '../../../../core/settings/subtitle_size_setting.dart';
import '../../../widgets/subtitle_size_picker.dart';
import 'settings_row.dart';

/// The Playback section's subtitle size row. Reads its own provider, so it
/// works while `UserSettings` is still loading or failed: the value lives on
/// this device, not the server.
class SubtitleSizeSettingsRow extends ConsumerWidget {
  const SubtitleSizeSettingsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size =
        ref.watch(subtitleSizeSettingProvider).value ?? SubtitleSize.medium;
    return SettingsRow.navigation(
      key: const Key('subtitle-size-row'),
      icon: Icons.closed_caption,
      title: 'Subtitle size',
      subtitle: 'Text subtitles on this device',
      value: size.label,
      onTap: () async {
        final picked = await showSubtitleSizePicker(context, size);
        if (picked != null) {
          await ref.read(subtitleSizeSettingProvider.notifier).set(picked);
        }
      },
    );
  }
}
