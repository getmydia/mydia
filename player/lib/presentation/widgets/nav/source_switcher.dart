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
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/colors.dart';
import '../../screens/detail/detail_links.dart';
import '../../screens/sources/plex_home_sheet.dart';
import '../focus_highlight.dart';
import '../../../domain/navigation/all_servers_locations.dart'
    show allServersRoot, isAllServersLocation;
import '../../../domain/navigation/source_nav.dart' show sourceIdFromLocation;
import 'rail_scope.dart';
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
  /// otherwise the remembered pick, on screens such as `/sources/manage`.
  static Source currentFor(
    List<Source> sources,
    String location,
    SourceId? active,
  ) {
    final fromLocation = sourceIdFromLocation(location);
    return sources.where((s) => s.id.value == fromLocation).firstOrNull ??
        sources.where((s) => s.id == active).firstOrNull ??
        sources.first;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(switchableSourcesProvider);
    if (sources.isEmpty) return const SizedBox.shrink();
    final current =
        currentFor(sources, location, ref.watch(activeSourceIdProvider));

    final allServers = isAllServersLocation(location);
    // Named only when the account's Plex Home has someone to switch to.
    final homeUser = current.kind == SourceKind.plex &&
            ref.watch(accountProfilesProvider(current.account.id)).length > 1
        ? current.profile.name
        : null;
    void open(BuildContext anchorContext) => _open(anchorContext, ref, current);

    final rail = RailScope.maybeOf(context);
    if (rail != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: _RailSwitcher(
          name: allServers ? 'All servers' : current.displayName,
          caption: allServers ? null : _Header._caption(current, homeUser),
          needsReauth: !allServers && current.account.needsReauth,
          labelsVisible: rail.labelsVisible,
          onOpen: open,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: _Header(
        source: current,
        allServers: allServers,
        homeUser: homeUser,
        onOpen: open,
      ),
    );
  }

  Future<void> _open(
    BuildContext anchorContext,
    WidgetRef ref,
    Source current,
  ) =>
      openSourcePicker(
        anchorContext,
        ref,
        location: location,
        current: current,
        onNavigate: onNavigate,
        onSwitchSource: onSwitchSource,
      );
}

/// The source the server header names for [location], or null while there
/// are no switchable sources. Reads once: callers that must rebuild watch
/// [switchableSourcesProvider] themselves.
Source? currentSwitcherSource(WidgetRef ref, String location) {
  final sources = ref.read(switchableSourcesProvider);
  if (sources.isEmpty) return null;
  return SourceSwitcher.currentFor(
    sources,
    location,
    ref.read(activeSourceIdProvider),
  );
}

/// Opens the server picker anchored at [anchorContext] and acts on the
/// choice: Add, Manage, hidden-source toggle, All servers, a source or a
/// Plex Home user. Shared by the in-app header and the native iPad sidebar.
Future<void> openSourcePicker(
  BuildContext anchorContext,
  WidgetRef ref, {
  required String location,
  required Source current,
  required ValueChanged<String> onNavigate,
  ValueChanged<String>? onSwitchSource,
}) async {
  final choice = await showSourcePicker(
    anchorContext,
    currentId: isAllServersLocation(location) ? null : current.id,
  );
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
    case PickAllServers():
      (onSwitchSource ?? onNavigate)(allServersRoot);
    case PickSource(:final source) when source.account.needsReauth:
      onNavigate('/sources/add/${source.kind.name}'
          '?account=${source.account.id}');
    case PickSource(:final source):
      ref.read(selectedSourceIdProvider.notifier).select(source.id);
      (onSwitchSource ?? onNavigate)(sourceHomeLocation(source.id));
    case SwitchUser(:final account):
      await showPlexHomeSheet(
        anchorContext,
        account: account,
        serverId: current.account.id == account.id ? current.server.id : null,
        onSwitched: (id) =>
            (onSwitchSource ?? onNavigate)(sourceHomeLocation(id)),
      );
  }
}

/// The rail's server entry: the server's initial in the icon box, then its
/// name and caption beside it. Same 48px row collapsed and expanded.
class _RailSwitcher extends StatelessWidget {
  const _RailSwitcher({
    required this.name,
    required this.caption,
    required this.needsReauth,
    required this.labelsVisible,
    required this.onOpen,
  });

  final String name;
  final String? caption;
  final bool needsReauth;
  final bool labelsVisible;

  /// Receives this row's own context, which the picker's popover hangs under.
  final ValueChanged<BuildContext> onOpen;

  @override
  Widget build(BuildContext context) {
    void open() => onOpen(context);
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    const radius = BorderRadius.all(Radius.circular(14));
    final theme = Theme.of(context).textTheme;

    return Semantics(
      button: true,
      label: 'Switch server: $name',
      excludeSemantics: true,
      onTap: open,
      child: RailEntry(
        tooltip: name,
        labelsVisible: labelsVisible,
        onTap: open,
        iconBox: FocusHighlight(
          onActivate: open,
          borderRadius: radius,
          child: SizedBox(
            key: const ValueKey('source-switcher-compact'),
            child: Material(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: radius,
              child: Center(
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontFamily: AppTheme.displayFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
        label: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    key: const ValueKey('source-switcher-rail-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        theme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (caption != null)
                    Text(
                      caption!,
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
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.source,
    required this.homeUser,
    required this.onOpen,
    this.allServers = false,
  });

  final Source source;

  /// Names All servers instead of [source]: its name, a layers icon, no
  /// caption and no connection status.
  final bool allServers;

  /// The active Plex Home user, when the account has more than one.
  final String? homeUser;

  /// Receives this row's own context, which the picker's popover hangs under.
  final ValueChanged<BuildContext> onOpen;

  /// The line under the name.
  static String? _caption(Source source, String? homeUser) {
    if (source.account.needsReauth) return 'Sign in again';
    return switch (source.kind) {
      SourceKind.mydia => 'Mydia · ${source.account.displayName}',
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
    final needsReauth = !allServers && source.account.needsReauth;
    final caption = allServers ? null : _caption(source, homeUser);
    final name = allServers ? 'All servers' : source.displayName;

    return Semantics(
        button: true,
        label: 'Switch server, current: $name',
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
                      builder: (context, rawStatus) {
                        final status = allServers ? null : rawStatus;
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Icon(
                              allServers
                                  ? Icons.layers_rounded
                                  : sourceKindIcon(source.kind),
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
                        );
                      },
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
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
