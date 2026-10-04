/// Which sources exist, which one is active, and the [MediaSource] for each.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_status.dart';
import '../auth/auth_storage.dart';
import '../graphql/graphql_provider.dart';
import 'lock/source_lock_controller.dart';
import 'media_source.dart';
import 'mydia_source.dart';
import 'source.dart';
import 'source_factories.dart';
import 'store/source_records.dart';
import 'store/source_secrets.dart';
import 'store/source_store.dart';

final sourceStoreProvider = FutureProvider<SourceStore>(
  (ref) => HiveSourceStore.open(),
  retry: (_, __) => null,
);

final sourceSecretsProvider =
    Provider<SourceSecrets>((ref) => SourceSecrets(getAuthStorage()));

/// Every stored third-party account, plus the remembered active source.
class SourceRecordsNotifier extends AsyncNotifier<SourceSnapshot> {
  @override
  Future<SourceSnapshot> build() async {
    // Plex and Stash send no CORS headers for a foreign origin, and the web
    // player is served by Mydia itself. Web keeps Mydia only.
    if (kIsWeb) return SourceSnapshot.empty;
    final store = await ref.watch(sourceStoreProvider.future);
    return store.load();
  }

  SourceSnapshot? get _current => switch (state) {
        AsyncData(:final value) => value,
        _ => null,
      };

  /// Writes run one at a time. A read-modify-write (`markNeedsReauth`,
  /// `updateServers`) reads its record inside the queue, so it always sees
  /// what the write before it stored.
  Future<void> _queue = Future.value();

  Future<T> _serialise<T>(Future<T> Function() op) {
    final result = _queue.then((_) => op());
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// A sign-in flow writes a fresh record with no locks. Keep the stored
  /// record's locks for servers the new record still lists, so signing in
  /// again never unhides a server.
  Future<void> putAccount(SourceAccountRecord record) => _serialise(() {
        final stored = _record(record.account.id);
        final ids = {for (final s in record.servers) s.id};
        final kept = {
          for (final e in (stored?.serverLocks ?? const {}).entries)
            if (ids.contains(e.key)) e.key: e.value,
          ...record.serverLocks,
        };
        return _write(
            (store) => store.putAccount(record.copyWith(serverLocks: kept)));
      });

  Future<void> removeAccount(String accountId) => _serialise(() async {
        final record = _record(accountId);
        await _write((store) => store.removeAccount(accountId));
        if (record != null) {
          await ref.read(sourceSecretsProvider).deleteAll(record);
        }
      });

  /// Never throws: a selection that cannot be remembered still applies for
  /// this launch.
  Future<void> setActive(SourceId? id) async {
    if (kIsWeb) return;
    try {
      await _serialise(() => _write((store) => store.setActive(id)));
    } catch (e) {
      debugPrint('[Sources] Could not remember the active source: $e');
    }
  }

  Future<void> markNeedsReauth(String accountId, bool value) =>
      _serialise(() async {
        final record = _record(accountId);
        if (record == null || record.account.needsReauth == value) return;
        await _write((store) => store.putAccount(record.copyWith(
              account: record.account.copyWith(needsReauth: value),
            )));
      });

  Future<void> setServerLock(
          String accountId, String serverId, SourceLock lock) =>
      _serialise(() async {
        final record = _record(accountId);
        if (record == null) return;
        final locks = {...record.serverLocks}..remove(serverId);
        if (lock != SourceLock.none) locks[serverId] = lock;
        await _write(
            (store) => store.putAccount(record.copyWith(serverLocks: locks)));
      });

  /// "Forgot PIN": every account with a locked or hidden server goes, with
  /// its tokens. Nothing that was out of sight becomes visible.
  ///
  /// Runs as one queued write, so a lock still queued ahead of it is in the
  /// snapshot it reads.
  Future<void> removeLockedAccounts() => _serialise(() async {
        final locked = [
          for (final r in _current?.accounts ?? const <SourceAccountRecord>[])
            if (r.serverLocks.isNotEmpty) r,
        ];
        for (final record in locked) {
          await _write((store) => store.removeAccount(record.account.id));
          await ref.read(sourceSecretsProvider).deleteAll(record);
        }
      });

  Future<void> updateServers(
    String accountId,
    List<SourceServer> Function(List<SourceServer> servers) update,
  ) =>
      _serialise(() async {
        final record = _record(accountId);
        if (record == null) return;
        await _write((store) =>
            store.putAccount(record.copyWith(servers: update(record.servers))));
      });

  /// Replaces [accountId]'s record with what [update] returns. [update]
  /// runs inside the write queue and may do its own async work first (a
  /// Plex Home switch writes tokens there), so no other write interleaves.
  /// Null, and nothing written, when the account is gone or [update]
  /// returns null.
  Future<SourceAccountRecord?> updateRecord(
    String accountId,
    Future<SourceAccountRecord?> Function(SourceAccountRecord current) update,
  ) =>
      _serialise(() async {
        final record = _record(accountId);
        if (record == null) return null;
        final next = await update(record);
        if (next == null) return null;
        await _write((store) => store.putAccount(next));
        return next;
      });

  SourceAccountRecord? _record(String accountId) =>
      _current?.accounts.where((a) => a.account.id == accountId).firstOrNull;

  Future<void> _write(Future<void> Function(SourceStore store) write) async {
    if (kIsWeb) return;
    final store = await ref.read(sourceStoreProvider.future);
    await write(store);
    final next = await store.load();
    if (!ref.mounted) return;
    state = AsyncData(next);
  }
}

/// No automatic retry: a store that cannot open means no third-party
/// sources for this launch, and the UI must not wait on backoff timers.
final sourceRecordsProvider =
    AsyncNotifierProvider<SourceRecordsNotifier, SourceSnapshot>(
        SourceRecordsNotifier.new,
        retry: (_, __) => null);

/// True until the stored sources have loaded once, successfully or not.
///
/// Riverpod retries a failed build and reports the retry as a loading state
/// that still carries the error, so check `hasError` rather than matching
/// [AsyncError].
final sourcesLoadingProvider = Provider<bool>((ref) {
  final records = ref.watch(sourceRecordsProvider);
  return !records.hasValue && !records.hasError;
});

SourceSnapshot? _snapshotOf(Ref ref) =>
    switch (ref.watch(sourceRecordsProvider)) {
      AsyncData(:final value) => value,
      _ => null,
    };

/// Every stored source with a lock, hidden ones included. Read this, never
/// [thirdPartySourcesProvider], to ask how a source is locked.
final sourceLocksProvider = Provider<Map<SourceId, SourceLock>>((ref) {
  final snapshot = _snapshotOf(ref);
  if (snapshot == null) return const {};
  return {
    for (final record in snapshot.accounts)
      for (final source in record.sources)
        if (record.lockOf(source.server.id) case final lock
            when lock != SourceLock.none)
          source.id: lock,
  };
});

/// Sources that ask to authenticate before they open: every locked or
/// hidden one while the app is locked, none once it is unlocked.
final gatedSourceIdsProvider = Provider<Set<SourceId>>((ref) {
  if (ref.watch(sourceLockProvider)) return const {};
  return ref.watch(sourceLocksProvider).keys.toSet();
});

/// Whether the window must stay out of screenshots and the app switcher:
/// a locked or hidden source is open.
final windowSecureProvider = Provider<bool>((ref) =>
    ref.watch(sourceLockProvider) && ref.watch(sourceLocksProvider).isNotEmpty);

/// Plex, Stash and Jellyfin sources the viewer has added, minus hidden ones
/// while the app is locked. Everything that lists or counts sources reads
/// this, so a hidden source leaves no trace, not even in the switcher's
/// decision to appear.
final thirdPartySourcesProvider = Provider<List<Source>>((ref) {
  final snapshot = _snapshotOf(ref);
  if (snapshot == null) return const [];
  final unlocked = ref.watch(sourceLockProvider);
  return [
    for (final record in snapshot.accounts)
      for (final source in record.sources)
        if (unlocked || record.lockOf(source.server.id) != SourceLock.hidden)
          source,
  ];
});

/// The stored profiles of an account: a Plex account's Home users, the
/// single owner for every other kind. Empty while loading or unknown.
final accountProfilesProvider =
    Provider.family<List<SourceProfile>, String>((ref, accountId) {
  final snapshot = _snapshotOf(ref);
  return snapshot?.accounts
          .where((a) => a.account.id == accountId)
          .firstOrNull
          ?.profiles ??
      const [];
});

/// Whether the legacy Mydia login has credentials.
///
/// `AuthStateNotifier.retryConnection` sets a bare `AsyncValue.loading()`,
/// with no previous value. Reading that directly made Mydia vanish from the
/// switcher for the length of every retry; this holds the last answer
/// through loading and changes only on data or an error.
class MydiaPresenceNotifier extends Notifier<bool> {
  @override
  bool build() {
    ref.listen<AsyncValue<AuthStatus>>(authStateProvider, (_, next) {
      final present = _presentIn(next);
      if (present != null) state = present;
    });
    return _presentIn(ref.read(authStateProvider)) ?? false;
  }

  static bool? _presentIn(AsyncValue<AuthStatus> auth) => switch (auth) {
        AsyncData(:final value) =>
          value == AuthStatus.authenticated || value == AuthStatus.offlineMode,
        AsyncError() => false,
        _ => null,
      };
}

final mydiaPresentProvider =
    NotifierProvider<MydiaPresenceNotifier, bool>(MydiaPresenceNotifier.new);

/// Every source, the legacy Mydia login first when it has credentials.
///
/// Offline mode counts: the credentials exist even though the server is out
/// of reach, and the downloads screen still belongs to that source.
final sourcesProvider = Provider<List<Source>>((ref) {
  return [
    if (ref.watch(mydiaPresentProvider)) Source.legacyMydia(),
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
  /// The remembered pick, once the records have loaded.
  @override
  SourceId? build() => switch (ref.watch(sourceRecordsProvider)) {
        AsyncData(:final value) => value.activeId,
        _ => null,
      };

  void select(SourceId id) {
    state = id;
    unawaited(ref.read(sourceRecordsProvider.notifier).setActive(id));
  }
}

/// The viewer's explicit pick, if any. Read [activeSourceIdProvider] instead.
final selectedSourceIdProvider =
    NotifierProvider<SelectedSourceNotifier, SourceId?>(
        SelectedSourceNotifier.new);

/// The source the viewer is browsing: their pick while it still exists and
/// is open, otherwise the first source that does not ask to unlock.
final activeSourceIdProvider = Provider<SourceId?>((ref) {
  final sources = ref.watch(sourcesProvider);
  final gated = ref.watch(gatedSourceIdsProvider);
  final selected = ref.watch(selectedSourceIdProvider);
  if (selected != null &&
      !gated.contains(selected) &&
      sources.any((s) => s.id == selected)) {
    return selected;
  }
  return sources.where((s) => !gated.contains(s.id)).firstOrNull?.id ??
      sources.firstOrNull?.id;
});

/// The [MediaSource] for [id], or null when no such source exists.
///
/// Watches only whether the source exists. A third-party source owns a
/// connection race and timers, so a change to its stored record (a
/// re-auth flag, rediscovered connections) must not rebuild it; the record
/// is read once at build.
final mediaSourceProvider = Provider.family<MediaSource?, SourceId>((ref, id) {
  final exists =
      ref.watch(sourcesProvider.select((all) => all.any((s) => s.id == id)));
  if (!exists) return null;
  final source = ref.read(sourcesProvider).firstWhere((s) => s.id == id);
  final MediaSource media = switch (source.kind) {
    SourceKind.mydia =>
      MydiaSource(source: source, auth: ref.watch(authStateProvider)),
    SourceKind.plex ||
    SourceKind.stash ||
    SourceKind.jellyfin =>
      buildThirdPartySource(ref, source),
  };
  ref.onDispose(media.dispose);
  return media;
});

/// Where `/s/:sourceId` lands before its screen builds: Mydia keeps its
/// unprefixed routes, so its root is `/`; an unknown id goes home; a Plex
/// or Stash source stays (null).
String? sourceRootRedirect(String sourceId, List<Source> sources) {
  final source = sources.where((s) => s.id.value == sourceId).firstOrNull;
  if (source == null || source.kind == SourceKind.mydia) return '/';
  return null;
}
