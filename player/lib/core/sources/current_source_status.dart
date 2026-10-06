/// Connection status of the source the chrome is about, for the banners and
/// the shell's offline gating.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'media_source.dart';
import 'mydia/bound_mydia.dart';
import 'source.dart';
import 'sources_providers.dart';

/// The connection status of source [id], kept current. Null when the source
/// does not exist.
final sourceStatusProvider =
    Provider.autoDispose.family<SourceConnectionStatus?, SourceId>((ref, id) {
  final source = ref.watch(mediaSourceProvider(id));
  if (source == null) return null;
  final status = source.statusListenable;
  void changed() => ref.invalidateSelf();
  status.addListener(changed);
  ref.onDispose(() => status.removeListener(changed));
  return status.value;
});

/// The active source's connection status. Null when there is no source.
final currentSourceStatusProvider = Provider<SourceConnectionStatus?>((ref) {
  final id = ref.watch(activeSourceIdProvider);
  return id == null ? null : ref.watch(sourceStatusProvider(id));
});

/// Which source a screen at [location] belongs to: the `/s/<id>` source, else
/// the bound Mydia instance (the legacy screens), else the [active] source.
SourceId? statusSourceIdFor(
  String location, {
  SourceId? bound,
  SourceId? active,
}) {
  if (location.startsWith('/s/')) {
    final segment = location.substring(3).split('/').first;
    if (segment.isNotEmpty) {
      try {
        return SourceId(Uri.decodeComponent(segment));
      } on ArgumentError {
        return SourceId(segment);
      } on FormatException {
        return SourceId(segment);
      }
    }
  }
  return bound ?? active;
}

/// The connection status of the source the screen at a location belongs to.
final routeSourceStatusProvider = Provider.autoDispose
    .family<SourceConnectionStatus?, String>((ref, location) {
  final id = statusSourceIdFor(
    location,
    bound: ref.watch(boundSourceIdProvider),
    active: ref.watch(activeSourceIdProvider),
  );
  return id == null ? null : ref.watch(sourceStatusProvider(id));
});

/// Whether [status] means the source cannot be reached right now.
bool isOffline(SourceConnectionStatus? status) =>
    status == SourceConnectionStatus.unreachable;
