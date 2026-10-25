import 'package:flutter/material.dart';
import '../../core/theme/palette.dart';
import '../../domain/models/media_file.dart';
import '../../l10n/l10n.dart';

Future<MediaFile?> showQualitySelector(
  BuildContext context,
  List<MediaFile> files,
) async {
  if (files.isEmpty) return null;
  if (files.length == 1) return files.first;

  return showModalBottomSheet<MediaFile>(
    context: context,
    backgroundColor: context.palette.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => QualitySelectorSheet(files: files),
  );
}

class QualitySelectorSheet extends StatelessWidget {
  final List<MediaFile> files;

  const QualitySelectorSheet({
    super.key,
    required this.files,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                context.l10n.downloadSelectQuality,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            const SizedBox(height: 16),
            ...files.map(
              (file) => ListTile(
                onTap: () => Navigator.of(context).pop(file),
                title: Text(
                  file.displayQuality,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: _buildFileDetails(context.l10n, file, palette),
                trailing: const Icon(Icons.chevron_right),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget? _buildFileDetails(
    AppLocalizations l10n,
    MediaFile file,
    MydiaPalette palette,
  ) {
    final details = <String>[];

    if (file.bitrate != null) {
      final bitrateMbps = (file.bitrate! / 1000000).toStringAsFixed(1);
      details.add('$bitrateMbps Mbps');
    }

    if (file.size != null) {
      final sizeGB = (file.size! / 1073741824).toStringAsFixed(2);
      details.add('$sizeGB GB');
    }

    if (file.directPlaySupported) {
      details.add(l10n.qualityDirectPlay);
    }

    if (details.isEmpty) return null;

    return Text(
      details.join(' • '),
      style: TextStyle(
        color: palette.textSecondary,
        fontSize: 12,
      ),
    );
  }
}
