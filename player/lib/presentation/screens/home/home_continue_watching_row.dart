/// Continue Watching on Home, for any set of servers. A dismissal hides every
/// card of its series at once and brings them back if the server refuses,
/// because the merged list itself is never edited.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/capabilities.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/source_error.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/media_context_menu.dart';
import '../../widgets/toast/toaster.dart';
import '../all_servers/all_servers_cards.dart' show allServersServerLabel;
import '../detail/detail_links.dart';
import '../detail/play_item.dart';
import '../sources/continue_watching_card.dart';
import '../sources/source_browse_providers.dart';
import '../sources/source_poster_row.dart';
import 'home_rows.dart';

class HomeContinueWatchingRow extends ConsumerStatefulWidget {
  const HomeContinueWatchingRow({
    super.key,
    required this.rows,
    required this.onTitleTap,
  });

  final HomeRows rows;
  final VoidCallback onTitleTap;

  @override
  ConsumerState<HomeContinueWatchingRow> createState() =>
      _HomeContinueWatchingRowState();
}

class _HomeContinueWatchingRowState
    extends ConsumerState<HomeContinueWatchingRow> {
  /// Dismissals sent but not yet answered, by `ItemSummary.dismissRef`.
  final Set<ItemRef> _hidden = {};

  String? _label(ItemSummary item) {
    final rows = widget.rows;
    if (!rows.labelled) return null;
    return allServersServerLabel(
        rows.names[item.ref.sourceId], rows.extraCopies[item.ref] ?? 0);
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final item in widget.rows.continueWatching)
        if (!_hidden.contains(item.dismissRef)) item,
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return SourcePosterRow(
      key: const Key('home-continue-watching'),
      title: context.l10n.nextUpContinueWatching,
      railId: 'continue',
      items: items,
      itemWidth: ContinueWatchingCard.artSize.width,
      height: ContinueWatchingCard.heightFor(
        context,
        hasCaption: items.any((i) =>
            ContinueWatchingCard.hasCaptionFor(i, trailingLabel: _label(i))),
        hasTimeLeft: items.any(ContinueWatchingCard.hasTimeLeftFor),
      ),
      onTitleTap: widget.onTitleTap,
      posterFor: (context, item) => ContinueWatchingCard(
        key: ValueKey(
            'home-continue-${item.ref.sourceId.value}-${item.ref.externalId}'),
        item: item,
        trailingLabel: _label(item),
        onTap: () => playItem(context, ref, item.ref),
        onContextMenu: (cardContext) => _openMenu(cardContext, item),
      ),
    );
  }

  ContinueWatching? _capability(ItemSummary item) =>
      ref.read(mediaSourceProvider(item.ref.sourceId))?.as<ContinueWatching>();

  Future<void> _openMenu(BuildContext cardContext, ItemSummary item) async {
    final removable =
        _capability(item)?.canRemoveFromContinueWatching(item) ?? false;
    final position = popupPositionBelow(cardContext);
    if (position == null) return;
    final selected = await showMenu<_Action>(
      context: cardContext,
      position: position,
      items: [
        PopupMenuItem(
          key: const Key('home-continue-details'),
          value: _Action.details,
          child: Text(cardContext.l10n.commonDetails),
        ),
        if (removable)
          PopupMenuItem(
            key: const Key('home-continue-remove'),
            value: _Action.remove,
            child: Text(cardContext.l10n.mediaMenuRemoveFromContinueWatching),
          ),
      ],
    );
    if (selected == null || !cardContext.mounted) return;
    switch (selected) {
      case _Action.details:
        await cardContext.push(sourceItemLocation(item.ref));
      case _Action.remove:
        await _remove(cardContext, item);
    }
  }

  Future<void> _remove(BuildContext context, ItemSummary item) async {
    final continueWatching = _capability(item);
    if (continueWatching == null) return;
    final toaster = Toaster.of(context);
    final l10n = context.l10n;
    // The removal can outlive this row; a container does not.
    final container = ProviderScope.containerOf(context, listen: false);
    final key = item.dismissRef;
    setState(() => _hidden.add(key));
    try {
      await continueWatching.removeFromContinueWatching(key);
    } catch (e) {
      if (mounted) setState(() => _hidden.remove(key));
      toaster.show(
        e is SourceException ? e.viewerMessage : l10n.continueRemoveTitleFailed,
        kind: ToastKind.error,
      );
      return;
    }
    invalidateSourceContinueWatchingContainerWrites(container, key);
  }
}

enum _Action { details, remove }
