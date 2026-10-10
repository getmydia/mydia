import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/window_chrome_inset.dart';
import '../../../domain/detail/detail_target.dart';
import '../../widgets/freshness_header.dart';
import 'detail_providers.dart';
import 'detail_states.dart';

/// The page frame every detail screen shares.
///
/// A detail screen is a full-window route (pushed outside the shell), and so
/// the sole owner of the title-bar band: the body has to sit under
/// `removeBand`, or the ambient `MediaQuery.padding.top` still carries the
/// band on top of the hero's own title row a second time.
class DetailScreenFrame<T> extends StatelessWidget {
  const DetailScreenFrame({
    super.key,
    required this.target,
    required this.value,
    required this.noun,
    required this.onRetry,
    required this.builder,
  });

  final DetailTarget target;
  final AsyncValue<T> value;

  /// Named in the error state: "Failed to load [noun]".
  final String noun;
  final VoidCallback onRetry;
  final Widget Function(BuildContext context, T data) builder;

  @override
  Widget build(BuildContext context) {
    return WindowChromeInsets.removeBand(
      child: Scaffold(
        extendBodyBehindAppBar: true,
        body: Column(
          children: [
            FreshnessHeader(
              queryKeys: freshnessKeys(target),
              topInset: freshnessTopInset(context, appBarHeight: 0),
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
    );
  }
}
