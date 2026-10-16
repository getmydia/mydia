// Resume: the player never trusts route absence as "no progress". The source
// player route asks the source for the saved position of the item it plays,
// and offers the resume dialog when that position clears the existing
// thresholds. The calendar carries no progress, so every calendar-initiated
// playback goes through the normal resume prompt, exactly like opening the
// same episode from its own detail screen would.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/player/best_file.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/item.dart';
import '../detail/detail_links.dart';

/// Plays [entry], picking the best version for this screen.
///
/// The calendar listing only knows the default version, so this fetches the
/// item and picks as a local Play button would. A failed fetch falls back to
/// the listing's version: a calendar tap still plays.
Future<void> playCalendarEntry(
  BuildContext context,
  WidgetRef ref,
  ItemSummary entry,
) async {
  final screenWidth = MediaQuery.sizeOf(context).width;
  final source = ref.read(mediaSourceProvider(entry.ref.sourceId));
  String? fileId = entry.defaultVersionId;
  if (source != null) {
    try {
      final detail = await source.item(entry.ref);
      fileId = await pickBestVersionId(detail.versions, screenWidth) ?? fileId;
    } catch (_) {
      // See the doc comment.
    }
  }
  if (!context.mounted) return;
  await context.push(sourcePlayerLocation(
    entry.ref,
    fileId: fileId,
    title: entry.title,
  ));
}
