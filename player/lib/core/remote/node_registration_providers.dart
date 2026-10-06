import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../p2p/p2p_service.dart';
import '../sources/capabilities.dart';
import '../sources/source.dart';
import '../sources/sources_providers.dart';
import '../sources/store/source_records.dart';
import 'node_registration_service.dart';
import 'registration_status.dart';
import 'remote_control_settings.dart';

/// One registration per Mydia instance, following the accounts.
final nodeRegistrationsProvider =
    NotifierProvider<NodeRegistrations, Map<SourceId, RegistrationStatus>>(
  NodeRegistrations.new,
);

/// The worst status across instances, for the one global settings row.
final nodeRegistrationSummaryProvider = Provider<RegistrationStatus>(
  (ref) => worstRegistrationStatus(ref.watch(nodeRegistrationsProvider).values),
);

class _Entry {
  _Entry(this.sourceId, this.service);

  final SourceId sourceId;
  final NodeRegistrationService service;
  StreamSubscription<RegistrationStatus>? statuses;
  ProviderSubscription<Object?>? sourceSubscription;

  void dispose() {
    unawaited(statuses?.cancel());
    sourceSubscription?.close();
    service.dispose();
  }
}

/// Keeps one [NodeRegistrationService] per stored Mydia account and feeds each
/// from the inputs, republishing every status as provider state.
///
/// Every input change re-runs [_sync], which is the whole point: the previous
/// implementation sampled these once during startup and gave up for the rest
/// of the session if any of them had not arrived yet. Inputs are listened to
/// rather than watched, so this notifier never rebuilds: a rebuild would run
/// its dispose callbacks and tear every service down, and the services must
/// outlive input changes for an unchanged scope to do no work.
class NodeRegistrations extends Notifier<Map<SourceId, RegistrationStatus>> {
  final _entries = <String, _Entry>{};

  /// Whether the remote control setting had not resolved at the last sync.
  bool _settingUnresolved = false;

  @override
  Map<SourceId, RegistrationStatus> build() {
    ref.onDispose(() {
      for (final e in _entries.values) {
        e.dispose();
      }
      _entries.clear();
    });
    ref.listen(p2pStatusNotifierProvider, (_, __) => _sync());
    ref.listen(remoteControlEnabledProvider, (_, __) => _sync());
    ref.listen(sourceRecordsProvider, (_, __) => _sync());
    return _sync();
  }

  Map<SourceId, RegistrationStatus> _sync() {
    final nodeId = ref.read(p2pStatusNotifierProvider).nodeId;
    final controllableAsync = ref.read(remoteControlEnabledProvider);
    final records = ref.read(sourceRecordsProvider).value?.accounts ??
        const <SourceAccountRecord>[];
    final mydia = [
      for (final r in records)
        if (r.account.kind == SourceKind.mydia) r,
    ];

    // `AsyncValue.value` is null both while Hive is still opening its box
    // and if opening it failed, and treating either as "true" (the old
    // behaviour) reads a device that explicitly opted out as controllable
    // for however long that takes, republishing a node id nobody asked to
    // publish. Unresolved defaults to *not* controllable, and the sync
    // that follows resolution decides for real.
    final controllable = controllableAsync.value ?? false;
    _settingUnresolved = !controllableAsync.hasValue;

    final live = {for (final r in mydia) r.account.id};
    for (final id in _entries.keys.toList()) {
      if (!live.contains(id)) _entries.remove(id)!.dispose();
    }

    for (final record in mydia) {
      final entry = _entries.putIfAbsent(
        record.account.id,
        () => _create(record.account.id, mydiaSourceIdOf(record)),
      );
      final remoteTargets =
          ref.read(mediaSourceProvider(entry.sourceId))?.as<RemoteTargets>();
      entry.service.update(
        controllable: controllable,
        nodeId: nodeId,
        clientReady: remoteTargets != null && !record.account.needsReauth,
        // Changes only with the account or a re-sign-in clearing
        // `needsReauth`, so a token refresh never re-registers.
        clientScope: '${record.account.id}:${record.account.needsReauth}',
      );
    }

    final next = {
      for (final e in _entries.values) e.sourceId: _reported(e.service.status),
    };
    // The first sync runs inside `build`, which returns the map itself.
    if (ref.mounted && _built) state = next;
    _built = true;
    return next;
  }

  bool _built = false;

  _Entry _create(String accountId, SourceId sourceId) {
    final service = NodeRegistrationService(
      // Resolved per attempt, so a rebuilt source object is picked up by the
      // next retry instead of pinning a stale one.
      register: (nodeId) async {
        final targets =
            ref.read(mediaSourceProvider(sourceId))?.as<RemoteTargets>();
        if (targets == null) throw StateError('No Mydia server');
        return targets.registerNode(nodeId);
      },
    );
    final entry = _Entry(sourceId, service);
    entry.statuses = service.statuses.listen((status) {
      // `cancel()` is async and does not retract an event already queued, so
      // one can arrive after this entry or provider is gone. Same guard, same
      // reason, as `P2pStatusNotifier`.
      if (!ref.mounted || _entries[accountId] != entry) return;
      state = {...state, sourceId: _reported(status)};
    });
    // The source object appearing or being replaced changes whether the
    // client is ready.
    entry.sourceSubscription =
        ref.listen(mediaSourceProvider(sourceId), (_, __) => _sync());
    return entry;
  }

  /// While the setting hasn't resolved, `controllable: false` makes the
  /// service go idle, which reads to the user as "you turned this off". It is
  /// still loading, the same reason `RegistrationWaiting` exists for the node
  /// id and the server connection. `RegistrationIdle` is the only status a
  /// service emits while uncontrollable, so this cannot misfire.
  RegistrationStatus _reported(RegistrationStatus status) {
    if (_settingUnresolved && status is RegistrationIdle) {
      return const RegistrationWaiting('the remote control setting');
    }
    return status;
  }

  /// Abandons any pending backoff and tries again now, for every instance
  /// that is not registered.
  void retryAll() {
    for (final e in _entries.values) {
      if (e.service.status is! RegistrationSucceeded) e.service.retryNow();
    }
  }
}
