library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/dock_insets.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/library.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/horizontal_rail.dart';
import '../../widgets/source_artwork.dart';
import 'source_browse_providers.dart';
import 'source_error_view.dart';

class SourceHomeScreen extends ConsumerWidget {
  const SourceHomeScreen({super.key, required this.sourceId});

  final SourceId sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(mediaSourceProvider(sourceId));
    final libraries = ref.watch(sourceLibrariesProvider(sourceId));
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: switch (libraries) {
          AsyncData(:final value) => ListView(
              padding:
                  EdgeInsets.fromLTRB(0, 16, 0, DockInsets.bottomOf(context)),
              children: [
                _Header(
                    title: source?.displayName ?? 'Server',
                    sourceId: sourceId,
                    searchable: source?.as<Searchable>() != null),
                for (final library in value) _LibraryRow(library: library),
              ],
            ),
          AsyncError(:final error) => Column(
              children: [
                _Header(
                    title: source?.displayName ?? 'Server',
                    sourceId: sourceId,
                    searchable: false),
                Expanded(
                  child: SourceErrorView(
                    error: error,
                    account: source?.source.account,
                    onRetry: () =>
                        ref.invalidate(sourceLibrariesProvider(sourceId)),
                  ),
                ),
              ],
            ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.sourceId,
    required this.searchable,
  });

  final bool searchable;
  final String title;
  final SourceId sourceId;

  @override
  Widget build(BuildContext context) {
    // The mobile shell's scaffold exists only in the narrow layout; there it
    // owns the drawer that holds this source's navigation.
    final mobileShell = AppShell.scaffoldKey.currentState;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          if (mobileShell != null)
            IconButton(
              key: const Key('source-open-drawer'),
              icon: const Icon(Icons.menu),
              onPressed: mobileShell.openDrawer,
            ),
          Expanded(
            child:
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
          ),
          if (searchable)
            IconButton(
              key: const Key('source-open-search'),
              icon: const Icon(Icons.search),
              onPressed: () => context.push('/s/${sourceId.value}/search'),
            ),
        ],
      ),
    );
  }
}

class _LibraryRow extends ConsumerWidget {
  const _LibraryRow({required this.library});

  final Library library;

  static const _posterWidth = 140.0;
  static const _rowHeight = 250.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(sourceLibraryPreviewProvider(library.ref));
    final items = switch (preview) {
      AsyncData(:final value) => value,
      _ => const [],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: Key('source-library-row-${library.ref.id}'),
          onTap: () => context.push(
              '/s/${library.ref.sourceId.value}/library/${Uri.encodeComponent(library.ref.id)}'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text(library.title,
                    style: Theme.of(context).textTheme.titleLarge),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
        SizedBox(
          height: _rowHeight,
          child: HorizontalRail(
            itemCount: items.length,
            height: _rowHeight,
            leftFadeKey: Key('source-rail-left-${library.ref.id}'),
            rightFadeKey: Key('source-rail-right-${library.ref.id}'),
            itemBuilder: (context, index) {
              final item = items[index];
              return SizedBox(
                width: _posterWidth,
                child: SourcePoster(
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
