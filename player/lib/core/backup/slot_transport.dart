import 'backup_records.dart';

/// One device's backup slot as a store lists it.
class SlotInfo {
  const SlotInfo({
    required this.slotId,
    required this.version,
    this.deviceName,
    this.updatedAtMs,
    this.size,
  });

  final String slotId;

  /// Opaque; changes on every write.
  final String version;
  final String? deviceName;
  final int? updatedAtMs;
  final int? size;
}

class SlotListing {
  const SlotListing({
    required this.cursor,
    required this.slots,
    this.ownStale = false,
  });

  /// Pass back to [SlotTransport.list]; null means the store is never
  /// conditional.
  final String? cursor;

  /// Includes this device's own slot when present.
  final List<SlotInfo> slots;

  /// The engine must force an upload (relay: own epoch is below the vault
  /// epoch).
  final bool ownStale;
}

/// A store of per-device backup slots, independent of where they live (relay,
/// cloud drive, CloudKit). Payloads are plaintext here; sealing is the
/// engine's concern.
abstract class SlotTransport {
  String get ownSlotId;

  /// Null means unchanged since [cursor].
  Future<SlotListing?> list({String? cursor});

  /// Throws [FormatException] when the slot is undecodable.
  Future<BackupPayload> read(SlotInfo slot);

  /// Throws `BackupRelayException(BackupRelayError.tooLarge)` when the encoded
  /// payload exceeds 4194304 bytes.
  Future<void> writeOwn(BackupPayload payload);

  Future<void> delete(String slotId);

  /// Emits when the store may have changed remotely.
  Stream<void> get changes;
}
