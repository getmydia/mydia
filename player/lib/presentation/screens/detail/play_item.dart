/// What Play does everywhere: start playback, never open a details page in
/// its place.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/player/best_file.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/source_error.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/toast/toaster.dart';
import '../sources/source_browse_providers.dart';
import 'detail_links.dart';

/// Plays [item] for this screen; the session resumes from the saved position
/// on its own. Movies, episodes and videos play their best version. A show
/// plays its next-up episode, and opens when the source has none to offer. A
/// season or folder has nothing to play itself, so it opens.
Future<void> playItem(BuildContext context, WidgetRef ref, ItemRef item) async {
  final source = ref.read(mediaSourceProvider(item.sourceId));
  if (source == null) return;
  if (item.kind == ItemKind.season || item.kind == ItemKind.folder) {
    await context.push(sourceItemLocation(item));
    return;
  }
  if (item.kind == ItemKind.show) {
    ItemSummary? next;
    try {
      next = await source.as<NextUp>()?.nextUp(item);
    } catch (_) {
      next = null;
    }
    if (!context.mounted) return;
    if (next == null) {
      await context.push(sourceItemLocation(item));
      return;
    }
    return playItem(context, ref, next.ref);
  }

  final toaster = Toaster.of(context);
  final l10n = context.l10n;
  final screenWidth = MediaQuery.sizeOf(context).width;
  final ItemDetail detail;
  try {
    detail = await source.item(item);
  } catch (e) {
    toaster.show(
      e is SourceException ? e.viewerMessage : l10n.detailOpenTitleFailed,
      kind: ToastKind.error,
    );
    return;
  }
  final fileId = await pickBestVersionId(detail.versions, screenWidth);
  if (fileId == null) {
    toaster.show(l10n.detailNothingToPlay, kind: ToastKind.error);
    return;
  }
  if (!context.mounted) return;
  await context.push(sourcePlayerLocation(
    detail.summary.ref,
    fileId: fileId,
    title: detail.summary.title,
  ));
  if (!context.mounted) return;
  invalidateSourceItemWrites(ref, item);
}
