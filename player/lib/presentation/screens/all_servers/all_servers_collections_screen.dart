/// Every included server's collections, each captioned with its server.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/layout/dock_insets.dart';
import '../../../core/sources/source.dart';
import '../../../domain/sources/collection.dart';
import '../../widgets/collection_card.dart';
import '../detail/detail_links.dart';
import '../sources/source_drawer_button.dart';
import '../sources/source_error_view.dart';
import 'all_servers_banner.dart';
import 'all_servers_providers.dart';

class AllServersCollectionsScreen extends ConsumerWidget {
  const AllServersCollectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(allServersCollectionsProvider);
    final names = ref.watch(allServersNamesProvider);
    final merged = result.value;
    final collections = [
      for (final c in merged?.value ?? const <SourceCollection>[])
        if (names.containsKey(c.sourceId)) c
    ];
    void retry() => ref.invalidate(allServersCollectionsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: SourceDrawerButton.maybe(context),
        title: const Text('Collections'),
      ),
      body: Column(
        children: [
          if (merged != null)
            AllServersBanner(unavailable: merged.unavailable, onRetry: retry),
          Expanded(
            child: switch (result) {
              AsyncError(:final error) when merged == null =>
                SourceErrorView(error: error, onRetry: retry),
              _ when merged == null =>
                const Center(child: CircularProgressIndicator()),
              _ => RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(allServersCollectionsProvider);
                    await ref.read(allServersCollectionsProvider.future);
                  },
                  child: _grid(context, collections, names),
                ),
            },
          ),
        ],
      ),
    );
  }

  Widget _grid(BuildContext context, List<SourceCollection> collections,
      Map<SourceId, String> names) {
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final cardSpacing = Breakpoints.getCardSpacing(context);
    final bottomPadding = DockInsets.bottomOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = width > 1400
            ? 6
            : width > 1200
                ? 5
                : width > 1000
                    ? 4
                    : width > 800
                        ? 3
                        : 2;
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(
              horizontalPadding, 8, horizontalPadding, bottomPadding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 0.85,
            crossAxisSpacing: cardSpacing,
            mainAxisSpacing: cardSpacing,
          ),
          itemCount: collections.length,
          itemBuilder: (context, index) {
            final c = collections[index];
            return CollectionCard(
              key: ValueKey('${c.sourceId.value}-${c.id}'),
              collection: c,
              caption: names[c.sourceId],
              onTap: () => context.push(collectionLocation(c.sourceId, c.id)),
            );
          },
        );
      },
    );
  }
}
