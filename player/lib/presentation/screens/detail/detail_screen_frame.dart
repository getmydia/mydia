import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/theme/ambient_tint/ambient_tint.dart';
import '../../../domain/detail/detail_art.dart';
import '../../../domain/detail/detail_target.dart';
import '../../widgets/freshness_header.dart';
import '../../widgets/shell_rail_inset.dart';
import 'detail_providers.dart';
import 'detail_states.dart';
import 'detail_tint_scope.dart';

/// The page frame every detail screen shares.
///
/// A detail screen renders inside the shell, with the floating rail over it
/// (or the phone bottom bar below it). The shell gives it the full width: its
/// ground and hero art run to the window's left edge under the rail, and the
/// content is inset by `ShellRailInset` (see `SliverRailInset`). Like every
/// other in-shell page it draws its own title row into the title-bar band, so
/// the body has to sit under `removeBand`, or the ambient
/// `MediaQuery.padding.top` still carries the band on top of the hero's own
/// title row a second time. The shell narrows `WindowChromeInsets` to the
/// column (`AppShell.contentInsets`), so the back button clears the window
/// controls only where the rail does not already.
class DetailScreenFrame<T> extends StatelessWidget {
  const DetailScreenFrame({
    super.key,
    required this.target,
    required this.value,
    required this.noun,
    required this.onRetry,
    required this.builder,
    this.tintArt,
  });

  /// The artwork this screen takes its tint from, once data has loaded.
  final DetailArt? Function(T data)? tintArt;

  final DetailTarget target;
  final AsyncValue<T> value;

  /// Named in the error state: "Failed to load [noun]".
  final String noun;
  final VoidCallback onRetry;
  final Widget Function(BuildContext context, T data) builder;

  @override
  Widget build(BuildContext context) {
    final art = switch (value) {
      AsyncData(:final value) => tintArt?.call(value),
      _ => null,
    };
    return WindowChromeInsets.removeBand(
      child: DetailTintScope(
        art: art,
        child: Builder(
          builder: (context) => Scaffold(
            backgroundColor: AmbientTint.of(context).ground,
            extendBodyBehindAppBar: true,
            body: Column(
              children: [
                ShellPageInset(
                  child: FreshnessHeader(
                    queryKeys: freshnessKeys(target),
                    topInset: freshnessTopInset(context, appBarHeight: 0),
                  ),
                ),
                Expanded(
                  child: value.when(
                    data: (data) => builder(context, data),
                    loading: () => const DetailLoadingState(),
                    error: (error, _) => DetailErrorState(
                      noun: noun,
                      error: error,
                      onRetry: onRetry,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
