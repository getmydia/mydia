import 'dart:async';

import 'package:player/core/backup/backup_records.dart';
import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/backup_sync_service.dart';
import 'package:player/core/backup/slot_transport.dart';

/// Fake [SlotTransport]. Transports sharing one [server] map see each other's
/// slots. Each write bumps a per-store counter used as the slot version and
/// the list cursor.
class InMemorySlotTransport implements SlotTransport {
  InMemorySlotTransport({required this.ownSlotId, required this.server})
    : _state = _stores[server] ??= _StoreState();

  static final _stores = Expando<_StoreState>();

  final Map<String, List<int>> server;
  final _StoreState _state;
  final _changes = StreamController<void>.broadcast();
  BackupRelayException? _failNext;

  @override
  final String ownSlotId;

  /// The next call to any method throws [e], once.
  void failNext(BackupRelayException e) => _failNext = e;

  void pushChange() => _changes.add(null);

  void _maybeFail() {
    final e = _failNext;
    if (e != null) {
      _failNext = null;
      throw e;
    }
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<SlotListing?> list({String? cursor}) async {
    _maybeFail();
    final current = '${_state.counter}';
    if (cursor == current) return null;
    final slots = [
      for (final id in server.keys.toList()..sort())
        SlotInfo(
          slotId: id,
          version: '${_state.versions[id] ?? 0}',
          deviceName: _state.names[id],
          size: server[id]!.length,
        ),
    ];
    return SlotListing(cursor: current, slots: slots);
  }

  @override
  Future<BackupPayload> read(SlotInfo slot) async {
    _maybeFail();
    final bytes = server[slot.slotId];
    if (bytes == null) throw FormatException('no slot ${slot.slotId}');
    return BackupPayload.decode(bytes);
  }

  @override
  Future<void> writeOwn(BackupPayload payload) async {
    _maybeFail();
    final bytes = payload.encode();
    if (bytes.length > BackupSyncService.maxSlotBytes) {
      throw const BackupRelayException(BackupRelayError.tooLarge);
    }
    server[ownSlotId] = bytes;
    _state.names[ownSlotId] = payload.deviceName;
    _state.versions[ownSlotId] = ++_state.counter;
  }

  @override
  Future<void> delete(String slotId) async {
    _maybeFail();
    server.remove(slotId);
    _state.names.remove(slotId);
    _state.versions.remove(slotId);
    _state.counter++;
  }
}

class _StoreState {
  int counter = 0;
  final versions = <String, int>{};
  final names = <String, String>{};
}
