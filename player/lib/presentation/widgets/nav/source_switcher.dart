/// Lists the viewer's servers in the sidebar once there is more than one.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/media_source.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/theme/colors.dart';
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
          for (final group in _groupByAccount(sources)) ...[
            if (group.first.kind != SourceKind.mydia)
              _AccountCaption(account: group.first.account),
            for (final source in group)
              _SourceRow(
                source: source,
                isSelected: source.id == active,
                onNavigate: onNavigate,
              ),
          ],
          if (!kIsWeb) ...[
            SidebarRow(
              key: const ValueKey('source-switcher-add'),
              icon: Icons.add_rounded,
              selectedIcon: Icons.add_rounded,
              label: 'Add server',
              isSelected: false,
              onTap: () => onNavigate('/sources/add'),
            ),
            SidebarRow(
              key: const ValueKey('source-switcher-manage'),
              icon: Icons.tune_rounded,
              selectedIcon: Icons.tune_rounded,
              label: 'Manage servers',
              isSelected: false,
              onTap: () => onNavigate('/sources/manage'),
            ),
          ],
        ],
      ),
    );
  }

  /// Sources grouped by account, in the order each account first appears.
  static List<List<Source>> _groupByAccount(List<Source> sources) {
    final groups = <String, List<Source>>{};
    for (final source in sources) {
      groups.putIfAbsent(source.account.id, () => []).add(source);
    }
    return groups.values.toList();
  }

  static IconData _iconFor(SourceKind kind) => switch (kind) {
        SourceKind.mydia => Icons.dns_rounded,
        SourceKind.plex => Icons.live_tv_rounded,
        SourceKind.stash => Icons.video_library_rounded,
        SourceKind.jellyfin => Icons.smart_display_rounded,
      };
}

class _AccountCaption extends StatelessWidget {
  const _AccountCaption({required this.account});

  final ProviderAccount account;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('source-switcher-account-${account.id}'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Text(
        account.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: AppColors.textSecondary),
      ),
    );
  }
}

class _SourceRow extends ConsumerWidget {
  const _SourceRow({
    required this.source,
    required this.isSelected,
    required this.onNavigate,
  });

  final Source source;
  final bool isSelected;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(mediaSourceProvider(source.id))?.statusListenable;
    final needsReauth = source.account.needsReauth;
    Widget row(SourceConnectionStatus? current) {
      final dim = !source.server.presence ||
          current == SourceConnectionStatus.unreachable;
      return Opacity(
        opacity: dim ? 0.5 : 1,
        child: SidebarRow(
          key: ValueKey('source-switcher-${source.id.value}'),
          icon: SourceSwitcher._iconFor(source.kind),
          selectedIcon: SourceSwitcher._iconFor(source.kind),
          label: needsReauth
              ? '${source.displayName} (sign in again)'
              : source.displayName,
          isSelected: isSelected,
          badge: current == null ? null : _StatusDot(current),
          onTap: () {
            if (needsReauth) {
              onNavigate('/sources/add/${source.kind.name}'
                  '?account=${source.account.id}');
              return;
            }
            ref.read(selectedSourceIdProvider.notifier).select(source.id);
            onNavigate(source.kind == SourceKind.mydia
                ? '/'
                : '/s/${source.id.value}');
          },
        ),
      );
    }

    if (status == null) return row(null);
    return ValueListenableBuilder(
      valueListenable: status,
      builder: (context, current, _) => row(current),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot(this.status);

  final SourceConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      SourceConnectionStatus.local => (AppColors.success, 'Local'),
      SourceConnectionStatus.remote => (AppColors.success, 'Remote'),
      SourceConnectionStatus.relay => (AppColors.warning, 'Relay'),
      SourceConnectionStatus.connecting => (AppColors.info, 'Connecting'),
      SourceConnectionStatus.unreachable => (AppColors.error, 'Unreachable'),
    };
    return Tooltip(
      message: label,
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
