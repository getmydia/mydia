import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
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
  final source = ref.watch(currentSourceIdProvider(location));
  final entries = source == null
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
  // Without a Mydia account the router sends `/settings` back to the
  // source's home, so the row would be a dead end.
  if (ref.watch(hasMydiaProvider)) return entries;
  return [
    for (final e in entries)
      if (e.id != 'settings') e,
  ];
});
