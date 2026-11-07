import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/sources/files/files_scan_controller.dart';
import '../../../core/sources/source.dart';
import '../../../core/theme/palette.dart';
import '../../../l10n/l10n.dart';

/// "Scanning 312 of 2,040" above a files library while its folders are read.
/// Takes no space when no scan runs.
class FilesScanBanner extends ConsumerWidget {
  const FilesScanBanner({super.key, required this.sourceId});

  final SourceId sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(filesScanProvider(sourceId));
    if (!scan.running) return const SizedBox.shrink();
    final l10n = context.l10n;
    final format = NumberFormat.decimalPattern(l10n.localeName);
    final palette = context.palette;
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
              l10n.filesScanProgress(
                  format.format(scan.done), format.format(scan.total)),
              style: TextStyle(color: palette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
