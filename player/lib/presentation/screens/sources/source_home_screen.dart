library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/dock_insets.dart';
import '../../../core/layout/window_chrome_inset.dart';
import '../../widgets/window_chrome/window_title_row.dart';
import '../../../core/sources/cache/source_keys.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/startup/startup_timeline.dart';
import '../../../domain/sources/hub.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/freshness_header.dart';
import '../detail/detail_links.dart';
import 'source_browse_providers.dart';
import 'source_continue_watching_row.dart';
import 'source_home_hero.dart';
import 'source_drawer_button.dart';
import 'source_error_view.dart';
import 'source_poster_row.dart';

class SourceHomeScreen extends ConsumerWidget {
  const SourceHomeScreen({super.key, required this.sourceId});

  final SourceId sourceId;

  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(sourceContinueWatchingProvider(sourceId));
    ref.invalidate(sourceHubsProvider(sourceId));
    ref.invalidate(sourceLibraryPreviewProvider);
    ref.invalidate(sourceLibrariesProvider(sourceId));
    try {
      await ref.read(sourceLibrariesProvider(sourceId).future);
    } catch (_) {
      // The screen shows the error; the indicator only has to stop.
    }
  }

  /// The first Continue Watching item, else the first item of the first hub.
  /// A failed or loading row has no value and falls through.
  ItemSummary? _heroItem(WidgetRef ref) {
    final resuming = ref.watch(sourceContinueWatchingProvider(sourceId));
    if (resuming.value?.firstOrNull case final item?) return item;
    final hubs = ref.watch(sourceHubsProvider(sourceId)).value;
    for (final hub in hubs ?? const <Hub>[]) {
      if (hub.items.firstOrNull case final item?) return item;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libraries = ref.watch(sourceLibrariesProvider(sourceId));
    final hero = _heroItem(ref);
    if (libraries.hasValue) {
      StartupTimeline.app
        ..mark('home_first_data')
        ..logOnce();
    }
    // Nothing to feature, or nothing to show yet: the calm static backdrop.
    if (hero == null || !libraries.hasValue) {
      publishBackdropSource(ref, BackdropSource.none);
    }
    // The title row draws into the window band on every platform, so the body
    // sits under `removeBand` or the band is counted twice.
    return WindowChromeInsets.removeBand(
      child: Builder(builder: (context) => _scaffold(context, ref, libraries)),
    );
  }

  /// The title bar that hosts the cast button and the window drag band.
  /// A `@visibleForTesting` seam so the cast alignment test needs no
  /// providers: this is the exact widget the screen puts in `appBar`.
  @visibleForTesting
  static PreferredSizeWidget header(BuildContext context) =>
      WindowTitleBar(height: WindowTitleRow.heightOf(context));

  Widget _scaffold(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<Library>> libraries,
  ) {
    final source = ref.watch(mediaSourceProvider(sourceId));
    final hero = _heroItem(ref);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: header(context),
      body: SafeArea(
        top: false,
        child: switch (libraries) {
          AsyncData(:final value) => Column(
              children: [
                FreshnessHeader(queryKeys: [
                  SourceKeys.libraries(sourceId),
                  SourceKeys.continueWatching(sourceId),
                  SourceKeys.hubs(sourceId),
                ]),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () => _refresh(ref),
                    child: ListView(
                      key: const Key('source-home-list'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                          0, 16, 0, DockInsets.bottomOf(context)),
                      children: [
                        _Header(
                            title: source?.displayName ?? 'Server',
                            sourceId: sourceId,
                            searchable: source?.as<Searchable>() != null),
                        if (hero != null)
                          SourceHomeHero(
                            key: ValueKey(
                                'source-home-hero-${hero.ref.externalId}'),
                            sourceId: sourceId,
                            item: hero,
                          ),
                        SourceContinueWatchingRow(sourceId: sourceId),
                        _Rows(sourceId: sourceId, libraries: value),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          AsyncError(:final error) => Column(
              children: [
                _Header(
                    title: source?.displayName ?? 'Server',
                    sourceId: sourceId,
                    searchable: false),
                Expanded(
                  child: SourceErrorView(
                    error: error,
                    account: source?.source.account,
                    onRetry: () =>
                        ref.invalidate(sourceLibrariesProvider(sourceId)),
                  ),
                ),
              ],
            ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.sourceId,
    required this.searchable,
  });

  final bool searchable;
  final String title;
  final SourceId sourceId;

  @override
  Widget build(BuildContext context) {
    final drawerButton = SourceDrawerButton.maybe(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          if (drawerButton != null) drawerButton,
          Expanded(
            child:
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
          ),
          if (searchable)
            IconButton(
              key: const Key('source-open-search'),
              icon: const Icon(Icons.search),
              onPressed: () => context.push(sourceSearchLocation(sourceId)),
            ),
        ],
      ),
    );
  }
}

/// The server's hubs when it has them, else one row per library. A hub
/// failure falls back to the libraries; a refresh keeps the old hubs on
/// screen until the new ones land.
class _Rows extends ConsumerWidget {
  const _Rows({required this.sourceId, required this.libraries});

  final SourceId sourceId;
  final List<Library> libraries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hubs = ref.watch(sourceHubsProvider(sourceId));
    final list = hubs.hasValue ? hubs.requireValue : null;
    if (list != null && list.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final hub in list)
            SourcePosterRow(
              key: ValueKey('source-hub-${hub.id}'),
              title: hub.title,
              titleKey: Key('source-hub-row-${hub.id}'),
              railId: 'hub-${hub.id}',
              items: hub.items,
              onTitleTap: switch (hub.library) {
                final library? => () =>
                    context.push(sourceLibraryLocation(library)),
                null => null,
              },
            ),
        ],
      );
    }
    if (hubs.isLoading && list == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final library in libraries) _LibraryRow(library: library),
      ],
    );
  }
}

class _LibraryRow extends ConsumerWidget {
  const _LibraryRow({required this.library});

  final Library library;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(sourceLibraryPreviewProvider(library.ref));
    return SourcePosterRow(
      title: library.title,
      titleKey: Key('source-library-row-${library.ref.id}'),
      railId: library.ref.id,
      items: switch (preview) {
        AsyncData(:final value) => value,
        _ => const <ItemSummary>[],
      },
      onTitleTap: () => context.push(sourceLibraryLocation(library.ref)),
    );
  }
}
