/// Below the All servers rows: one row per included server, opening its
/// home. Fixed, so edit mode does not arrange it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/sources_providers.dart';
import '../../screens/detail/detail_links.dart';
import '../connection_status_dot.dart';
import 'sidebar_row.dart';

class AllServersServerRows extends ConsumerWidget {
  const AllServersServerRows({
    super.key,
    required this.onNavigate,
    this.compact = false,
  });

  /// Icon-only rows for the collapsed rail; the "Servers" caption is dropped.
  final bool compact;

  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(allServersSourcesProvider);
    return Column(
      crossAxisAlignment:
          compact ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        if (!compact)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child:
                Text('Servers', style: Theme.of(context).textTheme.labelSmall),
          ),
        for (final s in sources)
          SidebarRow(
            key: ValueKey('all-server-row-${s.id.value}'),
            compact: compact,
            icon: Icons.dns_outlined,
            selectedIcon: Icons.dns,
            label: s.displayName,
            isSelected: false,
            badge: ConnectionStatusDot(location: sourceHomeLocation(s.id)),
            onTap: () {
              ref.read(selectedSourceIdProvider.notifier).select(s.id);
              onNavigate(sourceHomeLocation(s.id));
            },
          ),
      ],
    );
  }
}
