/// The sidebar's destinations while a third-party source is on screen.
/// Mydia's own destinations (calendar, collections, downloads, favorites)
/// mean nothing for those sources, so they are replaced, not greyed. The
/// frame matches Mydia's nav: Home and Search on top, Settings pinned at the
/// bottom, so switching servers changes only the libraries in between.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_status.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/theme/colors.dart';
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
    this.selectedRowFocusNode,
  });

  final SourceId sourceId;
  final String location;
  final ValueChanged<String> onNavigate;

  /// Node for the row matching [location], so the shell can focus the
  /// sidebar deliberately when the viewer presses left at the content edge.
  ///
  /// Falls back to Home when no row matches, such as `/s/<id>/item/...`,
  /// for the reason `SidebarContent` documents on its own node: otherwise the
  /// node attaches to nothing and a remote cannot reach the sidebar from the
  /// routes it does not list.
  final FocusNode? selectedRowFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final root = '/s/${sourceId.value}';
    final libraries = switch (ref.watch(sourceLibrariesProvider(sourceId))) {
      AsyncData(:final value) => value,
      _ => const <Library>[],
    };
    final searchable =
        ref.watch(mediaSourceProvider(sourceId))?.as<Searchable>() != null;
    // Without a Mydia sign-in the router sends `/settings` back to the
    // source's home, so the row would be a dead end.
    final mydiaSignedIn = switch (ref.watch(authStateProvider)) {
      AsyncData(value: AuthStatus.authenticated) => true,
      _ => false,
    };
    final libraryTargets = [
      for (final library in libraries)
        '$root/library/${Uri.encodeComponent(library.ref.id)}',
    ];
    final matched = location == root ||
        (searchable && location == '$root/search') ||
        libraryTargets.contains(location);
    // The row carrying the shell's node: the selected one, else Home.
    String focusTarget() => matched ? location : root;
    SidebarRow row(String key, IconData icon, String label, String target) =>
        SidebarRow(
          key: ValueKey('source-nav-$key'),
          focusNode: target == focusTarget() ? selectedRowFocusNode : null,
          icon: icon,
          selectedIcon: icon,
          label: label,
          isSelected: location == target,
          onTap: () => onNavigate(target),
        );

    return Column(
      children: [
        Expanded(
          child: ListView(
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
            ],
          ),
        ),
        if (mydiaSignedIn) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Divider(
              height: 1,
              color: AppColors.divider.withValues(alpha: 0.15),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SidebarRow(
              key: const ValueKey('source-nav-settings'),
              icon: Icons.settings_outlined,
              selectedIcon: Icons.settings_rounded,
              label: 'Settings',
              isSelected: false,
              onTap: () => onNavigate('/settings'),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}
