import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/downloads/download_providers.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/models/download_request.dart';
import '../../../domain/sources/item.dart';
import '../../widgets/quality_download_dialog.dart';
import '../../widgets/toast/toaster.dart';

/// Ask which option, then queue the download. The same for every source:
/// the source says what it offers and the service does the rest.
Future<void> startItemDownload(
  BuildContext context,
  WidgetRef ref, {
  required ItemRef item,
  required DownloadMetadata metadata,
}) async {
  final manager = await ref.read(downloadManagerProvider.future);
  if (!context.mounted) return;
  if (manager.isDownloaded(item)) {
    showToast(context, 'Already downloaded');
    return;
  }
  final downloadable =
      ref.read(mediaSourceProvider(item.sourceId))?.as<Downloadable>();
  if (downloadable == null) {
    showToast(context, 'This server is not available to download from',
        kind: ToastKind.error);
    return;
  }

  final option = await pickDownloadOption(
    context,
    title: metadata.title,
    options: downloadable.downloadOptions(item),
  );
  if (option == null || !context.mounted) return;

  try {
    await manager.start(DownloadRequest(
      ref: item,
      optionId: option.resolution,
      metadata: metadata,
      expectedBytes: option.actualSize ??
          (option.estimatedSize > 0 ? option.estimatedSize : null),
    ));
    if (context.mounted) {
      showToast(context, 'Download started', kind: ToastKind.success);
    }
  } catch (e) {
    if (context.mounted) {
      showToast(context, 'Failed to start download: $e', kind: ToastKind.error);
    }
  }
}
