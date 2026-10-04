/// "Similar in your library" for a detail screen. Mydia's rail keeps its
/// cards and their menus; Part B adds the third-party branch.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../domain/detail/detail_views.dart';
import '../../widgets/content_rail.dart';

class DetailSimilarRail extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
