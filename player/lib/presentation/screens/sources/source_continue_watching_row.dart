/// The Continue Watching row on a source's home, for a source with the
/// `ContinueWatching` capability.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/capabilities.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/source_error.dart';
import '../../widgets/media_context_menu.dart';
import '../../widgets/source_artwork.dart';
import '../../widgets/toast/toaster.dart';
import '../detail/detail_links.dart';
import 'source_browse_providers.dart';
import 'source_poster_row.dart';

/// `Invented Series · S1 · E2` for an episode, the item's own caption
/// otherwise.
String? continueWatchingCaption(ItemSummary item) {
  final caption = item.subtitle ?? item.year?.toString();
  return switch ((item.showTitle, caption)) {
    (final show?, final caption?) => '$show · $caption',
    (final show?, null) => show,
    (null, _) => caption,
  };
}

class SourceContinueWatchingRow extends ConsumerWidget {
  const SourceContinueWatchingRow({super.key, required this.sourceId});

  final SourceId sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = sourceContinueWatchingProvider(sourceId);
    ref.listen(provider, (_, next) {
      if (next case AsyncError(:final error)) {
        debugPrint('Continue Watching failed for ${sourceId.value}: $error');
      }
    });
    final state = ref.watch(provider);
    // hasValue first: on a failure with no earlier list, the row is empty.
    final items = state.hasValue ? state.requireValue : const <ItemSummary>[];
    if (items.isEmpty) return const SizedBox.shrink();
    final continueWatching =
        ref.watch(mediaSourceProvider(sourceId))?.as<ContinueWatching>();
    return SourcePosterRow(
      key: const Key('source-continue-watching'),
      title: 'Continue Watching',
      railId: 'continue',
      items: items,
      posterFor: (context, item) => SourcePoster(
        key: ValueKey('source-continue-${item.ref.externalId}'),
        item: item,
        subtitle: continueWatchingCaption(item),
        onTap: () => _play(context, ref, item.ref),
        onContextMenu: (cardContext) => _openMenu(
          cardContext,
          ref,
          item.ref,
          removable:
              continueWatching?.canRemoveFromContinueWatching(item) ?? false,
        ),
      ),
    );
  }
}

enum _Action { details, remove }

/// Plays the item's first version. The session resumes from the detail's
/// saved position on its own.
Future<void> _play(BuildContext context, WidgetRef ref, ItemRef item) async {
  final source = ref.read(mediaSourceProvider(item.sourceId));
  if (source == null) return;
  final toaster = Toaster.of(context);
  final ItemDetail detail;
  try {
    detail = await source.item(item);
  } catch (e) {
    toaster.show(
      e is SourceException ? e.viewerMessage : 'Could not open this title.',
      kind: ToastKind.error,
    );
    return;
  }
  final version = detail.versions.firstOrNull;
  if (version == null) {
    toaster.show('This title has nothing to play.', kind: ToastKind.error);
    return;
  }
  if (!context.mounted) return;
  await context.push(sourcePlayerLocation(
    detail.summary.ref,
    fileId: version.id,
    title: detail.summary.title,
  ));
  if (!context.mounted) return;
  invalidateSourceItemWrites(ref, item);
}

Future<void> _openMenu(
  BuildContext cardContext,
  WidgetRef ref,
  ItemRef item, {
  required bool removable,
}) async {
  final position = popupPositionBelow(cardContext);
  if (position == null) return;
  final selected = await showMenu<_Action>(
    context: cardContext,
    position: position,
    items: [
      const PopupMenuItem(
        key: Key('source-continue-details'),
        value: _Action.details,
        child: Text('Details'),
      ),
      if (removable)
        const PopupMenuItem(
          key: Key('source-continue-remove'),
          value: _Action.remove,
          child: Text('Remove from Continue Watching'),
        ),
    ],
  );
  if (selected == null || !cardContext.mounted) return;
  switch (selected) {
    case _Action.details:
      await cardContext.push(sourceItemLocation(item));
    case _Action.remove:
      await _remove(cardContext, ref, item);
  }
}

Future<void> _remove(BuildContext context, WidgetRef ref, ItemRef item) async {
  final continueWatching =
      ref.read(mediaSourceProvider(item.sourceId))?.as<ContinueWatching>();
  if (continueWatching == null) return;
  final toaster = Toaster.of(context);
  try {
    await continueWatching.removeFromContinueWatching(item);
  } catch (e) {
    toaster.show(
      e is SourceException ? e.viewerMessage : 'Could not remove this title.',
      kind: ToastKind.error,
    );
    return;
  }
  if (!context.mounted) return;
  invalidateSourceContinueWatchingWrites(ref, item);
}
