/// The Continue Watching row on a source's home, for a source with the
/// `ContinueWatching` capability.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/player/best_file.dart';
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

class SourceContinueWatchingRow extends ConsumerStatefulWidget {
  const SourceContinueWatchingRow({super.key, required this.sourceId});

  final SourceId sourceId;

  @override
  ConsumerState<SourceContinueWatchingRow> createState() =>
      _SourceContinueWatchingRowState();
}

class _SourceContinueWatchingRowState
    extends ConsumerState<SourceContinueWatchingRow> {
  /// Dismissals sent but not yet answered, by `ItemSummary.dismissRef`. Every
  /// card of the same series leaves together, and a refusal brings them all
  /// back, because the provider list itself is never edited.
  final Set<ItemRef> _hidden = {};

  @override
  Widget build(BuildContext context) {
    final sourceId = widget.sourceId;
    final provider = sourceContinueWatchingProvider(sourceId);
    ref.listen(provider, (_, next) {
      if (next case AsyncError(:final error)) {
        debugPrint('Continue Watching failed for ${sourceId.value}: $error');
      }
    });
    final state = ref.watch(provider);
    // hasValue first: on a failure with no earlier list, the row is empty.
    final items = [
      for (final item
          in state.hasValue ? state.requireValue : const <ItemSummary>[])
        if (!_hidden.contains(item.dismissRef)) item,
    ];
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
          remove: () => _remove(cardContext, item),
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context, ItemSummary item) async {
    final continueWatching = ref
        .read(mediaSourceProvider(item.ref.sourceId))
        ?.as<ContinueWatching>();
    if (continueWatching == null) return;
    final toaster = Toaster.of(context);
    final key = item.dismissRef;
    setState(() => _hidden.add(key));
    try {
      await continueWatching.removeFromContinueWatching(key);
    } catch (e) {
      if (mounted) setState(() => _hidden.remove(key));
      toaster.show(
        e is SourceException ? e.viewerMessage : 'Could not remove this title.',
        kind: ToastKind.error,
      );
      return;
    }
    if (mounted) invalidateSourceContinueWatchingWrites(ref, key);
  }
}

enum _Action { details, remove }

/// Plays the item's best version for this screen. The session resumes from
/// the detail's saved position on its own.
Future<void> _play(BuildContext context, WidgetRef ref, ItemRef item) async {
  final source = ref.read(mediaSourceProvider(item.sourceId));
  if (source == null) return;
  final toaster = Toaster.of(context);
  final screenWidth = MediaQuery.sizeOf(context).width;
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
  final fileId = await pickBestVersionId(detail.versions, screenWidth);
  if (fileId == null) {
    toaster.show('This title has nothing to play.', kind: ToastKind.error);
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

Future<void> _openMenu(
  BuildContext cardContext,
  WidgetRef ref,
  ItemRef item, {
  required bool removable,
  required Future<void> Function() remove,
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
      await remove();
  }
}
