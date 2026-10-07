/// Every included server's collections, each captioned with its server.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/sources/collection.dart';
import '../../widgets/collection_card.dart';
import '../sources/source_drawer_button.dart';
import '../sources/source_error_view.dart';
import '../sources/source_listing_screen.dart' show SourceEmptyState;
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
              _ when collections.isEmpty => const SourceEmptyState(
                  key: Key('all-collections-empty'),
                  title: 'Nothing here yet.',
                ),
              _ => RefreshIndicator(
                  onRefresh: () async {
                    ref.invalidate(allServersCollectionsProvider);
                    await ref.read(allServersCollectionsProvider.future);
                  },
                  child: CollectionsGrid(
                    collections: collections,
                    scrollTopPadding: 8,
                    captionFor: (c) => names[c.sourceId],
                  ),
                ),
            },
          ),
        ],
      ),
    );
  }
}
