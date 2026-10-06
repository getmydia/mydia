/// Locations and cards for the All servers views.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/media_source.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../widgets/nav/all_servers_nav_list.dart'
    show allServersMoviesLocation, allServersShowsLocation;
import '../../widgets/source_artwork.dart';
import '../detail/detail_links.dart';
import 'all_servers_providers.dart';

export '../../widgets/nav/all_servers_nav_list.dart'
    show allServersRoot, allServersSearchLocation;

String allServersLibraryLocation(LibraryKind kind) => kind == LibraryKind.shows
    ? allServersShowsLocation
    : allServersMoviesLocation;

/// Every server's items, Mydia's included, open the shared screens under `/s/`.
String allServersItemLocation(ItemRef ref) => sourceItemLocation(ref);

/// Where `/all*` goes before it builds: home when fewer than two servers are
/// included, since one server is just that server.
String? allServersRedirect(List<MediaSource> included) =>
    included.length < 2 ? '/' : null;

/// A poster captioned with its server's name.
class AllServersPoster extends ConsumerWidget {
  const AllServersPoster(
      {super.key, required this.item, this.caption, this.onContextMenu});

  final ItemSummary item;

  /// Shown before the server name, such as `Show · S1 · E2`.
  final String? caption;
  final void Function(BuildContext posterContext)? onContextMenu;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(allServersNamesProvider)[item.ref.sourceId];
    return SourcePoster(
      key: ValueKey(
          'all-poster-${item.ref.sourceId.value}-${item.ref.externalId}'),
      item: item,
      subtitle: [caption ?? item.year?.toString(), server]
          .whereType<String>()
          .join(' · '),
      onTap: () => context.push(allServersItemLocation(item.ref)),
      onContextMenu: onContextMenu,
    );
  }
}
