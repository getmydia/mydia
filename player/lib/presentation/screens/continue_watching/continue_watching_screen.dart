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
    showMediaContextMenu(
      posterContext,
      target: MediaContextTarget(
        id: item.ref.externalId,
        type: item.ref.kind.name,
        continueWatchingId: item.dismissRef.externalId,
      ),
      // Unreachable: with `tapPlays` false the menu never offers Play.
      onPlay: () {},
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
    final continueWatching =
        ref.watch(mediaSourceProvider(sourceId))?.as<ContinueWatching>();

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
      // `tapPlays` stays false: this grid opens the title, it does not play
      // it. That suppresses the navigation entries, which would only repeat
      // the tap, and leaves the removal. A source that cannot dismiss an
      // entry gets no menu rather than one that opens empty.
      posterFor: (context, item, open) {
        final removable =
            continueWatching?.canRemoveFromContinueWatching(item) ?? false;
        return SourcePoster(
          key: ValueKey('source-poster-${item.ref.externalId}'),
          item: item,
          subtitle: item.showTitle,
          onTap: open,
          onContextMenu: removable
              ? (posterContext) => _openMenu(posterContext, item)
              : null,
          showMenuButton: removable,
        );
      },
    );
  }
}
