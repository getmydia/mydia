import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_gzip.dart';
import 'package:player/core/backup/backup_meta_store.dart';
import 'package:player/core/backup/backup_records.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/backup_snapshot.dart';
import 'package:player/core/backup/backup_status.dart';
import 'package:player/core/backup/slot_sync_engine.dart';
import 'package:player/core/backup/slot_transport.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/store/source_store.dart';

import '../../test_utils/mock_auth_storage.dart';
import 'in_memory_slot_transport.dart';

const _t0 = 1786000000000;

/// Counts calls, fails while [failing], and reports [stale] as `ownStale`.
class _Transport extends InMemorySlotTransport {
  _Transport({required super.ownSlotId, required super.server});

  int lists = 0;
  int writes = 0;
  final reads = <String, int>{};
  bool failing = false;
  bool stale = false;

  void _fail() {
    if (failing) {
      throw const BackupRelayException(BackupRelayError.network);
    }
  }

  @override
  Future<SlotListing?> list({String? cursor}) async {
    lists++;
    _fail();
    final l = await super.list(cursor: cursor);
    if (l == null) return null;
    return SlotListing(cursor: l.cursor, slots: l.slots, ownStale: stale);
  }

  @override
  Future<BackupPayload> read(SlotInfo slot) async {
    reads[slot.slotId] = (reads[slot.slotId] ?? 0) + 1;
    _fail();
    return super.read(slot);
  }

  @override
  Future<void> writeOwn(BackupPayload payload) async {
    _fail();
    writes++;
    await super.writeOwn(payload);
  }
}

/// One install's stores and an engine over them.
class _Device {
  _Device(this.name, this.clock, Map<String, List<int>> server)
      : transport = _Transport(ownSlotId: 'slot-$name', server: server) {
    snapshot = BackupSnapshot(
      peerSync: sync,
      authStorage: auth,
      meta: meta,
      loadSources: sources.load,
      putAccount: sources.putAccount,
      settings: SettingsService(storage: auth),
      loadSubtitleLanguages: () async => null,
      saveSubtitleLanguages: (_) async {},
      onRemoteFilesChanges: (_, __) async {},
      rootsFor: (_) async => const [],
      putRoots: (_, __) async {},
    );
    engine = SlotSyncEngine(
      meta: meta,
      snapshot: snapshot,
      deviceName: () async => name,
      platform: 'linux',
      clock: clock,
    );
  }

  final String name;
  final DateTime Function() clock;
  final _Transport transport;
  final auth = MockAuthStorage();
  final sources = InMemorySourceStore();
  final sync = InMemoryPeerSyncStore();
  final meta = BackupMetaStore(InMemoryBackupMetaStorage());
  late final BackupSnapshot snapshot;
  late final SlotSyncEngine engine;

  Future<void> watch(String key) =>
      sync.setWatched(key, true, nowMs: clock().millisecondsSinceEpoch);

  bool watched(String key) => sync.watchRecord(key)?.watched ?? false;

  Future<void> upload({bool force = false}) =>
      engine.serialise(() => engine.uploadOnce(force: force));

  Future<void> pollOnce() => engine.serialise(() => engine.pollOnce());
}

/// Runs [body] in fake time, flushing microtasks until it completes.
void _fake(String name, void Function(FakeAsync async) body) {
  test(name, () => fakeAsync(body));
}

void _settle(FakeAsync async, Future<void> f) {
  var done = false;
  Object? error;
  StackTrace? stack;
  f.then((_) => done = true, onError: (Object e, StackTrace s) {
    error = e;
    stack = s;
    done = true;
  });
  for (var i = 0; i < 1000 && !done; i++) {
    async.flushMicrotasks();
  }
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  expect(done, isTrue, reason: 'future never completed');
}

void main() {
  late Map<String, List<int>> server;
  final devices = <_Device>[];
  DateTime now() => DateTime.fromMillisecondsSinceEpoch(_t0);

  _Device device(String name, [DateTime Function()? clock]) {
    final d = _Device(name, clock ?? now, server);
    devices.add(d);
    d.engine.attach(d.transport);
    return d;
  }

  setUp(() => server = {});
  tearDown(() {
    for (final d in devices) {
      d.engine.dispose();
    }
    devices.clear();
  });

  _fake('debounce_coalesces_marks_into_one_upload', (async) {
    final a = device(
        'a',
        () => DateTime.fromMillisecondsSinceEpoch(
            _t0 + async.elapsed.inMilliseconds));
    for (var i = 0; i < 10; i++) {
      _settle(async, a.watch('tmdb:movie:$i'));
      a.engine.markDirty();
      async.elapse(const Duration(seconds: 10));
    }
    expect(a.transport.writes, 0);
    async.elapse(const Duration(seconds: 21));
    expect(a.transport.writes, 1);
    async.elapse(const Duration(minutes: 10));
    expect(a.transport.writes, 1);
    expect(a.engine.status.value, isA<BackupIdle>());
  });

  test('unchanged_records_skip_upload_unless_forced', () async {
    final a = device('a');
    await a.watch('tmdb:movie:1');
    await a.upload();
    expect(a.transport.writes, 1);
    await a.upload();
    expect(a.transport.writes, 1, reason: 'the records are unchanged');
    await a.upload(force: true);
    expect(a.transport.writes, 2);
  });

  test('ownStale_forces_upload_after_poll', () async {
    final a = device('a');
    await a.upload();
    expect(a.transport.writes, 1);
    await a.engine.poll();
    expect(a.transport.writes, 1, reason: 'not stale: nothing to upload');
    a.transport.stale = true;
    // A listing that moved, so the poll is not answered as unchanged.
    await device('b').upload();
    await a.engine.poll();
    expect(a.transport.writes, 2);
  });

  test('changes_stream_triggers_poll', () async {
    final a = device('a');
    expect(a.transport.lists, 0);
    a.transport.pushChange();
    await Future<void>.delayed(Duration.zero);
    await a.engine.serialise(() async {});
    expect(a.transport.lists, 1);

    await a.engine.detach();
    a.transport.pushChange();
    await Future<void>.delayed(Duration.zero);
    await a.engine.serialise(() async {});
    expect(a.transport.lists, 1, reason: 'detached engines stop listening');
  });

  _fake('backoff_doubles_to_30_minutes', (async) {
    final a = device('a');
    a.transport.failing = true;
    final delays = <Duration>[];
    for (var i = 0; i < 7; i++) {
      a.engine.reportFailure(BackupRelayError.network);
      delays
          .add(async.pendingTimers.singleWhere((t) => !t.isPeriodic).duration);
    }
    expect(delays, [
      for (final m in [1, 2, 4, 8, 16, 30, 30]) Duration(minutes: m),
    ]);
    expect(
        a.engine.status.value,
        isA<BackupError>()
            .having((e) => e.kind, 'kind', BackupRelayError.network));

    // The retry polls, and a success resets the backoff.
    a.transport.failing = false;
    final lists = a.transport.lists;
    async.elapse(const Duration(minutes: 30));
    async.flushMicrotasks();
    expect(a.transport.lists, greaterThan(lists));
    expect(a.engine.status.value, isA<BackupIdle>());
    a.engine.reportFailure(BackupRelayError.network);
    expect(async.pendingTimers.singleWhere((t) => !t.isPeriodic).duration,
        const Duration(minutes: 1));
  });

  test('unreadable_slot_not_redownloaded_until_version_moves', () async {
    final a = device('a');
    final b = device('b');
    await a.upload();
    await b.watch('tmdb:movie:20');
    await b.upload();
    // Corrupt b's bytes in place: its version does not move.
    server['slot-b'] = [1, 2, 3];

    await a.pollOnce();
    expect(a.engine.unreadableSlots.value, {'slot-b'});
    expect(a.transport.reads['slot-b'], 1);
    expect(a.watched('tmdb:movie:20'), isFalse);

    await a.pollOnce();
    expect(a.transport.reads['slot-b'], 1, reason: 'same version: skipped');
    expect(a.engine.unreadableSlots.value, {'slot-b'});

    await b.watch('tmdb:movie:21');
    await b.upload();
    await a.pollOnce();
    expect(a.transport.reads['slot-b'], 2);
    expect(a.engine.unreadableSlots.value, isEmpty);
    expect(a.watched('tmdb:movie:21'), isTrue);
    expect(a.meta.slotNames()['slot-b'], 'b');
    expect(a.engine.slots.value.map((s) => s.slotId).first, 'slot-a');
  });

  test('newer_version_slot_is_flagged_not_merged', () async {
    final a = device('a');
    final b = device('b');
    await a.upload();
    await b.watch('tmdb:movie:20');
    await b.upload();
    server['slot-b'] = gzipEncode(utf8.encode(jsonEncode({
      'v': 2,
      'deviceName': 'b',
      'platform': 'p',
      'createdAt': 1,
      'records': <Object>[],
    })));
    await a.pollOnce();
    expect(a.engine.newerVersionSeen.value, isTrue);
    expect(a.engine.unreadableSlots.value, {'slot-b'});
    expect(a.watched('tmdb:movie:20'), isFalse);

    // Same version: not read again, still flagged.
    await a.pollOnce();
    expect(a.transport.reads['slot-b'], 1);
    expect(a.engine.newerVersionSeen.value, isTrue);

    // The slot is rewritten by a build this one understands.
    await b.watch('tmdb:movie:21');
    await b.upload();
    await a.pollOnce();
    expect(a.engine.newerVersionSeen.value, isFalse);
    expect(a.engine.unreadableSlots.value, isEmpty);
    expect(a.watched('tmdb:movie:21'), isTrue);
  });

  test('moved_slot_is_listed_not_merged', () async {
    final a = device('a');
    final b = device('b');
    await a.upload();
    await b.watch('tmdb:movie:20');
    await b.upload();
    await b.transport.writeOwn(const BackupPayload(
        deviceName: 'b',
        platform: 'p',
        createdAt: 1,
        records: [],
        movedTo: 'icloud'));
    await a.pollOnce();
    expect(a.engine.movedSlots.value, {'slot-b': 'icloud'});
    expect(a.engine.unreadableSlots.value, isEmpty);
    expect(a.watched('tmdb:movie:20'), isFalse);

    await b.watch('tmdb:movie:21');
    await b.upload(force: true);
    await a.pollOnce();
    expect(a.engine.movedSlots.value, isEmpty);
    expect(a.watched('tmdb:movie:21'), isTrue);
  });

  for (final kind in [
    BackupRelayError.signedOut,
    BackupRelayError.cloudUnavailable,
  ]) {
    _fake('${kind.name}_halts_without_clearing', (async) {
      final a = device('a');
      _settle(async, a.watch('tmdb:movie:1'));
      a.transport.failing = false;
      a.engine.reportFailure(kind);
      async.flushMicrotasks();
      final status = a.engine.status.value;
      expect(status, isA<BackupError>());
      expect((status as BackupError).kind, kind);
      expect(a.engine.halted, isTrue);
      expect(async.pendingTimers, isEmpty);
      expect(a.watched('tmdb:movie:1'), isTrue, reason: 'local data kept');
      a.engine.markDirty();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(hours: 2));
      expect(a.transport.writes, 0);

      a.engine.resume();
      expect(a.engine.halted, isFalse);
      expect(a.engine.status.value, isA<BackupIdle>());
      _settle(async, a.engine.poll());
      expect(a.transport.lists, greaterThan(0));
    });
  }

  _fake('quota_full_waits_for_next_change', (async) {
    final a = device('a');
    _settle(async, a.watch('tmdb:movie:1'));
    a.transport.failing = false;
    a.engine.reportFailure(BackupRelayError.quotaFull);
    async.flushMicrotasks();
    expect((a.engine.status.value as BackupError).kind,
        BackupRelayError.quotaFull);
    expect(async.pendingTimers.where((t) => !t.isPeriodic), isEmpty);
    expect(a.engine.halted, isFalse);
    a.engine.markDirty();
    async.elapse(SlotSyncEngine.debounce + const Duration(seconds: 1));
    expect(a.transport.writes, 1);
    expect(a.engine.status.value, isA<BackupIdle>());
  });

  test('legacy_int_mergedSeq_read_as_version', () async {
    final a = device('a');
    final b = device('b');
    await b.upload();
    // The in-memory store's first write is version "1"; an install upgraded
    // from int seqs has merged it already.
    await a.meta.setMergedSeq('slot-b', 1);
    expect(a.meta.mergedVersion('slot-b'), '1');

    await a.pollOnce();
    expect(a.transport.reads['slot-b'], isNull);

    await a.meta.setMergedVersion('slot-b', 'v2');
    expect(a.meta.mergedVersion('slot-b'), 'v2');
    await a.meta.clearMergedSeqs();
    expect(a.meta.mergedVersion('slot-b'), isNull);
    expect(a.meta.mergedSeq('slot-b'), 0);
  });

  _fake('markDirty_while_paused_uploads_after_unpause', (async) {
    final a = device('a');
    _settle(async, a.watch('tmdb:movie:1'));
    a.engine.pause();
    a.engine.markDirty();
    async.elapse(SlotSyncEngine.debounce + const Duration(seconds: 1));
    expect(a.transport.writes, 0);

    a.engine.unpause();
    async.elapse(SlotSyncEngine.debounce + const Duration(seconds: 1));
    expect(a.transport.writes, 1);
  });

  test('failed_forced_upload_retains_force_until_success', () async {
    final a = device('a');
    await a.watch('tmdb:movie:1');
    await a.upload();
    expect(a.transport.writes, 1);

    a.transport.failing = true;
    await expectLater(a.upload(force: true), throwsA(anything));

    a.transport.failing = false;
    // Records match the last uploaded hash, yet the retained force bit uploads.
    await a.upload();
    expect(a.transport.writes, 2);

    // Cleared on success, another unchanged upload skips.
    await a.upload();
    expect(a.transport.writes, 2);
  });

  _fake('tooLarge_cleared_when_unchanged_hash_matches', (async) {
    final a = device('a');
    _settle(async, a.watch('tmdb:movie:1'));
    _settle(async, a.upload());
    expect(a.transport.writes, 1);

    a.engine.reportFailure(BackupRelayError.tooLarge);
    async.flushMicrotasks();
    expect(
        (a.engine.status.value as BackupError).kind, BackupRelayError.tooLarge);

    _settle(async, a.upload());
    expect(a.engine.status.value, isA<BackupIdle>());
    expect(a.transport.writes, 1);
  });

  _fake('cloudUnavailable_halt_resumes_and_polls_on_transport_change', (async) {
    final a = device('a');
    _settle(async, a.watch('tmdb:movie:1'));
    a.engine.reportFailure(BackupRelayError.cloudUnavailable);
    async.flushMicrotasks();
    expect(a.engine.halted, isTrue);

    a.transport.lists = 0;
    a.transport.pushChange();
    async.flushMicrotasks();
    expect(a.engine.halted, isFalse);
    expect(a.engine.status.value, isA<BackupIdle>());
    expect(a.transport.lists, greaterThan(0));
  });
}
