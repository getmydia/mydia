/// One titled rail of posters on a source's home: a library preview, a
/// server hub or Continue Watching.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../domain/sources/item.dart';
import '../../widgets/horizontal_rail.dart';
import '../../widgets/source_artwork.dart';
import 'source_browse_providers.dart';

class SourcePosterRow extends StatelessWidget {
  const SourcePosterRow({
    super.key,
    required this.title,
    required this.railId,
    required this.items,
    this.titleKey,
    this.onTitleTap,
    this.posterFor,
  });

  static const posterWidth = 140.0;
  static const rowHeight = 250.0;

  final String title;

  /// Tells this rail's fade keys apart from the other rails on the screen.
  final String railId;
  final List<ItemSummary> items;
  final Key? titleKey;

  /// Null renders the title as plain text, with no chevron.
  final VoidCallback? onTitleTap;

  /// Builds each poster. Null builds one that opens the item's screen.
  final Widget Function(BuildContext context, ItemSummary item)? posterFor;

  @override
  Widget build(BuildContext context) {
    final heading = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (onTitleTap != null) const Icon(Icons.chevron_right),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onTitleTap case final onTap?)
          InkWell(key: titleKey, onTap: onTap, child: heading)
        else
          KeyedSubtree(key: titleKey, child: heading),
        SizedBox(
          height: rowHeight,
          child: HorizontalRail(
            itemCount: items.length,
            height: rowHeight,
            leftFadeKey: Key('source-rail-left-$railId'),
            rightFadeKey: Key('source-rail-right-$railId'),
            itemBuilder: (context, index) {
              final item = items[index];
              return SizedBox(
                width: posterWidth,
                child: posterFor?.call(context, item) ??
                    SourcePoster(
                      key: ValueKey('source-poster-${item.ref.externalId}'),
                      item: item,
                      onTap: () => context.push(sourceItemLocation(item.ref)),
                    ),
              );
            },
          ),
        ),
      ],
    );
  }
}
