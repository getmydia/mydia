/// Search across every included server, sectioned by kind.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/dock_insets.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/merged/merged_search.dart';
import '../../widgets/browse_scaffold.dart';
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
    return BrowseScaffold(
      icon: Icons.search_rounded,
      title: 'Search',
      queryKeys: const [],
      secondRow: Center(
        child: TextField(
          key: const Key('all-search-field'),
          autofocus: true,
          style: const TextStyle(fontSize: 18),
          decoration: InputDecoration(
            hintText: 'Search $count servers',
            hintStyle: TextStyle(
              color: AppColors.textSecondary.withValues(alpha: 0.6),
              fontSize: 18,
            ),
            // The app theme sets `filled: true`; the bar already draws the
            // surface, so the field is bare.
            filled: false,
            border: InputBorder.none,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            prefixIconConstraints: const BoxConstraints(minWidth: 32),
          ),
          textInputAction: TextInputAction.search,
          onChanged: notifier.query,
        ),
      ),
      body: (context, scrollTopPadding) => switch (results) {
        null => const SizedBox.shrink(),
        AsyncData(:final value) when value.value.isEmpty =>
          const Center(child: Text('Nothing found.')),
        AsyncData(:final value) => ListView(
            padding: EdgeInsets.only(
                top: scrollTopPadding, bottom: DockInsets.bottomOf(context)),
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
        AsyncError(:final error) => Padding(
            padding: EdgeInsets.only(top: scrollTopPadding),
            child: SourceErrorView(error: error, onRetry: notifier.retry),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}
