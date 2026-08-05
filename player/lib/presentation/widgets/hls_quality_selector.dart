import 'package:flutter/material.dart';

import '../../domain/models/quality_rung.dart';

/// Shows the playback quality picker and returns the chosen rung, or null if
/// the viewer dismissed it.
///
/// [ladder] comes from `deriveQualityLadder`, so it already excludes rungs
/// that would upscale the source. [clampNote], when present, explains that
/// the server is limiting the stream below what was chosen, which happens on
/// a relay connection where the cap is not negotiable by the client.
Future<QualityRung?> showQualityPicker(
  BuildContext context,
  List<QualityRung> ladder,
  QualityRung current, {
  String? clampNote,
}) {
  return showDialog<QualityRung>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: Colors.grey[900],
      title: const Text(
        'Video Quality',
        style: TextStyle(color: Colors.white),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: SingleChildScrollView(
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
                  style: TextStyle(color: Colors.amber[300], fontSize: 12),
                ),
              ),
            for (final rung in ladder) _rungTile(context, rung, current),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
        ),
      ],
    ),
  );
}

Widget _rungTile(BuildContext context, QualityRung rung, QualityRung current) {
  final isSelected = rung == current;
  return ListTile(
    key: isSelected
        ? Key('quality-rung-selected-${rung.label}')
        : Key('quality-rung-${rung.label}'),
    leading: Icon(
      isSelected ? Icons.check_circle : Icons.circle_outlined,
      color: isSelected ? Colors.red : Colors.grey,
    ),
    title: Text(
      rung.label,
      style: TextStyle(
        color: isSelected ? Colors.white : Colors.grey[300],
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
    ),
    subtitle: Text(
      rung.isOriginal
          ? 'Source quality, no re-encoding'
          : 'Up to ${rung.maxBitrateKbps} kbps',
      style: const TextStyle(color: Colors.grey, fontSize: 12),
    ),
    onTap: () => Navigator.of(context).pop(rung),
  );
}
