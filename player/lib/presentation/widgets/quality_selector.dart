import 'package:flutter/material.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/media_file.dart';

Future<MediaFile?> showQualitySelector(
  BuildContext context,
  List<MediaFile> files,
) async {
  if (files.isEmpty) return null;
  if (files.length == 1) return files.first;

  return showModalBottomSheet<MediaFile>(
    context: context,
    backgroundColor: AppColors.surface,
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
                'Select Quality',
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
                subtitle: _buildFileDetails(file),
                trailing: const Icon(Icons.chevron_right),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget? _buildFileDetails(MediaFile file) {
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
      details.add('Direct Play');
    }

    if (details.isEmpty) return null;

    return Text(
      details.join(' • '),
      style: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 12,
      ),
    );
  }
}
