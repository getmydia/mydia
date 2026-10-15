/// A season or episode link opens its show: on that season, and for an
/// episode with the episode selected in the hero.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/source_error.dart';
import '../../widgets/window_chrome/window_title_row.dart';
import '../../widgets/shell_rail_inset.dart';
import '../show/show_detail_screen.dart';
import 'source_browse_providers.dart';
import 'source_error_view.dart';

class SourceShowSelectionRoute extends ConsumerWidget {
  const SourceShowSelectionRoute({super.key, required this.item});

  /// A season or an episode.
  final ItemRef item;

  bool get _isEpisode => item.kind == ItemKind.episode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(sourceItemProvider(item));
    final source = ref.watch(mediaSourceProvider(item.sourceId));
    // A detail location gets the full width; the fallback states sit beside
    // the rail rather than under it.
    Widget failed(Object error) => ShellPageInset(
          child: WindowChromeInsets.removeBand(
            child: Builder(
              builder: (context) => Scaffold(
                appBar: WindowTitleBar.back(context),
                body: SourceErrorView(
                  error: error,
                  account: source?.source.account,
                  onRetry: () => ref.invalidate(sourceItemProvider(item)),
                ),
              ),
            ),
          ),
        );
    return switch (detail) {
      AsyncData(:final value) when value.show != null =>
        ShowDetailScreen.target(
          target: SourceTarget(value.show!),
          initialSeason:
              _isEpisode ? value.summary.parentIndex : value.summary.index,
          initialEpisode: _isEpisode ? item.externalId : null,
        ),
      AsyncData() => failed(const SourceException.notFound()),
      AsyncError(:final error) => failed(error),
      _ => const ShellPageInset(
          child: Scaffold(body: Center(child: CircularProgressIndicator())),
        ),
    };
  }
}
