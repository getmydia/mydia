import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/navigation/media_filter.dart';
import '../../../domain/navigation/nav_destination.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../filter/filter_editor_sheet.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/cast_actions.dart';
import '../../widgets/cast_button.dart';
import '../../widgets/freshness_header.dart';
import '../../widgets/glass_surface.dart';
import '../library/library_grid_body.dart';

class FilterScreen extends ConsumerStatefulWidget {
  final String filterId;

  const FilterScreen({
    super.key,
    required this.filterId,
  });

  @override
  ConsumerState<FilterScreen> createState() => _FilterScreenState();
}

class _FilterScreenState extends ConsumerState<FilterScreen> {
  final ScrollController _scrollController = ScrollController();
  LibraryViewMode _viewMode = LibraryViewMode.grid;

  static const double _barHeight = kToolbarHeight;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _toggleViewMode() {
    setState(() {
      _viewMode = _viewMode == LibraryViewMode.grid
          ? LibraryViewMode.list
          : LibraryViewMode.grid;
    });
  }

  @override
  Widget build(BuildContext context) {
    final layoutAsync = ref.watch(sidebarLayoutProvider);
    final isDesktop = Breakpoints.isDesktop(context);
    final chromeTop = freshnessTopInset(context, appBarHeight: _barHeight);
    final scrollTopPadding = chromeTop + 8;

    publishBackdropSource(ref, BackdropSource.none);

    return layoutAsync.when(
      loading: () => const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(child: Text(error.toString())),
      ),
      data: (layout) {
        final destination = layout.filters[widget.filterId];
        if (destination == null) {
          return const Scaffold(
            backgroundColor: Colors.transparent,
            body: _FilterNotFoundBody(),
          );
        }

        final filter = destination.filter;
        final emptyCopy = _emptyCopyFor(filter);

        return Scaffold(
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
          appBar: _buildAppBar(
            context,
            destination,
            isDesktop,
          ),
          body: LibraryMediaBody(
            filter: filter,
            scrollController: _scrollController,
            chromeTop: chromeTop,
            scrollTopPadding: scrollTopPadding,
            viewMode: _viewMode,
            emptyTitle: emptyCopy.title,
            emptySubtitle: emptyCopy.subtitle,
            emptyIcon: emptyCopy.icon,
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    FilterDestination destination,
    bool isDesktop,
  ) {
    final title = destination.label;
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);

    return PreferredSize(
      preferredSize: const Size.fromHeight(_barHeight),
      child: GlassSurface.appBar(
        opacity: 0.85,
        child: SafeArea(
          child: SizedBox(
            height: kToolbarHeight,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isDesktop ? horizontalPadding - 8 : 8,
              ),
              child: Row(
                children: [
                  if (!isDesktop)
                    IconButton(
                      icon: const Icon(Icons.menu_rounded),
                      onPressed: () {
                        AppShell.scaffoldKey.currentState?.openDrawer();
                      },
                      tooltip: 'Menu',
                    ),
                  Padding(
                    padding: EdgeInsets.only(left: isDesktop ? 8 : 0),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.filter_alt_rounded,
                          color: AppColors.primary,
                          size: 24,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          title,
                          style: Theme.of(context)
                              .textTheme
                              .headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                                letterSpacing: -0.3,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  _FilterActionButton(
                    icon: _viewMode == LibraryViewMode.grid
                        ? Icons.view_list_rounded
                        : Icons.grid_view_rounded,
                    onPressed: _toggleViewMode,
                    tooltip: 'Toggle view',
                  ),
                  const SizedBox(width: 4),
                  PopupMenuButton<String>(
                    icon: const Icon(
                      Icons.more_vert_rounded,
                      color: AppColors.textSecondary,
                      size: 22,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    color: AppColors.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    onSelected: (value) {
                      if (value == 'save_filter') {
                        showFilterEditor(
                          context: context,
                          ref: ref,
                          initialFilter: destination.filter,
                        );
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                        value: 'save_filter',
                        child: Text('Save this view as a filter'),
                      ),
                    ],
                  ),
                  const SizedBox(width: 4),
                  CastButton(
                    onPressed: () => pickCastDevice(context, ref),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  ({String title, String subtitle, IconData icon}) _emptyCopyFor(
    MediaFilter filter,
  ) {
    if (filter.kind == MediaKind.movies) {
      return (
        title: 'No movies yet',
        subtitle: 'Add content to your library to see it here',
        icon: Icons.movie_filter_rounded,
      );
    }
    return (
      title: 'No TV shows yet',
      subtitle: 'Add content to your library to see it here',
      icon: Icons.live_tv_rounded,
    );
  }
}

class _FilterNotFoundBody extends StatelessWidget {
  const _FilterNotFoundBody();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'This filter no longer exists.',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.go('/'),
              child: const Text('Go home'),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  const _FilterActionButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppColors.surfaceVariant.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onPressed,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 20,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
