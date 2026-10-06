/// The "More like this" row of a detail screen: the items its source's
/// `Similar` capability names, as a poster row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/mydia/bound_mydia.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../sources/source_poster_row.dart';
import 'source_detail_controllers.dart';

class DetailSimilarRail extends ConsumerWidget {
  const DetailSimilarRail({
    super.key,
    this.movie,
    this.show,
  });

  final MovieView? movie;
  final ShowView? show;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = movie?.target ?? show?.target;
    if (target == null) return const SizedBox.shrink();
    final item = itemRefOf(target, ref.watch(boundSourceIdProvider));
    final items = ref.watch(sourceSimilarProvider(item)).value;
    if (items == null || items.isEmpty) return const SizedBox.shrink();
    return SourcePosterRow(
      title: 'More like this',
      railId: 'similar',
      items: items,
    );
  }
}
