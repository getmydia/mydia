/// The selected source's connection status, for the chrome that reacts to it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'media_source.dart';
import 'sources_providers.dart';

/// The selected source's connection status, kept current. Null when nothing
/// is selected or the source is not built yet.
final currentSourceStatusProvider = Provider<SourceConnectionStatus?>((ref) {
  final id = ref.watch(selectedSourceIdProvider);
  if (id == null) return null;
  final source = ref.watch(mediaSourceProvider(id));
  if (source == null) return null;
  final status = source.statusListenable;
  void changed() => ref.invalidateSelf();
  status.addListener(changed);
  ref.onDispose(() => status.removeListener(changed));
  return status.value;
});

/// Whether [status] means the source cannot be reached right now.
bool isOffline(SourceConnectionStatus? status) =>
    status == SourceConnectionStatus.unreachable;
