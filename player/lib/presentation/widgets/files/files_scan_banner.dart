import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/sources/files/files_scan_controller.dart';
import '../../../core/sources/files/media_info/files_probe_queue.dart';
import '../../../core/sources/source.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';

/// Whether [scan], or the background read of file details after it
/// ([probe]), has something for [FilesScanBanner] to say.
bool filesScanBannerShows(ScanState scan, {ProbeProgress? probe}) =>
    scan.running || scan.skippedCount > 0 || probe?.running == true;

/// What a running [scan] is doing: the folders read while they are still
/// being listed, then the files handled out of the total.
String filesScanProgressText(AppLocalizations l10n, ScanState scan) {
  final format = NumberFormat.decimalPattern(l10n.localeName);
  return scan.walking
      ? l10n.filesScanReadingFolders(format.format(scan.foldersRead))
      : l10n.filesScanProgress(
          format.format(scan.done), format.format(scan.total));
}

/// How far the background read of file details has got.
String filesProbeProgressText(AppLocalizations l10n, ProbeProgress probe) {
  final format = NumberFormat.decimalPattern(l10n.localeName);
  return l10n.filesProbeProgress(
      format.format(probe.done), format.format(probe.total));
}

/// "Scanning 312 of 2,040" above a files library while its folders are read,
/// and afterwards how many folders and files the scan could not read, if any,
/// and a quieter line while file details are read in the background. Takes
/// no space otherwise.
class FilesScanBanner extends ConsumerWidget {
  const FilesScanBanner({super.key, required this.sourceId});

  final SourceId sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(filesScanProvider(sourceId));
    final probe = ref.watch(filesProbeQueueProvider(sourceId));
    if (!filesScanBannerShows(scan, probe: probe)) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final palette = context.palette;
    if (!scan.running) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (scan.skippedCount > 0)
            Padding(
              key: const Key('files-scan-skipped'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.folder_off_outlined,
                      size: 16, color: palette.textSecondary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.filesScanSkippedItems(scan.skippedCount),
                      style: TextStyle(color: palette.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          if (probe.running)
            Padding(
              key: const Key('files-probe-progress'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  const SizedBox.square(
                    dimension: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      filesProbeProgressText(l10n, probe),
                      style:
                          TextStyle(color: palette.textSecondary, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    }
    return Padding(
      key: const Key('files-scan-banner'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              filesScanProgressText(l10n, scan),
              style: TextStyle(color: palette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
