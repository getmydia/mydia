import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/cache/source_keys.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/item.dart';
import '../../widgets/media_context_menu.dart';
import '../../widgets/source_artwork.dart';
import '../../widgets/toast/toaster.dart';
import '../detail/play_item.dart';
import '../sources/source_browse_providers.dart';
import '../sources/source_listing_screen.dart';

class ContinueWatchingScreen extends ConsumerStatefulWidget {
  const ContinueWatchingScreen({super.key, required this.sourceId});

  final SourceId sourceId;

  @override
  ConsumerState<ContinueWatchingScreen> createState() =>
      _ContinueWatchingScreenState();
}

class _ContinueWatchingScreenState
    extends ConsumerState<ContinueWatchingScreen> {
  /// Cards taken off the grid before the server has answered. The list from
  /// the provider is never edited, so a failed removal returns its card to
  /// exactly where it was, and a refetch that lands mid-flight cannot be
  /// undone by it.
  final Set<ItemRef> _hidden = {};

  void _openMenu(BuildContext posterContext, ItemSummary item) {
    final removable = ref
            .read(mediaSourceProvider(widget.sourceId))
            ?.as<ContinueWatching>()
            ?.canRemoveFromContinueWatching(item) ??
        false;
    showMediaContextMenu(
      posterContext,
      target: MediaContextTarget(
        item: item.ref,
        show: item.showRef,
        hasFile: true,
        tapPlays: true,
        continueWatching: removable ? item.dismissRef : null,
      ),
      onPlay: () => playItem(context, ref, item.ref),
      onRemoveFromContinueWatching: () => _remove(item),
    );
  }

  Future<void> _remove(ItemSummary item) async {
    final continueWatching =
        ref.read(mediaSourceProvider(widget.sourceId))?.as<ContinueWatching>();
    if (continueWatching == null) return;
    // Captured before the await: the card is being removed from under this
    // context.
    final toaster = Toaster.of(context);

    // Every card of the same series leaves together; see `dismissRef`.
    final key = item.dismissRef;
    setState(() => _hidden.add(key));
    try {
      await continueWatching.removeFromContinueWatching(key);
    } catch (_) {
      if (mounted) setState(() => _hidden.remove(key));
      toaster.show(
        'Could not remove from Continue Watching',
        kind: ToastKind.error,
      );
      return;
    }
    if (mounted) invalidateSourceContinueWatchingWrites(ref, key);
  }

  @override
  Widget build(BuildContext context) {
    final sourceId = widget.sourceId;
    final provider = sourceContinueWatchingProvider(sourceId);
    return SourceListingScreen(
      sourceId: sourceId,
      icon: Icons.play_circle_outline_rounded,
      title: 'Continue Watching',
      queryKey: SourceKeys.continueWatching(sourceId),
      items: ref.watch(provider).whenData(
            (items) => [
              for (final item in items)
                if (!_hidden.contains(item.dismissRef)) item,
            ],
          ),
      onRetry: () => ref.invalidate(provider),
      errorTitle: 'Failed to load continue watching',
      emptyTitle: 'Nothing in progress.',
      // A tap plays, as on the home row; the menu carries details and removal.
      posterFor: (context, item, open) {
        // Null for a movie, so SourcePoster falls back to the year.
        return SourcePoster(
          key: ValueKey('source-poster-${item.ref.externalId}'),
          item: item,
          subtitle: showEpisodeCaption(item),
          onTap: () => playItem(context, ref, item.ref),
          onContextMenu: (posterContext) => _openMenu(posterContext, item),
          showMenuButton: true,
        );
      },
    );
  }
}
