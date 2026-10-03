/// Which sources exist, which one is active, and the [MediaSource] for each.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_status.dart';
import '../graphql/graphql_provider.dart';
import 'media_source.dart';
import 'mydia_source.dart';
import 'source.dart';

/// Plex and Stash sources the viewer has added. Always empty until the
/// add-server flows exist.
final thirdPartySourcesProvider = Provider<List<Source>>((ref) => const []);

/// Every source, the legacy Mydia login first when it has credentials.
///
/// Offline mode counts: the credentials exist even though the server is out
/// of reach, and the downloads screen still belongs to that source.
final sourcesProvider = Provider<List<Source>>((ref) {
  final status = switch (ref.watch(authStateProvider)) {
    AsyncData(:final value) => value,
    _ => null,
  };
  final hasMydia =
      status == AuthStatus.authenticated || status == AuthStatus.offlineMode;
  return [
    if (hasMydia) Source.legacyMydia(),
    ...ref.watch(thirdPartySourcesProvider),
  ];
});

/// The sources the switcher shows: empty unless there is a choice to make.
///
/// Reads [thirdPartySourcesProvider] first so that, while no third-party
/// source exists, building the sidebar never reads the auth state.
final switchableSourcesProvider = Provider<List<Source>>((ref) {
  if (ref.watch(thirdPartySourcesProvider).isEmpty) return const [];
  final all = ref.watch(sourcesProvider);
  return all.length > 1 ? all : const [];
});

class SelectedSourceNotifier extends Notifier<SourceId?> {
  @override
  SourceId? build() => null;

  void select(SourceId id) => state = id;
}

/// The viewer's explicit pick, if any. Read [activeSourceIdProvider] instead.
final selectedSourceIdProvider =
    NotifierProvider<SelectedSourceNotifier, SourceId?>(
        SelectedSourceNotifier.new);

/// The source the viewer is browsing: their pick while it still exists,
/// otherwise the first source.
final activeSourceIdProvider = Provider<SourceId?>((ref) {
  final sources = ref.watch(sourcesProvider);
  final selected = ref.watch(selectedSourceIdProvider);
  if (selected != null && sources.any((s) => s.id == selected)) {
    return selected;
  }
  return sources.isEmpty ? null : sources.first.id;
});

/// The [MediaSource] for [id], or null when no such source exists or its
/// kind has no implementation yet.
final mediaSourceProvider = Provider.family<MediaSource?, SourceId>((ref, id) {
  final source =
      ref.watch(sourcesProvider).where((s) => s.id == id).firstOrNull;
  if (source == null) return null;
  return switch (source.kind) {
    SourceKind.mydia =>
      MydiaSource(source: source, auth: ref.watch(authStateProvider)),
    SourceKind.plex || SourceKind.stash => null,
  };
});
