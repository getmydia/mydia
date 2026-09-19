import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';
import '../../core/theme/depth_tokens.dart';
import '../../domain/models/quality_delivery_subtitle.dart';
import '../../domain/models/quality_rung.dart';
import 'osd_dialog.dart';

/// The stats row inside the quality sheet.
const Key statsToggleKey = Key('quality-stats-toggle');

/// Shows the playback quality picker and returns the chosen rung, or null if
/// the viewer dismissed it.
///
/// [rungs] is Auto followed by `deriveQualityLadder`'s ladder, which already
/// excludes rungs that would upscale the source. [clampNote], when present,
/// explains that the server is limiting the stream below what was chosen,
/// which happens on a relay connection where the cap is not negotiable by
/// the client.
///
/// [autoSubtitle] is what Auto is doing or would do (see
/// `autoDeliverySubtitle`). [originalSubtitle] is the delivery-mode line for
/// the Original rung (Direct Play / lossless / re-encoding), computed by the
/// caller.
///
/// [statsEnabled] and [onStatsChanged] add a "Stats for nerds" row under a
/// divider at the foot of the sheet. Both or neither: the settings
/// screen's standing-preference picker passes neither and keeps its
/// current shape. The sheet is where a viewer already stands when they
/// wonder why the picture is soft, which is why the panel's discovery path
/// is here rather than on a chrome button `SecondaryCluster` cannot
/// afford.
Future<QualityRung?> showQualityPicker(
  BuildContext context,
  List<QualityRung> rungs,
  QualityRung current, {
  required String autoSubtitle,
  required String originalSubtitle,
  String? clampNote,
  bool? statsEnabled,
  ValueChanged<bool>? onStatsChanged,
}) {
  var statsValue = statsEnabled ?? false;
  return showDialog<QualityRung>(
    context: context,
    builder: (context) => OsdDialog(
      title: const Text('Video Quality'),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (clampNote != null)
                Padding(
                  key: const Key('quality-clamp-note'),
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                  child: Text(
                    clampNote,
                    style: const TextStyle(
                      color: AppColors.warningText,
                      fontSize: 12,
                    ),
                  ),
                ),
              for (final rung in rungs)
                _rungTile(
                    context, rung, current, autoSubtitle, originalSubtitle),
              if (statsEnabled != null && onStatsChanged != null) ...[
                const Divider(height: 17, color: DepthTokens.osdDivider),
                StatefulBuilder(
                  builder: (context, setState) {
                    return SwitchListTile(
                      key: statsToggleKey,
                      value: statsValue,
                      title: const Text(
                        'Stats for nerds',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14.5,
                        ),
                      ),
                      subtitle: const Text(
                        'Also in Settings. Stays on after the controls fade.',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11.5,
                        ),
                      ),
                      secondary: const Icon(
                        Icons.speed,
                        color: AppColors.textSecondary,
                      ),
                      onChanged: (next) {
                        setState(() => statsValue = next);
                        onStatsChanged(next);
                      },
                    );
                  },
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
      ],
    ),
  );
}

Widget _rungTile(
  BuildContext context,
  QualityRung rung,
  QualityRung current,
  String autoSubtitle,
  String originalSubtitle,
) {
  final isSelected = rung == current;
  final subtitle = rung.isAuto
      ? autoSubtitle
      : rung.isOriginal
          ? originalSubtitle
          : cappedRungDeliverySubtitle(rung.maxBitrateKbps);
  return ListTile(
    key: isSelected
        ? Key('quality-rung-selected-${rung.label}')
        : Key('quality-rung-${rung.label}'),
    leading: Icon(
      isSelected ? Icons.check_circle : Icons.circle_outlined,
      color: isSelected ? AppColors.primary : AppColors.textSecondary,
    ),
    title: Text(
      rung.label,
      style: TextStyle(
        color: AppColors.textPrimary,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
    ),
    subtitle: Text(
      subtitle,
      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
    ),
    onTap: () => Navigator.of(context).pop(rung),
  );
}
