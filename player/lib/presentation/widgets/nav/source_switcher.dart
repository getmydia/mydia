/// The sidebar's server header, shown once there is more than one source.
///
/// One row naming the server the page on screen belongs to. It used to list
/// every server with Add and Manage permanently above the nav, which cost
/// most of a phone's drawer and made it hard to tell which server the nav
/// below belonged to. The list now lives in the picker the header opens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/lock/source_lock_controller.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/theme/colors.dart';
import '../../screens/sources/plex_home_sheet.dart';
import '../focus_highlight.dart';
import 'source_nav_list.dart' show sourceIdFromLocation;
import 'source_picker.dart';

class SourceSwitcher extends ConsumerWidget {
  const SourceSwitcher({
    super.key,
    required this.location,
    required this.onNavigate,
    this.onSwitchSource,
  });

  final String location;

  /// Add, Manage and re-auth go here.
  final ValueChanged<String> onNavigate;

  /// Switching servers goes here, falling back to [onNavigate]. The mobile
  /// drawer passes a callback that leaves the drawer open, so the viewer
  /// sees the nav change under the new header.
  final ValueChanged<String>? onSwitchSource;

  /// The source the header names: the one in a `/s/<id>` location,
  /// otherwise Mydia, whose screens are every other location. The remembered
  /// pick only decides when Mydia is absent, on screens such as
  /// `/sources/manage`.
  static Source currentFor(
    List<Source> sources,
    String location,
    SourceId? active,
  ) {
    final fromLocation = sourceIdFromLocation(location);
    return sources.where((s) => s.id.value == fromLocation).firstOrNull ??
        sources.where((s) => s.kind == SourceKind.mydia).firstOrNull ??
        sources.where((s) => s.id == active).firstOrNull ??
        sources.first;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(switchableSourcesProvider);
    if (sources.isEmpty) return const SizedBox.shrink();
    final current =
        currentFor(sources, location, ref.watch(activeSourceIdProvider));

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: _Header(
        source: current,
        // Named only when the account's Plex Home has someone to switch to.
        homeUser: current.kind == SourceKind.plex &&
                ref.watch(accountProfilesProvider(current.account.id)).length >
                    1
            ? current.profile.name
            : null,
        onOpen: (anchorContext) => _open(anchorContext, ref, current),
      ),
    );
  }

  Future<void> _open(
    BuildContext anchorContext,
    WidgetRef ref,
    Source current,
  ) async {
    final choice = await showSourcePicker(anchorContext, currentId: current.id);
    // The header outlives the picker in practice, but `ref` is dead once it
    // unmounts and the analyzer cannot see that.
    if (choice == null || !anchorContext.mounted) return;
    switch (choice) {
      case AddServer():
        onNavigate('/sources/add');
      case ManageServers():
        onNavigate('/sources/manage');
      case ToggleHidden():
        if (ref.read(sourceLockProvider)) {
          ref.read(sourceLockProvider.notifier).lock();
        } else {
          onNavigate(unlockLocation('/sources/manage'));
        }
      case PickSource(:final source) when source.account.needsReauth:
        onNavigate('/sources/add/${source.kind.name}'
            '?account=${source.account.id}');
      case PickSource(:final source):
        ref.read(selectedSourceIdProvider.notifier).select(source.id);
        (onSwitchSource ?? onNavigate)(
            source.kind == SourceKind.mydia ? '/' : '/s/${source.id.value}');
      case SwitchUser(:final account):
        await showPlexHomeSheet(
          anchorContext,
          account: account,
          serverId: current.account.id == account.id ? current.server.id : null,
          onSwitched: (id) => (onSwitchSource ?? onNavigate)('/s/${id.value}'),
        );
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.source,
    required this.homeUser,
    required this.onOpen,
  });

  final Source source;

  /// The active Plex Home user, when the account has more than one.
  final String? homeUser;

  /// Receives this row's own context, which the picker's popover hangs under.
  final ValueChanged<BuildContext> onOpen;

  /// The line under the name, or null when it would only repeat it: Mydia's
  /// display name is already "Mydia".
  static String? _caption(Source source, String? homeUser) {
    if (source.account.needsReauth) return 'Sign in again';
    return switch (source.kind) {
      SourceKind.mydia => null,
      SourceKind.plex => homeUser == null
          ? 'Plex · ${source.account.displayName}'
          : 'Plex · ${source.account.displayName} · $homeUser',
      SourceKind.jellyfin => 'Jellyfin · ${source.account.displayName}',
      SourceKind.stash => 'Stash · ${source.account.displayName}',
    };
  }

  @override
  Widget build(BuildContext context) {
    void open() => onOpen(context);
    final theme = Theme.of(context).textTheme;
    final needsReauth = source.account.needsReauth;
    final caption = _caption(source, homeUser);

    return Semantics(
        button: true,
        label: 'Switch server, current: ${source.displayName}',
        child: FocusHighlight(
          key: const ValueKey('source-switcher-header'),
          onActivate: open,
          borderRadius: const BorderRadius.all(Radius.circular(12)),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: open,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant.withValues(alpha: 0.35),
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                  border: Border.all(
                      color: AppColors.border.withValues(alpha: 0.6)),
                ),
                child: Row(
                  children: [
                    SourceStatusBuilder(
                      sourceId: source.id,
                      builder: (context, status) => Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Icon(
                            sourceKindIcon(source.kind),
                            size: 22,
                            color: AppColors.primary,
                          ),
                          if (needsReauth)
                            const Positioned(
                              top: -4,
                              right: -4,
                              child: Icon(
                                Icons.error_rounded,
                                size: 12,
                                color: AppColors.warning,
                              ),
                            )
                          else if (status != null)
                            Positioned(
                              top: -2,
                              right: -2,
                              child: SourceStatusDot(status),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            source.displayName,
                            key: const ValueKey('source-switcher-header-name'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          if (caption != null)
                            Text(
                              caption,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.labelSmall?.copyWith(
                                color: needsReauth
                                    ? AppColors.warningText
                                    : AppColors.textSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.unfold_more_rounded,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ));
  }
}
