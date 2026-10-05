/// Search across every included server, sectioned by kind.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/dock_insets.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/merged/merged_search.dart';
import '../sources/source_drawer_button.dart';
import '../sources/source_error_view.dart';
import '../sources/source_poster_row.dart';
import 'all_servers_banner.dart';
import 'all_servers_cards.dart';
import 'all_servers_providers.dart';

String _sectionTitle(MergedSection s) => switch (s) {
      MergedSection.movies => 'Movies',
      MergedSection.shows => 'Shows',
      MergedSection.episodes => 'Episodes',
      MergedSection.videos => 'Videos',
    };

class AllServersSearchScreen extends ConsumerWidget {
  const AllServersSearchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(allServersSearchProvider);
    final notifier = ref.read(allServersSearchProvider.notifier);
    final count = ref
        .watch(allServersSourcesProvider)
        .where((s) => s.as<Searchable>() != null)
        .length;
    return Scaffold(
      appBar: AppBar(
        leading: SourceDrawerButton.maybe(context),
        title: TextField(
          key: const Key('all-search-field'),
          autofocus: true,
          decoration: InputDecoration(hintText: 'Search $count servers'),
          onChanged: notifier.query,
        ),
      ),
      body: switch (results) {
        null => const SizedBox.shrink(),
        AsyncData(:final value) when value.value.isEmpty =>
          const Center(child: Text('Nothing found.')),
        AsyncData(:final value) => ListView(
            padding: EdgeInsets.only(bottom: DockInsets.bottomOf(context)),
            children: [
              AllServersBanner(
                  unavailable: value.unavailable, onRetry: notifier.retry),
              for (final entry in value.value.sections.entries)
                SourcePosterRow(
                  key: Key('all-search-section-${entry.key.name}'),
                  title: _sectionTitle(entry.key),
                  railId: 'all-search-${entry.key.name}',
                  items: entry.value,
                  posterFor: (context, item) => AllServersPoster(item: item),
                ),
            ],
          ),
        AsyncError(:final error) =>
          SourceErrorView(error: error, onRetry: notifier.retry),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}
