/// The sidebar's destinations while the merged All servers views are on
/// screen. Mydia's own destinations are replaced, as for a single source.
library;

import 'package:flutter/material.dart';

import 'sidebar_row.dart';

/// Whether [location] is one of the merged `/all` views.
bool isAllServersLocation(String location) =>
    location == '/all' || location.startsWith('/all/');

class AllServersNavList extends StatelessWidget {
  const AllServersNavList({
    super.key,
    required this.location,
    required this.onNavigate,
    this.selectedRowFocusNode,
  });

  final String location;
  final ValueChanged<String> onNavigate;

  /// Node for the row matching [location], falling back to Home when no row
  /// matches, for the reason `SourceNavList` documents.
  final FocusNode? selectedRowFocusNode;

  static const _rows = [
    ('home', Icons.home_rounded, 'Home', '/all'),
    ('movies', Icons.movie_rounded, 'Movies', '/all/movies'),
    ('shows', Icons.tv_rounded, 'TV Shows', '/all/shows'),
    ('search', Icons.search_rounded, 'Search', '/all/search'),
  ];

  @override
  Widget build(BuildContext context) {
    final matched = _rows.any((r) => r.$4 == location);
    final focusTarget = matched ? location : '/all';
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        for (final (key, icon, label, target) in _rows)
          SidebarRow(
            key: ValueKey('all-nav-$key'),
            focusNode: target == focusTarget ? selectedRowFocusNode : null,
            icon: icon,
            selectedIcon: icon,
            label: label,
            isSelected: location == target,
            onTap: () => onNavigate(target),
          ),
      ],
    );
  }
}
