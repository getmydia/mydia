/// A season link opens its show on that season.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/sources_providers.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/source_error.dart';
import '../show/show_detail_screen.dart';
import 'source_browse_providers.dart';
import 'source_error_view.dart';

class SourceSeasonRoute extends ConsumerWidget {
  const SourceSeasonRoute({super.key, required this.season});

  final ItemRef season;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(sourceItemProvider(season));
    final source = ref.watch(mediaSourceProvider(season.sourceId));
    return switch (detail) {
      AsyncData(:final value) when value.show != null =>
        ShowDetailScreen.target(
          target: SourceTarget(value.show!),
          initialSeason: value.summary.index,
        ),
      AsyncData() => Scaffold(
          appBar: AppBar(backgroundColor: Colors.transparent),
          body: SourceErrorView(
            error: const SourceException.notFound(),
            account: source?.source.account,
            onRetry: () => ref.invalidate(sourceItemProvider(season)),
          ),
        ),
      AsyncError(:final error) => Scaffold(
          appBar: AppBar(backgroundColor: Colors.transparent),
          body: SourceErrorView(
            error: error,
            account: source?.source.account,
            onRetry: () => ref.invalidate(sourceItemProvider(season)),
          ),
        ),
      _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
    };
  }
}
