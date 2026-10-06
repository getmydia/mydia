/// The All servers home: Continue Watching and Recently Added from every
/// included server.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/dock_insets.dart';
import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/source_error.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/freshness_header.dart';
import '../../widgets/media_context_menu.dart';
import '../../widgets/toast/toaster.dart';
import '../../widgets/window_chrome/window_title_row.dart';
import '../home/home_loading_skeleton.dart';
import '../sources/source_continue_watching_row.dart'
    show continueWatchingCaption;
import '../sources/home_header.dart';
import '../sources/source_error_view.dart';
import '../sources/source_poster_row.dart';
import 'all_servers_banner.dart';
import 'all_servers_cards.dart';
import 'all_servers_providers.dart';

class AllServersHomeScreen extends ConsumerWidget {
  const AllServersHomeScreen({super.key});

  void _refresh(WidgetRef ref) {
    ref.invalidate(allServersContinueWatchingProvider);
    ref.invalidate(allServersRecentlyAddedProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    publishBackdropSource(ref, BackdropSource.none);
    // The title row draws into the window band, so the body sits under
    // `removeBand` or the band is counted twice.
    return WindowChromeInsets.removeBand(
      child: Builder(builder: (context) {
        // Read above the Scaffold: inside `extendBodyBehindAppBar` Flutter
        // rewrites padding.top to the bar's bottom edge.
        final chromeTop = freshnessTopInset(context,
            appBarHeight: WindowTitleRow.heightOf(context));
        return Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          appBar: homeHeader(
            context,
            mobileTitle: const HomeMydiaLockup(),
            onSearch: () => context.go(allServersSearchLocation),
          ),
          body: _body(context, ref, chromeTop),
        );
      }),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, double chromeTop) {
    final resuming = ref.watch(allServersContinueWatchingProvider);
    final recent = ref.watch(allServersRecentlyAddedProvider);
    if (!resuming.hasValue || !recent.hasValue) {
      return const HomeLoadingSkeleton();
    }
    final r = resuming.requireValue, n = recent.requireValue;
    final included = ref.watch(allServersNamesProvider);
    final continueItems = stillIncluded(included, r.value);
    final recentItems = stillIncluded(included, n.value);
    final everyServer = ref.watch(allServersSourcesProvider).length;
    final unavailable = {...r.unavailable, ...n.unavailable}.toList();
    // Zero included servers is nothing to show, not every server failing.
    if (everyServer > 0 && unavailable.length >= everyServer) {
      return Padding(
        padding: EdgeInsets.only(top: chromeTop),
        child: SourceErrorView(
            error: const SourceException.unreachable(),
            onRetry: () => _refresh(ref)),
      );
    }
    return RefreshIndicator(
      edgeOffset: chromeTop,
      onRefresh: () async => _refresh(ref),
      child: ListView(
        key: const Key('all-servers-home'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
            0, chromeTop + 16, 0, DockInsets.bottomOf(context)),
        children: [
          AllServersBanner(
              unavailable: unavailable, onRetry: () => _refresh(ref)),
          if (continueItems.isNotEmpty)
            SourcePosterRow(
              key: const Key('all-continue-watching'),
              title: 'Continue Watching',
              railId: 'all-continue',
              items: continueItems,
              posterFor: (context, item) => AllServersPoster(
                item: item,
                caption: continueWatchingCaption(item),
                onContextMenu: (c) => _menu(c, ref, item),
              ),
            ),
          if (recentItems.isNotEmpty)
            SourcePosterRow(
              key: const Key('all-recently-added'),
              title: 'Recently Added',
              railId: 'all-recent',
              items: recentItems,
              posterFor: (context, item) => AllServersPoster(item: item),
            ),
          if (continueItems.isEmpty && recentItems.isEmpty)
            const Padding(
              padding: EdgeInsets.all(48),
              child: Center(child: Text('Nothing to show yet.')),
            ),
        ],
      ),
    );
  }

  Future<void> _menu(BuildContext c, WidgetRef ref, ItemSummary item) async {
    final source = ref
        .read(allServersSourcesProvider)
        .where((s) => s.id == item.ref.sourceId)
        .firstOrNull;
    final cw = source?.as<ContinueWatching>();
    final removable = cw?.canRemoveFromContinueWatching(item) ?? false;
    final position = popupPositionBelow(c);
    if (position == null) return;
    final choice = await showMenu<String>(
      context: c,
      position: position,
      items: [
        const PopupMenuItem(
            key: Key('all-continue-details'),
            value: 'details',
            child: Text('Details')),
        if (removable)
          const PopupMenuItem(
              key: Key('all-continue-remove'),
              value: 'remove',
              child: Text('Remove from Continue Watching')),
      ],
    );
    if (choice == null || !c.mounted) return;
    switch (choice) {
      case 'details':
        await c.push(allServersItemLocation(item.ref));
      case 'remove':
        if (cw == null) return;
        final toaster = Toaster.of(c);
        try {
          await cw.removeFromContinueWatching(item.dismissRef);
        } catch (e) {
          toaster.show(
            e is SourceException
                ? e.viewerMessage
                : 'Could not remove this title.',
            kind: ToastKind.error,
          );
          return;
        }
        ref.invalidate(allServersContinueWatchingProvider);
    }
  }
}
