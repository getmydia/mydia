/// The sidebar's destinations while a third-party source is on screen.
/// Mydia's own destinations (calendar, collections, downloads, favorites)
/// mean nothing for those sources, so they are replaced, not greyed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/capabilities.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/library.dart';
import '../../screens/sources/source_browse_providers.dart';
import 'sidebar_row.dart';

/// The source id in a `/s/<id>/...` location, or null elsewhere.
String? sourceIdFromLocation(String location) {
  if (!location.startsWith('/s/')) return null;
  final rest = location.substring(3);
  final end = rest.indexOf('/');
  final id = end == -1 ? rest : rest.substring(0, end);
  try {
    return id.isEmpty ? null : Uri.decodeComponent(id);
  } on FormatException {
    return null;
  } on ArgumentError {
    // A truncated escape such as `%E0%A4%A` throws this, not FormatException.
    return null;
  }
}

class SourceNavList extends ConsumerWidget {
  const SourceNavList({
    super.key,
    required this.sourceId,
    required this.location,
    required this.onNavigate,
  });

  final SourceId sourceId;
  final String location;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = '/s/${sourceId.value}';
    final libraries = switch (ref.watch(sourceLibrariesProvider(sourceId))) {
      AsyncData(:final value) => value,
      _ => const <Library>[],
    };
    final searchable =
        ref.watch(mediaSourceProvider(sourceId))?.as<Searchable>() != null;
    SidebarRow row(String key, IconData icon, String label, String target) =>
        SidebarRow(
          key: ValueKey('source-nav-$key'),
          icon: icon,
          selectedIcon: icon,
          label: label,
          isSelected: location == target,
          onTap: () => onNavigate(target),
        );

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        row('home', Icons.home_rounded, 'Home', root),
        if (searchable)
          row('search', Icons.search_rounded, 'Search', '$root/search'),
        for (final library in libraries)
          row(
            'library-${library.ref.id}',
            switch (library.kind) {
              LibraryKind.movies => Icons.movie_rounded,
              LibraryKind.shows => Icons.tv_rounded,
              LibraryKind.videos => Icons.video_library_rounded,
            },
            library.title,
            '$root/library/${Uri.encodeComponent(library.ref.id)}',
          ),
        row('servers', Icons.dns_rounded, 'Servers', '/sources/manage'),
      ],
    );
  }
}
