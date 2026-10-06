/// The title bar both homes draw: a source's home and the All servers home.
///
/// One builder so the two cannot drift. On desktop the bar is transparent
/// and empty apart from the cast button: the hero is the identity there, and
/// the screen extends its body behind the bar. On a phone it is glass, with
/// the drawer button, a title and a search pill, as the pre-unification
/// Mydia home built it.
library;

import 'package:flutter/material.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/colors.dart';
import '../../widgets/channel_badge.dart';
import '../../widgets/glass_surface.dart';
import '../../widgets/mydia_logo.dart';
import '../../widgets/window_chrome/window_title_row.dart';
import 'source_drawer_button.dart';

const Key homeSearchKey = Key('home-search');

PreferredSizeWidget homeHeader(
  BuildContext context, {
  Widget? mobileTitle,
  Widget? desktopTitle,
  VoidCallback? onSearch,
}) {
  final height = WindowTitleRow.heightOf(context);
  if (Breakpoints.isDesktop(context)) {
    return WindowTitleBar(height: height, title: desktopTitle);
  }
  return WindowTitleBar(
    height: height,
    leading: SourceDrawerButton.maybe(context),
    title: mobileTitle,
    actions: [
      if (onSearch != null) ...[
        IconButton(
          key: homeSearchKey,
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.search_rounded, size: 20),
          ),
          onPressed: onSearch,
          tooltip: 'Search',
        ),
        const SizedBox(width: 8),
      ],
    ],
    decorate: (row) => GlassSurface.appBar(child: row),
  );
}

/// The All servers home's desktop bar title, styled like `BrowseScaffold`'s so
/// the merged screens read as one family. A source home has a hero to name it;
/// the merged home has none, so without this the bar would be blank.
class HomeDesktopTitle extends StatelessWidget {
  const HomeDesktopTitle({super.key, required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.primary, size: 22),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.3,
                    ),
              ),
            ),
          ],
        ),
      );
}

/// A source's name as the phone bar title.
class HomeServerTitle extends StatelessWidget {
  const HomeServerTitle(this.name, {super.key});

  final String name;

  @override
  Widget build(BuildContext context) => Text(
        name,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          letterSpacing: -0.5,
        ),
      );
}

/// The Mydia lockup, for the All servers home, which is no single server.
class HomeMydiaLockup extends StatelessWidget {
  const HomeMydiaLockup({super.key});

  @override
  Widget build(BuildContext context) => const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MydiaLogo(size: 32),
          SizedBox(width: 10),
          // Flexible so the channel pill fits on a narrow phone: the wordmark
          // ellipsizes instead of overflowing.
          Flexible(child: HomeServerTitle('Mydia Player')),
          SizedBox(width: 8),
          ChannelBadge(),
        ],
      );
}
