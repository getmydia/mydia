/// "Similar in your library" for a detail screen. Mydia's rail keeps its
/// cards and their menus; a source's items come from its `Similar`
/// capability and render as a poster row.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../../widgets/content_rail.dart';
import '../sources/source_poster_row.dart';
import 'source_detail_controllers.dart';

class DetailSimilarRail extends ConsumerWidget {
  const DetailSimilarRail({
    super.key,
    this.movie,
    this.show,
    this.collapsible = false,
  });

  final MovieView? movie;
  final ShowView? show;
  final bool collapsible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = movie?.target ?? show?.target;
    if (target is SourceTarget) {
      final items = ref.watch(sourceSimilarProvider(target.ref)).value;
      if (items == null || items.isEmpty) return const SizedBox.shrink();
      return SourcePosterRow(
        title: 'More like this',
        railId: 'similar',
        items: items,
      );
    }
    final similar = movie?.mydia?.similar ?? show?.mydia?.similar ?? const [];
    if (similar.isEmpty) return const SizedBox.shrink();
    return ContentRail(
      title: 'Similar in your library',
      collapsible: collapsible,
      items: similar,
      onItemTap: (id, type) => context.push(
        type.toLowerCase() == 'movie' ? '/movie/$id' : '/show/$id',
      ),
    );
  }
}
