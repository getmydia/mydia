import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart'
    show activeSourceIdProvider, mediaSourceProvider;
import '../../../domain/navigation/all_servers_locations.dart';
import '../../../domain/navigation/sidebar_layout.dart';
import '../../../domain/navigation/source_nav.dart';
import '../../../domain/sources/library.dart';
import '../../screens/sources/source_browse_providers.dart';

/// The source a shell location belongs to: the one in a `/s/` location,
/// else the active source (for `/downloads` and `/settings`).
final currentSourceIdProvider =
    Provider.family<SourceId?, String>((ref, location) {
  final fromLocation = sourceIdFromLocation(location);
  if (fromLocation != null) return SourceId(fromLocation);
  return ref.watch(activeSourceIdProvider);
});

/// The shell's navigation rows for [location]: the viewer's layout resolved
/// against the current source. With no source, only Downloads and Settings.
final sourceNavEntriesProvider =
    Provider.family<List<SourceNavEntry>, String>((ref, location) {
  final layout = switch (ref.watch(sidebarDestinationsProvider)) {
    AsyncData(:final value) => value,
    _ =>
      SidebarLayout.defaults.reconcile(downloadSupported: isDownloadSupported),
  };
  if (isAllServersLocation(location)) return resolveAllServersNav(layout);
  final source = ref.watch(currentSourceIdProvider(location));
  return source == null
      ? anchoredNavEntries(layout)
      : resolveSourceNav(
          layout: layout,
          source: source,
          capabilities:
              ref.watch(mediaSourceProvider(source))?.capabilities ?? const {},
          libraries: switch (ref.watch(sourceLibrariesProvider(source))) {
            AsyncData(:final value) => value,
            _ => const <Library>[],
          },
        );
});
