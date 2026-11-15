import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';

import 'backup_meta_store.dart';
import 'backup_records.dart';
import 'backup_relay_client.dart';
import 'backup_snapshot.dart';
import 'backup_status.dart';
import 'slot_transport.dart';

/// The store-agnostic half of the cloud backup: debounced upload of this
/// device's slot, polling and merging the other slots, backoff, and the
/// pending account offers, over whichever [SlotTransport] is attached.
/// Free of Riverpod, like the services that own it.
///
/// Every operation runs one at a time through [serialise], the one queue:
/// the owning service runs its own store operations (member changes,
/// rotations) through it too. The methods documented as running "in the
/// caller's slot" must only be called from inside [serialise].
class SlotSyncEngine {
  SlotSyncEngine({
    required BackupMetaStore meta,
    required BackupSnapshot snapshot,
    required Future<String> Function() deviceName,
    required String platform,
    required DateTime Function() clock,
    this.beforeApply,
    this.filterOwn,
    this.beforeUpload,
    this.afterUpload,
    this.afterPoll,
    this.handleFatal,
  })  : _meta = meta,
        _snapshot = snapshot,
        _deviceName = deviceName,
        _platform = platform,
        _clock = clock {
    // Filled here, not lazily: a lazy notifier could first be created by
    // dispose().
    _offers.value = meta.pendingAccounts();
  }

  static const debounce = Duration(minutes: 2);
  static const pollInterval = Duration(minutes: 15);
  static const maxBackoff = Duration(minutes: 30);

  final BackupMetaStore _meta;
  final BackupSnapshot _snapshot;
  final Future<String> Function() _deviceName;
  final String _platform;
  final DateTime Function() _clock;

  /// Runs before payloads are applied, with every payload by slot id (the
  /// relay records each slot's p2p node claims here).
  final Future<void> Function(Map<String, BackupPayload>)? beforeApply;

  /// Narrows the records this device uploads (a cloud store drops the
  /// group record).
  final List<BackupRecord> Function(List<BackupRecord>)? filterOwn;

  /// Runs before this device's records are collected for an upload.
  final Future<void> Function()? beforeUpload;

  /// Runs after the store took an upload.
  final void Function()? afterUpload;

  /// Runs after a poll merged a new listing, before [unreadableSlots] and
  /// [slots] are published.
  final Future<void> Function(SlotListing)? afterPoll;

  /// Given a failure before it becomes a status: returns null to treat it
  /// as an ordinary failure, or a future that handles it instead (the relay
  /// leaves a vault that is gone).
  final Future<void>? Function(BackupRelayException)? handleFatal;

  final _status = ValueNotifier<BackupStatus>(const BackupOff());
  final _unreadable = ValueNotifier<Set<String>>(const {});
  final _newerVersion = ValueNotifier<bool>(false);
  final _moved = ValueNotifier<Map<String, String>>(const {});
  final _offers = ValueNotifier<List<PendingAccountOffer>>(const []);
  final _slots = ValueNotifier<List<SlotInfo>>(const []);

  ValueListenable<BackupStatus> get status => _status;

  /// Slot ids whose last download could not be opened or decoded.
  ValueListenable<Set<String>> get unreadableSlots => _unreadable;

  /// Slots whose device moved its backup to another store: slot id to the
  /// store id. They are not merged.
  ValueListenable<Map<String, String>> get movedSlots => _moved;

  /// True while a listed slot was written by a newer app version.
  ValueListenable<bool> get newerVersionSeen => _newerVersion;

  /// Accounts other devices backed up that this one has not added or
  /// dismissed.
  ValueListenable<List<PendingAccountOffer>> get pendingOffers => _offers;

  /// The last listing, this device's slot first.
  ValueListenable<List<SlotInfo>> get slots => _slots;

  SlotTransport? _transport;

  /// Whose merged versions the attached transport uses (null: the relay).
  String? _mergedStore;
  StreamSubscription<void>? _changes;
  String? Function()? _readCursor;
  Future<void> Function(String?)? _writeCursor;
  String? _cursor;
  int? _lastSuccessMs;

  /// Set by [halt] (the store is unavailable): nothing runs until a start
  /// or a user action lifts it.
  bool halted = false;

  /// Set by [pause] while another store comes up: attached, but nothing
  /// runs in the background until [unpause] or [detach].
  bool _paused = false;
  bool _disposed = false;
  bool _dirty = false;

  /// The last upload was refused as too large; a successful poll keeps
  /// showing that until an upload succeeds.
  bool _tooLarge = false;
  int _failures = 0;
  String? _uploadedHash;
  Timer? _debounceTimer;
  Timer? _pollTimer;
  Timer? _retryTimer;
  Future<void> _queue = Future.value();
  Future<void>? _pendingPoll;

  /// Slots that could not be read, by the version that failed: not
  /// downloaded again until their version changes.
  final _failedSlots = <String, String>{};

  /// The [_failedSlots] that failed as a newer version.
  final _newerSlots = <String>{};

  /// Slots found moved, by slot id: the version read and the store id.
  final _movedSlots = <String, (String, String)>{};

  /// The latest merged account records, by account id, so an offer can be
  /// accepted: the offer itself holds no credentials.
  final _accountRecords = <String, AccountBackupRecord>{};

  bool get attached => _transport != null;

  /// When this device's slot was last uploaded, null before the first.
  int? get lastSuccessMs => _lastSuccessMs;

  bool get _active => _transport != null && !halted && !_paused && !_disposed;

  int get _nowMs => _clock().millisecondsSinceEpoch;

  // Lifecycle

  /// Syncs over [transport] from now on: polls every [pollInterval] and on
  /// each of its [SlotTransport.changes]. Does not poll at once. The list
  /// cursor is read and written through [readCursor] and [writeCursor]
  /// when given (the relay keeps it in its vault state), else in memory.
  /// [mergedStore] names the store whose merged versions this transport
  /// reads and writes in the meta store (null is the relay's): no store
  /// sees another's.
  void attach(
    SlotTransport transport, {
    int? lastSuccessMs,
    String? Function()? readCursor,
    Future<void> Function(String?)? writeCursor,
    String? mergedStore,
  }) {
    unawaited(_changes?.cancel());
    _transport = transport;
    _mergedStore = mergedStore;
    _paused = false;
    _readCursor = readCursor;
    _writeCursor = writeCursor;
    _cursor = null;
    _lastSuccessMs = lastSuccessMs;
    halted = false;
    _uploadedHash = null;
    _failures = 0;
    _set(BackupIdle(lastSuccessMs));
    _startPolling();
    _changes = transport.changes.listen((_) => unawaited(poll()));
  }

  /// Stops the timers and the change subscription and forgets what was
  /// known in memory of the store. The meta store is kept.
  Future<void> detach() async {
    _cancelTimers();
    final changes = _changes;
    _changes = null;
    _transport = null;
    _mergedStore = null;
    _paused = false;
    _readCursor = null;
    _writeCursor = null;
    _cursor = null;
    _dirty = false;
    _uploadedHash = null;
    _tooLarge = false;
    _failedSlots.clear();
    _newerSlots.clear();
    _movedSlots.clear();
    _accountRecords.clear();
    if (!_disposed) {
      _unreadable.value = const {};
      _newerVersion.value = false;
      _moved.value = const {};
      _slots.value = const [];
    }
    await changes?.cancel();
  }

  /// Stops background syncing without leaving the store, once the
  /// operation running now has finished: no timer, poll, upload or retry
  /// runs until [unpause] or [detach]. Operations the owner runs itself
  /// (a moved stub) still reach the store.
  Future<void> pause() => serialise(() async {
        if (_transport == null) return;
        _paused = true;
        _cancelTimers();
      });

  /// Undoes [pause]: polling again, and a change still waiting to go up
  /// is debounced again.
  void unpause() {
    if (!_paused) return;
    _paused = false;
    if (halted) return;
    ensurePolling();
    if (_dirty) markDirty();
  }

  void dispose() {
    _disposed = true;
    _cancelTimers();
    unawaited(_changes?.cancel());
    _changes = null;
    _status.dispose();
    _unreadable.dispose();
    _newerVersion.dispose();
    _moved.dispose();
    _offers.dispose();
    _slots.dispose();
  }

  // Triggers

  /// A backed-up record changed. Uploads at most once per [debounce].
  void markDirty() {
    if (!_active) return;
    _dirty = true;
    _debounceTimer ??= Timer(debounce, () {
      _debounceTimer = null;
      unawaited(background(_uploadIfDirty));
    });
  }

  /// Uploads a pending change now, as the app goes to the background.
  Future<void> flush() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    if (!_active || !_dirty) return;
    await background(_uploadIfDirty);
  }

  /// Lists the store and merges every slot that changed. A poll asked for
  /// while one is still waiting its turn joins it.
  Future<void> poll() {
    if (!_active) return Future.value();
    final waiting = _pendingPoll;
    if (waiting != null) return waiting;
    late final Future<void> mine;
    void release() {
      if (identical(_pendingPoll, mine)) _pendingPoll = null;
    }

    mine = background(() {
      release();
      return pollOnce();
    }).whenComplete(release);
    return _pendingPoll = mine;
  }

  /// Uploads this device's slot in the caller's slot, reporting a failure
  /// as status and a retry.
  Future<void> uploadNow({bool force = false}) =>
      attempt(() => uploadOnce(force: force));

  // Upload

  Future<void> _uploadIfDirty() async {
    if (_dirty) await uploadOnce();
  }

  /// Writes this device's records to its slot, in the caller's slot;
  /// throws on failure. Skipped when the records are what was last
  /// uploaded, unless [force]d (a new epoch, a join).
  Future<void> uploadOnce({bool force = false}) async {
    final transport = _require();
    _dirty = false;
    try {
      await beforeUpload?.call();
      var records = lwwMerge([await _snapshot.collect(nowMs: _nowMs)]);
      final filter = filterOwn;
      if (filter != null) records = filter(records);
      final hash = sha256
          .convert(
              utf8.encode(jsonEncode([for (final r in records) r.toJson()])))
          .toString();
      if (!force && hash == _uploadedHash) return;
      final payload = BackupPayload(
        deviceName: await _deviceName(),
        platform: _platform,
        createdAt: _nowMs,
        records: records,
      );
      _set(const BackupUploading());
      await transport.writeOwn(payload);
      _lastSuccessMs = _nowMs;
      _uploadedHash = hash;
      _tooLarge = false;
      afterUpload?.call();
      _set(BackupIdle(_lastSuccessMs));
    } catch (_) {
      _dirty = true;
      rethrow;
    }
  }

  // Poll

  /// Lists the store (from the stored cursor when [conditional] and not
  /// [full]) and merges every other slot whose version is not the one
  /// merged (every slot when [full]) in live mode, in the caller's slot;
  /// throws on failure. Uploads after when the listing says this device's
  /// slot is stale.
  Future<void> pollOnce({bool full = false, bool conditional = true}) async {
    final transport = _require();
    // Taken now: a detach while this awaits must not move the versions
    // into another store's record.
    final store = _mergedStore;
    final listing = await transport.list(
        cursor: full || !conditional ? null : _currentCursor);
    if (listing == null) return idle();
    final ownSlotId = transport.ownSlotId;
    final payloads = <String, BackupPayload>{};
    final unreadable = <String>{};
    final moved = <String, String>{};
    final listed = {for (final s in listing.slots) s.slotId};
    _failedSlots.removeWhere((id, _) => !listed.contains(id));
    _newerSlots.removeWhere((id) => !_failedSlots.containsKey(id));
    _movedSlots.removeWhere((id, _) => !listed.contains(id));
    for (final s in listing.slots) {
      if (s.slotId == ownSlotId) continue;
      final known = _movedSlots[s.slotId];
      if (!full && known != null && known.$1 == s.version) {
        moved[s.slotId] = known.$2;
        continue;
      }
      if (!full && s.version == _meta.mergedVersion(s.slotId, store: store)) {
        continue;
      }
      if (_failedSlots[s.slotId] == s.version) {
        unreadable.add(s.slotId);
        continue;
      }
      final BackupPayload? p;
      try {
        p = await _read(transport, s);
      } on NewerBackupVersionException {
        unreadable.add(s.slotId);
        _failedSlots[s.slotId] = s.version;
        _newerSlots.add(s.slotId);
        continue;
      }
      _movedSlots.remove(s.slotId);
      if (p == null) {
        unreadable.add(s.slotId);
        _failedSlots[s.slotId] = s.version;
        _newerSlots.remove(s.slotId);
      } else {
        _failedSlots.remove(s.slotId);
        _newerSlots.remove(s.slotId);
        final to = p.movedTo;
        if (to != null) {
          moved[s.slotId] = to;
          _movedSlots[s.slotId] = (s.version, to);
        } else {
          payloads[s.slotId] = p;
        }
      }
    }
    await apply(payloads, BackupApplyMode.live);
    for (final s in listing.slots) {
      if (payloads.containsKey(s.slotId)) {
        await _meta.setMergedVersion(s.slotId, s.version, store: store);
      }
    }
    refreshOffers();
    await afterPoll?.call(listing);
    if (!_disposed) {
      _unreadable.value = unreadable;
      _newerVersion.value = unreadable.any(_newerSlots.contains);
      _moved.value = Map.unmodifiable(moved);
      _slots.value = List.unmodifiable([
        ...listing.slots.where((s) => s.slotId == ownSlotId),
        ...listing.slots.where((s) => s.slotId != ownSlotId),
      ]);
    }
    // An unreadable slot keeps the cursor unset, so the next poll lists
    // again (the slot itself is read only once its version moves) and the
    // unreadable list stays current.
    final cursor = unreadable.isEmpty ? listing.cursor : null;
    if (cursor != _currentCursor) await _setCursor(cursor);
    idle();
    if (listing.ownStale) await uploadOnce(force: true);
  }

  String? get _currentCursor {
    final read = _readCursor;
    return read == null ? _cursor : read();
  }

  Future<void> _setCursor(String? cursor) async {
    final write = _writeCursor;
    if (write == null) {
      _cursor = cursor;
    } else {
      await write(cursor);
    }
  }

  /// Null when the slot is undecodable; a [NewerBackupVersionException] and
  /// other failures throw.
  Future<BackupPayload?> _read(SlotTransport transport, SlotInfo slot) async {
    final BackupPayload payload;
    try {
      payload = await transport.read(slot);
    } on NewerBackupVersionException {
      rethrow;
    } on FormatException {
      return null;
    }
    await rememberName(slot.slotId, payload.deviceName);
    return payload;
  }

  /// Every slot of [transport] that reads, by slot id, for a restore
  /// preview. Changes nothing: no names, merged versions or offers.
  Future<Map<String, BackupPayload>> readAll(SlotTransport transport) async {
    final listing = await transport.list();
    final out = <String, BackupPayload>{};
    for (final s in listing?.slots ?? const <SlotInfo>[]) {
      try {
        out[s.slotId] = await transport.read(s);
      } on FormatException {
        debugPrint('[Backup] Slot ${s.slotId} is unreadable');
      }
    }
    return out;
  }

  /// Keeps [slotId]'s device name in the meta store, so it outlives a
  /// restart.
  Future<void> rememberName(String slotId, String name) async {
    if (_meta.slotNames()[slotId] != name) {
      await _meta.setSlotName(slotId, name);
    }
  }

  // Apply and offers

  Future<ApplyResult> apply(
      Map<String, BackupPayload> payloads, BackupApplyMode mode) async {
    for (final p in payloads.values) {
      // The newest version wins, whatever order the slots (or polls) come
      // in: an accepted offer gets the credentials the merge chose.
      for (final r in p.records.whereType<AccountBackupRecord>()) {
        if (r.deleted) continue;
        final held = _accountRecords[r.accountId];
        if (held == null ||
            identical(
                lwwMerge([
                  [held],
                  [r]
                ]).single,
                r)) {
          _accountRecords[r.accountId] = r;
        }
      }
    }
    await beforeApply?.call(payloads);
    return applyByOrigin(_snapshot, payloads, mode: mode, nowMs: _nowMs);
  }

  /// Adds an account another device backed up, in the caller's slot.
  /// Lists the store first when its record is no longer in memory (after a
  /// restart).
  Future<void> acceptOffer(String accountId) async {
    try {
      if (!_accountRecords.containsKey(accountId) && attached) {
        await pollOnce(full: true);
      }
      final record = _accountRecords[accountId];
      if (record == null) {
        throw StateError('account $accountId is not in the backup');
      }
      if (!await _snapshot.addAccount(record)) {
        throw StateError('account $accountId could not be added');
      }
    } finally {
      refreshOffers();
    }
  }

  Future<void> dismissOffer(String accountId) async {
    final offer = _meta.pendingAccount(accountId);
    if (offer != null) await _meta.dismiss(accountId, offer.updatedAt);
    refreshOffers();
  }

  /// Republishes [pendingOffers] from the meta store.
  void refreshOffers() {
    if (!_disposed) _offers.value = _meta.pendingAccounts();
  }

  // Running operations

  Future<T> serialise<T>(Future<T> Function() op) {
    final result = _queue.then((_) => op());
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// A background operation, queued: errors become the status and a retry.
  Future<void> background(Future<void> Function() op) =>
      serialise(() => attempt(op));

  /// Runs [op] in the caller's slot, reporting failure as status.
  Future<void> attempt(Future<void> Function() op) async {
    if (!_active) return;
    try {
      await op();
      // A poll can succeed while an upload still waits for its retry: the
      // debounce has already fired, so the retry is what sends it.
      if (!_dirty) {
        _failures = 0;
        _retryTimer?.cancel();
        _retryTimer = null;
      }
      if (_status.value is BackupError) idle();
    } on BackupRelayException catch (e) {
      await _failed(e.kind, e);
    } on Object catch (e) {
      // Malformed 2xx bodies and storage failures are server-side errors.
      debugPrint('[Backup] Sync failed: ${e.runtimeType}');
      await _failed(BackupRelayError.server, null);
    }
  }

  /// Reports a failure as status and schedules a retry, backing off from 1
  /// minute to [maxBackoff].
  void reportFailure(BackupRelayError kind, [BackupRelayException? e]) =>
      unawaited(_failed(kind, e));

  Future<void> _failed(BackupRelayError kind, BackupRelayException? e) async {
    if (_disposed) return;
    final fatal = e == null ? null : handleFatal?.call(e);
    if (fatal != null) return fatal;
    if (kind == BackupRelayError.unavailable) return halt();
    _set(BackupError(kind, _lastSuccessMs));
    // A signed-out or unreachable cloud store stays so until the user acts
    // (see [resume]): nothing is retried meanwhile.
    if (kind == BackupRelayError.signedOut ||
        kind == BackupRelayError.cloudUnavailable) {
      halted = true;
      _cancelTimers();
      return;
    }
    // An oversize slot (or a full account) fails the same way until the data
    // shrinks: the next change tries again, not a timer.
    if (kind == BackupRelayError.tooLarge ||
        kind == BackupRelayError.quotaFull) {
      _tooLarge = true;
      return;
    }
    _failures++;
    var delay = Duration(minutes: 1 << min(_failures - 1, 5));
    if (delay > maxBackoff) delay = maxBackoff;
    final retryAfter = e?.retryAfterMs;
    if (retryAfter != null && retryAfter > delay.inMilliseconds) {
      delay = Duration(milliseconds: retryAfter);
    }
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(background(() async {
        await pollOnce();
        await _uploadIfDirty();
      }));
    });
  }

  /// The store is unavailable: stops every timer until a start or a user
  /// action.
  void halt() {
    halted = true;
    _cancelTimers();
    _set(const BackupUnavailable());
  }

  /// Lifts a [halt] or a signed-out or unreachable halt after the user fixed
  /// the cause (Reconnect): idle again, polling restarted. Does not poll.
  void resume() {
    if (_transport == null) return;
    halted = false;
    _failures = 0;
    _set(BackupIdle(_lastSuccessMs));
    ensurePolling();
  }

  /// Idle, unless an oversize upload is still being reported.
  void idle() {
    if (_tooLarge) return;
    _set(BackupIdle(_lastSuccessMs));
  }

  void setStatus(BackupStatus s) => _set(s);

  /// Restarts the periodic poll when attached and it is not running (after
  /// a user action lifted [halt]).
  void ensurePolling() {
    if (_transport != null && _pollTimer == null) _startPolling();
  }

  SlotTransport _require() {
    final transport = _transport;
    if (transport == null) throw StateError('backup is off');
    return transport;
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(poll()));
  }

  void _cancelTimers() {
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    _retryTimer?.cancel();
    _debounceTimer = _pollTimer = _retryTimer = null;
  }

  void _set(BackupStatus s) {
    if (!_disposed) _status.value = s;
  }
}
