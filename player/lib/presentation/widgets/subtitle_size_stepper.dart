import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/player/subtitle_size.dart';
import '../../core/settings/subtitle_size_setting.dart';
import '../../core/theme/colors.dart';

/// The subtitle sheet's size row. Writes the device setting directly, so
/// the text behind the sheet resizes as the viewer steps.
class SubtitleSizeStepper extends ConsumerWidget {
  const SubtitleSizeStepper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size =
        ref.watch(subtitleSizeSettingProvider).value ?? SubtitleSize.medium;
    final notifier = ref.read(subtitleSizeSettingProvider.notifier);
    final smaller = size.smaller;
    final larger = size.larger;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Subtitle size',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
          ),
          Row(
            children: [
              IconButton(
                key: const ValueKey('subtitle-size-decrement'),
                icon: const Icon(
                  Icons.text_decrease,
                  color: AppColors.textPrimary,
                ),
                tooltip: 'Smaller',
                onPressed: smaller == null ? null : () => notifier.set(smaller),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    size.label,
                    key: const ValueKey('subtitle-size-value'),
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('subtitle-size-increment'),
                icon: const Icon(
                  Icons.text_increase,
                  color: AppColors.textPrimary,
                ),
                tooltip: 'Larger',
                onPressed: larger == null ? null : () => notifier.set(larger),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
