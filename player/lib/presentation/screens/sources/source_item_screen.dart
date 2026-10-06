library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/capabilities.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/source_error.dart';
import '../../../core/layout/dock_insets.dart';
import '../../widgets/source_artwork.dart';
import '../../widgets/toast/toaster.dart';
import '../detail/detail_links.dart';
import 'source_browse_providers.dart';
import 'source_error_view.dart';

class SourceItemScreen extends ConsumerWidget {
  const SourceItemScreen({super.key, required this.item});

  final ItemRef item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(sourceItemProvider(item));
    final source = ref.watch(mediaSourceProvider(item.sourceId));
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent),
      extendBodyBehindAppBar: true,
      body: switch (detail) {
        AsyncData(:final value) => ListView(
            padding: EdgeInsets.only(bottom: DockInsets.bottomOf(context)),
            children: [
              SourceBackdrop(
                sourceId: item.sourceId,
                art: value.summary.backdrop ?? value.summary.poster,
                height: 280,
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: _Body(detail: value, item: item),
              ),
              if (item.kind == ItemKind.folder) _Children(parent: item),
            ],
          ),
        AsyncError(:final error) => SourceErrorView(
            error: error,
            account: source?.source.account,
            onRetry: () => ref.invalidate(sourceItemProvider(item)),
          ),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.detail, required this.item});

  final ItemDetail detail;
  final ItemRef item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final summary = detail.summary;
    final watched =
        ref.watch(mediaSourceProvider(item.sourceId))?.as<WatchedState>();
    final version = detail.versions.firstOrNull;
    final resume = (summary.userState.progressSeconds ?? 0) > 0 &&
        !summary.userState.watched;
    final meta = [
      if (summary.subtitle != null) summary.subtitle!,
      if (summary.year != null) '${summary.year}',
      if (summary.durationSeconds != null)
        '${(summary.durationSeconds! / 60).round()} min',
      if (detail.rating != null) '★ ${detail.rating!.toStringAsFixed(1)}',
    ].join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(summary.title, style: theme.textTheme.headlineMedium),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(meta, style: theme.textTheme.bodyMedium),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            if (item.kind == ItemKind.video && version != null)
              FilledButton.icon(
                key: const Key('source-item-play'),
                autofocus: true,
                onPressed: () async {
                  await context.push(sourcePlayerLocation(
                    detail.summary.ref,
                    fileId: version.id,
                    title: detail.summary.title,
                  ));
                  if (!context.mounted) return;
                  // Progress changed while playing.
                  invalidateSourceItemWrites(ref, item);
                },
                icon: const Icon(Icons.play_arrow),
                label: Text(resume ? 'Resume' : 'Play'),
              ),
            if (watched != null)
              OutlinedButton.icon(
                key: const Key('source-item-watched'),
                onPressed: () async {
                  final toaster = Toaster.of(context);
                  try {
                    await watched.setWatched(item, !summary.userState.watched);
                  } catch (e) {
                    if (!context.mounted) return;
                    toaster.show(
                      e is SourceException
                          ? e.viewerMessage
                          : 'Could not update watched state.',
                      kind: ToastKind.error,
                    );
                    return;
                  }
                  if (!context.mounted) return;
                  invalidateSourceItemWrites(ref, item);
                },
                icon: Icon(summary.userState.watched
                    ? Icons.check_circle
                    : Icons.check_circle_outline),
                label: Text(
                    summary.userState.watched ? 'Watched' : 'Mark watched'),
              ),
          ],
        ),
        if (detail.overview case final overview? when overview.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(overview, style: theme.textTheme.bodyLarge),
        ],
        if (detail.genres.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(detail.genres.join(', '), style: theme.textTheme.bodySmall),
        ],
        if (detail.people.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(detail.people.take(8).join(', '),
              style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}

class _Children extends ConsumerWidget {
  const _Children({required this.parent});

  final ItemRef parent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final children = ref.watch(sourceChildrenProvider(parent));
    return switch (children) {
      AsyncData(:final value) => Column(
          children: [
            for (final child in value)
              ListTile(
                key: ValueKey('source-child-${child.ref.externalId}'),
                title: Text(child.title),
                subtitle: child.subtitle == null ? null : Text(child.subtitle!),
                trailing: child.userState.watched
                    ? const Icon(Icons.check_circle, size: 18)
                    : null,
                onTap: () => context.push(sourceItemLocation(child.ref)),
              ),
          ],
        ),
      AsyncError(:final error) => SourceErrorView(
          error: error,
          onRetry: () => ref.invalidate(sourceChildrenProvider(parent)),
        ),
      _ => const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
    };
  }
}
