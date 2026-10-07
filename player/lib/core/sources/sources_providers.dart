/// Which sources exist, which one is active, and the [MediaSource] for each.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_storage.dart';
import '../downloads/collection_sync_providers.dart';
import '../downloads/download_providers.dart';
import '../downloads/download_service.dart';
import 'all_servers_inclusion.dart';
import 'cache/source_cache.dart';
import 'lock/source_lock_controller.dart';
import 'media_source.dart';
import 'source.dart';
import 'source_factories.dart';
import 'store/source_records.dart';
import 'store/source_secrets.dart';
import 'store/source_store.dart';

/// How long removing an account waits for the download manager. A manager
/// that never builds must not stall the write queue.
/// Mutable so a test can shorten it.
Duration downloadLookupTimeout = const Duration(seconds: 5);

final sourceStoreProvider = FutureProvider<SourceStore>(
  (ref) => HiveSourceStore.open(),
  retry: (_, __) => null,
);

final sourceSecretsProvider =
    Provider<SourceSecrets>((ref) => SourceSecrets(getAuthStorage()));

/// Overridable so tests can exercise the web rules in the VM.
final isWebProvider = Provider<bool>((_) => kIsWeb);

/// Plex, Jellyfin and Stash send no CORS headers for a foreign origin, and
/// the web player is served by Mydia itself. Web keeps Mydia only.
bool sourceKindAllowedOnWeb(SourceKind k) => k == SourceKind.mydia;

/// Every stored third-party account, plus the remembered active source.
class SourceRecordsNotifier extends AsyncNotifier<SourceSnapshot> {
  @override
  Future<SourceSnapshot> build() async {
    final isWeb = ref.watch(isWebProvider);
    final store = await ref.watch(sourceStoreProvider.future);
    final snapshot = await store.load();
    return isWeb ? _webOnly(snapshot) : snapshot;
  }

  /// What web can use of [snapshot]: Mydia accounts and their choices.
  static SourceSnapshot _webOnly(SourceSnapshot snapshot) {
    final accounts = [
      for (final a in snapshot.accounts)
        if (sourceKindAllowedOnWeb(a.account.kind)) a,
    ];
    if (accounts.length == snapshot.accounts.length) return snapshot;
    bool kept(SourceId id) =>
        accounts.any((a) => id.value.startsWith('${a.account.id}:'));
    return SourceSnapshot(
      accounts: accounts,
      activeId: snapshot.activeId != null && kept(snapshot.activeId!)
          ? snapshot.activeId
          : null,
      allServers: {
        for (final e in snapshot.allServers.entries)
          if (kept(e.key)) e.key: e.value,
      },
    );
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
        if (ref.read(isWebProvider) &&
            !sourceKindAllowedOnWeb(record.account.kind)) {
          debugPrint(
              '[Sources] ${record.account.kind} accounts cannot run on web.');
          return Future<void>.value();
        }
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

  /// Drops [accountId]'s All servers choices. Best effort: a leftover choice
  /// is inert, and a failure here must not stop the account's credentials
  /// from being deleted after it.
  Future<void> _dropAllServersChoices(
      SourceStore store, String accountId) async {
    final all = _current?.allServers ?? const <SourceId, bool>{};
    final kept = {
      for (final e in all.entries)
        if (!e.key.value.startsWith('$accountId:')) e.key: e.value,
    };
    if (kept.length == all.length) return;
    try {
      await store.setAllServers(kept);
    } catch (e) {
      debugPrint('[Sources] Could not drop All servers choices: $e');
    }
  }

  /// Deletes [accountId]'s cached data. Best effort: the cache is unreadable
  /// once the account is gone, the 30-day sweep reclaims leftovers, and a
  /// failure here must not stop other accounts from being removed.
  Future<void> _dropCache(String accountId) async {
    try {
      await ref.read(sourceCacheProvider).deleteAccount(accountId);
    } catch (e) {
      debugPrint('[Sources] Could not clear cached data for $accountId: $e');
    }
  }

  /// Deletes the collection auto-sync entries of [sourceIds]. Best effort,
  /// like [_dropCache]: leftovers are inert without the account.
  Future<void> _dropCollectionSync(Set<String> sourceIds,
      {bool dropUnowned = false}) async {
    try {
      await deleteCollectionSyncFor(ref, sourceIds, dropUnowned: dropUnowned);
    } catch (e) {
      debugPrint('[Sources] Could not clear collection sync entries: $e');
    }
  }

  /// Whether [accountId] is the account `legacyMydiaSourceIdProvider` names:
  /// the migrated legacy instance while it exists, else the only Mydia
  /// instance. Read from the records and the store, not that provider, which
  /// depends on this notifier.
  Future<bool> _isLegacyMydiaAccount(String accountId) async {
    try {
      final mydia = [
        for (final r in _current?.accounts ?? const <SourceAccountRecord>[])
          if (r.account.kind == SourceKind.mydia) r,
      ];
      if (mydia.isEmpty) return false;
      final store = await ref.read(sourceStoreProvider.future);
      final legacy = await store.legacyInstanceId();
      if (mydia.any((r) => r.account.id == legacy)) return legacy == accountId;
      return mydia.length == 1 && mydia.single.account.id == accountId;
    } catch (e) {
      debugPrint('[Sources] Could not resolve the legacy account: $e');
      return false;
    }
  }

  Future<void> removeAccount(String accountId) async {
    await _serialise(() async {
      final record = _record(accountId);
      final wasLegacy = await _isLegacyMydiaAccount(accountId);
      await _write((store) async {
        await store.removeAccount(accountId);
        await _dropAllServersChoices(store, accountId);
      });
      if (record != null) {
        await ref.read(sourceSecretsProvider).deleteAll(record);
      }
      // Keyed by id, so it needs no record.
      await _dropCache(accountId);
      // Legacy bare-id entries record no owner and read as the legacy
      // instance's, so they go with the account the legacy rule picked.
      await _dropCollectionSync({
        for (final s in record?.sources ?? const <Source>[]) s.id.value,
      }, dropUnowned: wasLegacy);
    });
    await _deleteDownloads([accountId]);
  }

  /// Downloads go with the accounts: their credentials are gone, so they
  /// could never sync or be re-fetched. Runs after the write queue has
  /// released, so a slow or missing download manager never delays other
  /// writes. The manager is resolved once, bounded by
  /// [downloadLookupTimeout]. Best effort: the orphan download sweep
  /// (orphan_download_sweep.dart) retries whatever is left over.
  Future<void> _deleteDownloads(List<String> accountIds) async {
    if (!isDownloadSupported || accountIds.isEmpty) return;
    final DownloadService manager;
    try {
      manager = await ref
          .read(downloadManagerProvider.future)
          .timeout(downloadLookupTimeout);
    } catch (e) {
      debugPrint('[sources] Download manager unavailable: $e');
      return;
    }
    for (final id in accountIds) {
      // Re-added during the wait: same server, so the account owns them again.
      if (_record(id) != null) continue;
      try {
        await manager.deleteAccountDownloads(id);
      } catch (e) {
        debugPrint('[sources] Could not delete downloads of $id: $e');
      }
    }
  }

  /// Never throws: a selection that cannot be remembered still applies for
  /// this launch.
  Future<void> setActive(SourceId? id) async {
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

  Future<void> setIncludedInAllServers(SourceId id, bool included) =>
      _serialise(() async {
        final snapshot = await future;
        final next = {...snapshot.allServers, id: included};
        await _write((store) => store.setAllServers(next));
      });

  /// "Forgot PIN": every account with a locked or hidden server goes, with
  /// its tokens. Nothing that was out of sight becomes visible.
  ///
  /// Runs as one queued write, so a lock still queued ahead of it is in the
  /// snapshot it reads.
  Future<void> removeLockedAccounts() async {
    final removed = await _serialise(() async {
      final locked = [
        for (final r in _current?.accounts ?? const <SourceAccountRecord>[])
          if (r.serverLocks.isNotEmpty) r,
      ];
      final ids = <String>[];
      for (final record in locked) {
        final id = record.account.id;
        await _write((store) async {
          await store.removeAccount(id);
          await _dropAllServersChoices(store, id);
        });
        await ref.read(sourceSecretsProvider).deleteAll(record);
        await _dropCache(id);
        ids.add(id);
      }
      return ids;
    });
    await _deleteDownloads(removed);
  }

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
    final store = await ref.read(sourceStoreProvider.future);
    await write(store);
    final next = await store.load();
    if (!ref.mounted) return;
    state = AsyncData(ref.read(isWebProvider) ? _webOnly(next) : next);
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

/// Every source the viewer has added, Mydia included, minus hidden ones
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

/// Every source: the stored accounts, minus hidden ones while the app is
/// locked.
final sourcesProvider =
    Provider<List<Source>>((ref) => ref.watch(thirdPartySourcesProvider));

/// Whether any Mydia account is stored.
final hasMydiaProvider = Provider<bool>((ref) {
  final snapshot = _snapshotOf(ref);
  return snapshot != null &&
      snapshot.accounts.any((a) => a.account.kind == SourceKind.mydia);
});

/// How many Mydia accounts are stored.
final mydiaAccountCountProvider = Provider<int>((ref) =>
    _snapshotOf(ref)
        ?.accounts
        .where((a) => a.account.kind == SourceKind.mydia)
        .length ??
    0);

/// The sources the switcher shows: empty unless there is a choice to make.
final switchableSourcesProvider = Provider<List<Source>>((ref) {
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
  final MediaSource media = buildThirdPartySource(ref, source);
  ref.onDispose(media.dispose);
  return media;
});

/// The viewer's "Include in All servers" choices; empty until they load.
final allServersChoicesProvider = Provider<Map<SourceId, bool>>(
    (ref) => ref.watch(sourceRecordsProvider).value?.allServers ?? const {});

/// Included sources the merged views read. Leaves out
/// what is locked away and what needs signing in again.
///
/// The list compares equal when it holds the same instances in the same
/// order, so a source-records write that changes nothing here (a picker
/// switch, an unchanged rediscovery) does not notify, and the merged reader
/// and grids built on it are not restarted.
final allServersSourcesProvider = Provider<List<MediaSource>>((ref) {
  return _IdentityList([
    for (final s in ref.watch(_allServersIncludedRecordsProvider))
      if (ref.watch(mediaSourceProvider(s.id)) case final media?) media,
  ]);
});

/// The saved sources that count as included. A `mediaSourceProvider` is null
/// only for an id that is no longer saved, which this list cannot hold, so
/// the router, which counts [allServersIncluded] directly, agrees with
/// [allServersSourcesProvider].
final _allServersIncludedRecordsProvider =
    Provider<List<Source>>((ref) => allServersIncluded(
          ref.watch(sourcesProvider),
          ref.watch(allServersChoicesProvider),
          ref.watch(gatedSourceIdsProvider),
        ));

/// An unmodifiable list whose equality is element-wise identity.
class _IdentityList extends UnmodifiableListView<MediaSource> {
  _IdentityList(super.source);

  @override
  bool operator ==(Object other) {
    if (other is! _IdentityList || other.length != length) return false;
    for (var i = 0; i < length; i++) {
      if (!identical(this[i], other[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(map(identityHashCode));
}

/// Included sources the merged views left out because they need signing in
/// again, so the views can say so.
final allServersNeedSignInProvider = Provider<List<Source>>((ref) {
  final choices = ref.watch(allServersChoicesProvider);
  return [
    for (final s in ref.watch(sourcesProvider))
      if (s.account.needsReauth && includedInAllServers(s, choices)) s,
  ];
});

/// Where `/s/:sourceId` lands before its screen builds: an unknown id goes
/// home; any known source stays (null).
String? sourceRootRedirect(String sourceId, List<Source> sources) =>
    sources.any((s) => s.id.value == sourceId) ? null : '/';
