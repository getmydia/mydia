/// The server picker the sidebar's server header opens.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/sources/lock/source_lock_controller.dart';
import '../../../core/sources/media_source.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/theme/colors.dart';
import 'sidebar_row.dart';

/// What the viewer chose in the picker. The header turns it into navigation,
/// so the picker itself never touches the router or the selection.
sealed class PickerChoice {
  const PickerChoice();
}

final class PickSource extends PickerChoice {
  const PickSource(this.source);

  final Source source;
}

/// The merged All servers views.
final class PickAllServers extends PickerChoice {
  const PickAllServers();
}

final class AddServer extends PickerChoice {
  const AddServer();
}

final class ManageServers extends PickerChoice {
  const ManageServers();
}

/// Show hidden servers behind the unlock screen, or lock again.
final class ToggleHidden extends PickerChoice {
  const ToggleHidden();
}

/// Switch which Plex Home user [account] acts as.
final class SwitchUser extends PickerChoice {
  const SwitchUser(this.account);

  final ProviderAccount account;
}

/// Opens the picker and resolves to the choice, or null when dismissed.
///
/// The narrow layout (the drawer) gets a bottom sheet. Wider layouts get a
/// popover hung under [anchorContext]'s box. Both are routes, so Back on a
/// phone or TV remote and Escape on a keyboard close them, and focus stays
/// inside until they do.
Future<PickerChoice?> showSourcePicker(
  BuildContext anchorContext, {
  required SourceId? currentId,
}) {
  final list = SourcePickerList(currentId: currentId);
  if (!Breakpoints.isDesktop(anchorContext)) {
    return showModalBottomSheet<PickerChoice>(
      context: anchorContext,
      backgroundColor: AppColors.surfaceVariant,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(child: list),
    );
  }
  final box = anchorContext.findRenderObject()! as RenderBox;
  final anchor = box.localToGlobal(Offset.zero) & box.size;
  return showGeneralDialog<PickerChoice>(
    context: anchorContext,
    barrierDismissible: true,
    barrierLabel:
        MaterialLocalizations.of(anchorContext).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (_, __, ___) => _Popover(anchor: anchor, child: list),
    transitionBuilder: (_, animation, __, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class _Popover extends StatelessWidget {
  const _Popover({required this.anchor, required this.child});

  final Rect anchor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final top = anchor.bottom + 4;
    return Stack(
      children: [
        Positioned(
          left: anchor.left,
          top: top,
          width: anchor.width,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight:
                  math.max(0, MediaQuery.sizeOf(context).height - top - 16),
            ),
            child: Material(
              color: AppColors.surfaceVariant,
              elevation: 8,
              borderRadius: const BorderRadius.all(Radius.circular(12)),
              clipBehavior: Clip.antiAlias,
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

IconData sourceKindIcon(SourceKind kind) => switch (kind) {
      SourceKind.mydia => Icons.dns_rounded,
      SourceKind.plex => Icons.live_tv_rounded,
      SourceKind.stash => Icons.video_library_rounded,
      SourceKind.jellyfin => Icons.smart_display_rounded,
    };

/// Sources grouped by account, in the order each account first appears.
List<List<Source>> groupSourcesByAccount(List<Source> sources) {
  final groups = <String, List<Source>>{};
  for (final source in sources) {
    groups.putIfAbsent(source.account.id, () => []).add(source);
  }
  return groups.values.toList();
}

/// Rebuilds with [sourceId]'s connection status, or null when the source
/// has no [MediaSource].
class SourceStatusBuilder extends ConsumerWidget {
  const SourceStatusBuilder({
    super.key,
    required this.sourceId,
    required this.builder,
  });

  final SourceId sourceId;
  final Widget Function(BuildContext context, SourceConnectionStatus? status)
      builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(mediaSourceProvider(sourceId))?.statusListenable;
    if (status == null) return builder(context, null);
    return ValueListenableBuilder(
      valueListenable: status,
      builder: (context, current, _) => builder(context, current),
    );
  }
}

class SourceStatusDot extends StatelessWidget {
  const SourceStatusDot(this.status, {super.key});

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

/// Every server grouped by account, then Add and Manage.
class SourcePickerList extends ConsumerStatefulWidget {
  const SourcePickerList({super.key, required this.currentId});

  /// The source the header names. Its row is selected and takes focus, so a
  /// remote's first press moves from where the viewer already is. Null means
  /// the All servers views are on screen: that row is current instead.
  final SourceId? currentId;

  @override
  ConsumerState<SourcePickerList> createState() => _SourcePickerListState();
}

class _SourcePickerListState extends ConsumerState<SourcePickerList> {
  final _currentNode = FocusNode(debugLabel: 'source-picker-current');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _currentNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _currentNode.dispose();
    super.dispose();
  }

  void _pick(PickerChoice choice) => Navigator.of(context).pop(choice);

  /// A Plex account whose Home has another user to switch to.
  bool _hasHomeUsers(ProviderAccount account) =>
      account.kind == SourceKind.plex &&
      ref.watch(accountProfilesProvider(account.id)).length > 1;

  @override
  Widget build(BuildContext context) {
    final sources = ref.watch(switchableSourcesProvider);
    final locks = ref.watch(sourceLocksProvider);
    final unlocked = ref.watch(sourceLockProvider);
    // Not a ListView: that builds lazily, so a current row below the fold
    // would never attach `_currentNode` and the focus request would do nothing.
    return SingleChildScrollView(
        key: const ValueKey('source-picker'),
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (ref.watch(allServersSourcesProvider).length >= 2)
              SidebarRow(
                key: const ValueKey('source-switcher-all'),
                focusNode: widget.currentId == null ? _currentNode : null,
                icon: Icons.layers_rounded,
                selectedIcon: Icons.layers_rounded,
                label: 'All servers',
                isSelected: widget.currentId == null,
                onTap: () => _pick(const PickAllServers()),
              ),
            for (final group in groupSourcesByAccount(sources)) ...[
              if (group.first.id != SourceId.legacyMydia)
                _AccountCaption(account: group.first.account),
              for (final source in group)
                _SourceRow(
                  source: source,
                  isCurrent: source.id == widget.currentId,
                  locked: !unlocked && locks[source.id] == SourceLock.locked,
                  focusNode:
                      source.id == widget.currentId ? _currentNode : null,
                  onTap: () => _pick(PickSource(source)),
                ),
              if (_hasHomeUsers(group.first.account))
                SidebarRow(
                  key: ValueKey(
                      'source-switcher-switch-user-${group.first.account.id}'),
                  icon: Icons.switch_account_rounded,
                  selectedIcon: Icons.switch_account_rounded,
                  label: 'Switch user (${group.first.profile.name})',
                  isSelected: false,
                  onTap: () => _pick(SwitchUser(group.first.account)),
                ),
            ],
            if (!kIsWeb) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Divider(
                  height: 1,
                  color: AppColors.divider.withValues(alpha: 0.4),
                ),
              ),
              SidebarRow(
                key: const ValueKey('source-switcher-add'),
                icon: Icons.add_rounded,
                selectedIcon: Icons.add_rounded,
                label: 'Add server',
                isSelected: false,
                onTap: () => _pick(const AddServer()),
              ),
              SidebarRow(
                key: const ValueKey('source-switcher-manage'),
                icon: Icons.tune_rounded,
                selectedIcon: Icons.tune_rounded,
                label: 'Manage servers',
                isSelected: false,
                onTap: () => _pick(const ManageServers()),
              ),
              SidebarRow(
                key: const ValueKey('source-switcher-hidden'),
                icon: unlocked ? Icons.lock_rounded : Icons.visibility_rounded,
                selectedIcon:
                    unlocked ? Icons.lock_rounded : Icons.visibility_rounded,
                label: unlocked ? 'Lock now' : 'Show hidden servers',
                isSelected: false,
                onTap: () => _pick(const ToggleHidden()),
              ),
            ],
          ],
        ));
  }
}

class _AccountCaption extends StatelessWidget {
  const _AccountCaption({required this.account});

  final ProviderAccount account;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('source-switcher-account-${account.id}'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
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

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.isCurrent,
    required this.locked,
    required this.focusNode,
    required this.onTap,
  });

  final Source source;
  final bool isCurrent;
  final bool locked;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SourceStatusBuilder(
      sourceId: source.id,
      builder: (context, status) {
        final dim = !source.server.presence ||
            status == SourceConnectionStatus.unreachable;
        return Opacity(
          opacity: dim ? 0.5 : 1,
          child: SidebarRow(
            key: ValueKey('source-switcher-${source.id.value}'),
            focusNode: focusNode,
            icon: sourceKindIcon(source.kind),
            selectedIcon: sourceKindIcon(source.kind),
            label: source.account.needsReauth
                ? '${source.displayName} (sign in again)'
                : source.displayName,
            isSelected: isCurrent,
            badge: locked
                ? Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.lock_rounded,
                        size: 12,
                        key: ValueKey(
                            'source-switcher-lock-${source.id.value}')),
                    if (status != null) ...[
                      const SizedBox(width: 4),
                      SourceStatusDot(status),
                    ],
                  ])
                : (status == null ? null : SourceStatusDot(status)),
            onTap: onTap,
          ),
        );
      },
    );
  }
}
