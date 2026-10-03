/// Lists the viewer's servers in the sidebar once there is more than one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import 'sidebar_row.dart';

class SourceSwitcher extends ConsumerWidget {
  const SourceSwitcher({super.key, required this.onNavigate});

  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(switchableSourcesProvider);
    if (sources.isEmpty) return const SizedBox.shrink();
    final active = ref.watch(activeSourceIdProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final source in sources)
            SidebarRow(
              key: ValueKey('source-switcher-${source.id.value}'),
              icon: _iconFor(source.kind),
              selectedIcon: _iconFor(source.kind),
              label: source.displayName,
              isSelected: source.id == active,
              onTap: () {
                ref.read(selectedSourceIdProvider.notifier).select(source.id);
                onNavigate(
                  source.kind == SourceKind.mydia
                      ? '/'
                      : '/s/${source.id.value}',
                );
              },
            ),
        ],
      ),
    );
  }

  static IconData _iconFor(SourceKind kind) => switch (kind) {
        SourceKind.mydia => Icons.dns_rounded,
        SourceKind.plex => Icons.live_tv_rounded,
        SourceKind.stash => Icons.video_library_rounded,
      };
}
