/// The similar-titles row of a detail screen: the items its source's
/// `Similar` capability names, as a poster row.
///
/// A show's row is supporting context rather than the reason the screen was
/// opened, so it starts collapsed behind a disclosure header and builds none
/// of its posters until asked. A movie's row is always open.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/colors.dart';
import '../../../domain/detail/detail_views.dart';
import '../sources/source_poster_row.dart';
import 'source_detail_controllers.dart';

class DetailSimilarRail extends ConsumerStatefulWidget {
  const DetailSimilarRail({super.key, this.movie, this.show});

  final MovieView? movie;
  final ShowView? show;

  /// Test and lookup handle for the disclosure chevron.
  static const disclosureKey = ValueKey('content-rail-disclosure');

  @override
  ConsumerState<DetailSimilarRail> createState() => _DetailSimilarRailState();
}

class _DetailSimilarRailState extends ConsumerState<DetailSimilarRail> {
  static const _disclosureDuration = Duration(milliseconds: 220);

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final target = widget.movie?.target ?? widget.show?.target;
    if (target == null) return const SizedBox.shrink();
    final items = ref.watch(sourceSimilarProvider(target.ref)).value;
    if (items == null || items.isEmpty) return const SizedBox.shrink();

    if (widget.movie != null) {
      return SourcePosterRow(
        title: 'More like this',
        railId: 'similar',
        items: items,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: _expanded,
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                letterSpacing: -0.3,
                              ),
                    ),
                  ),
                  AnimatedRotation(
                    key: DetailSimilarRail.disclosureKey,
                    turns: _expanded ? 0.5 : 0,
                    duration: _disclosureDuration,
                    curve: Curves.easeOutCubic,
                    child: const Icon(
                      Icons.expand_more_rounded,
                      size: 26,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: _disclosureDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? SourcePosterRow(
                  title: _title,
                  railId: 'similar',
                  items: items,
                  showHeading: false,
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
      ],
    );
  }

  static const _title = 'Similar in your library';
}
