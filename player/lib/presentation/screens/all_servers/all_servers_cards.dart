/// Locations and cards for the All servers views.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/capabilities.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../domain/sources/source_error.dart';
import '../../../domain/navigation/all_servers_locations.dart';
import '../../widgets/media_context_menu.dart';
import '../../widgets/source_artwork.dart';
import '../../widgets/toast/toaster.dart';
import '../detail/detail_links.dart';
import '../sources/source_browse_providers.dart'
    show invalidateSourceContinueWatchingWrites;
import 'all_servers_providers.dart';

export '../../../domain/navigation/all_servers_locations.dart';

String allServersLibraryLocation(LibraryKind kind) => kind == LibraryKind.shows
    ? allServersShowsLocation
    : allServersMoviesLocation;

/// Every server's items, Mydia's included, open the shared screens under `/s/`.
String allServersItemLocation(ItemRef ref) => sourceItemLocation(ref);

/// Where `/all*` goes before it builds: home when fewer than two servers are
/// included, since one server is just that server.
String? allServersRedirect(int includedCount) => includedCount < 2 ? '/' : null;

/// The server a card opens, with how many other copies it stands in for.
String? allServersServerLabel(String? server, int extraCopies) =>
    server == null || extraCopies <= 0 ? server : '$server +$extraCopies';

/// A poster captioned with its server's name.
class AllServersPoster extends ConsumerWidget {
  const AllServersPoster({
    super.key,
    required this.item,
    this.caption,
    this.onContextMenu,
    this.extraCopies = 0,
    this.onTap,
  });

  final ItemSummary item;

  /// Copies on other servers this card stands in for, shown as `+N`.
  final int extraCopies;

  /// Shown before the server name, such as `Show · S1 · E2`.
  final String? caption;
  final void Function(BuildContext posterContext)? onContextMenu;

  /// Null opens the item.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(allServersNamesProvider)[item.ref.sourceId];
    return SourcePoster(
      key: ValueKey(
          'all-poster-${item.ref.sourceId.value}-${item.ref.externalId}'),
      item: item,
      subtitle: [
        caption ?? item.year?.toString(),
        allServersServerLabel(server, extraCopies)
      ].whereType<String>().join(' · '),
      onTap: onTap ?? () => context.push(allServersItemLocation(item.ref)),
      onContextMenu: onContextMenu,
    );
  }
}

/// The Continue Watching card menu: Details, and Remove from Continue Watching
/// when the item's server allows it. A removal refreshes the merged list.
Future<void> showAllServersContinueMenu(
    BuildContext c, WidgetRef ref, ItemSummary item) async {
  final source = ref
      .read(allServersSourcesProvider)
      .where((s) => s.id == item.ref.sourceId)
      .firstOrNull;
  final cw = source?.as<ContinueWatching>();
  final removable = cw?.canRemoveFromContinueWatching(item) ?? false;
  final position = popupPositionBelow(c);
  if (position == null) return;
  final choice = await showMenu<String>(
    context: c,
    position: position,
    items: [
      const PopupMenuItem(
          key: Key('all-continue-details'),
          value: 'details',
          child: Text('Details')),
      if (removable)
        const PopupMenuItem(
            key: Key('all-continue-remove'),
            value: 'remove',
            child: Text('Remove from Continue Watching')),
    ],
  );
  if (choice == null || !c.mounted) return;
  switch (choice) {
    case 'details':
      await c.push(allServersItemLocation(item.ref));
    case 'remove':
      if (cw == null) return;
      final toaster = Toaster.of(c);
      try {
        await cw.removeFromContinueWatching(item.dismissRef);
      } catch (e) {
        toaster.show(
          e is SourceException
              ? e.viewerMessage
              : 'Could not remove this title.',
          kind: ToastKind.error,
        );
        return;
      }
      ref.invalidate(allServersContinueWatchingProvider);
      // Home reads each server's cached rail and stays mounted under the
      // listing.
      invalidateSourceContinueWatchingWrites(ref, item.dismissRef);
  }
}
