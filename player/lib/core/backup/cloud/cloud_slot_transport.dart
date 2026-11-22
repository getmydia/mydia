import '../backup_records.dart';
import '../backup_relay_client.dart';
import '../slot_transport.dart';
import 'cloud_backend.dart';
import 'cloudkit_backend.dart';

/// [records] without the p2p group record: the group secret is never
/// written to a cloud store, where it would sit in plaintext.
List<BackupRecord> withoutGroupRecords(List<BackupRecord> records) => [
  for (final r in records)
    if (r is! GroupBackupRecord) r,
];

/// A [CloudBackend] as a [SlotTransport]. Slots are stored as plaintext
/// gzip JSON ([BackupPayload.encode]): the provider is trusted.
class CloudSlotTransport implements SlotTransport {
  CloudSlotTransport(this.backend, this.ownSlotId);

  /// The same cap as the relay's, so a slot fits every store.
  static const maxSlotBytes = 4194304;

  final CloudBackend backend;

  @override
  final String ownSlotId;

  /// Reports this device's slot as stale when it is missing from the
  /// listing (another device removed it), so the engine writes it again.
  @override
  Future<SlotListing?> list({String? cursor}) async {
    final l = await backend.list(cursor: cursor);
    if (l == null) return null;
    return SlotListing(
      cursor: l.cursor,
      slots: l.slots,
      ownStale: !l.slots.any((s) => s.slotId == ownSlotId),
    );
  }

  @override
  Future<BackupPayload> read(SlotInfo slot) async =>
      BackupPayload.decode(await backend.readBytes(slot.slotId));

  /// Drops any group record, whatever the caller passed.
  @override
  Future<void> writeOwn(BackupPayload payload) async {
    final bytes = BackupPayload(
      deviceName: payload.deviceName,
      platform: payload.platform,
      createdAt: payload.createdAt,
      records: withoutGroupRecords(payload.records),
      movedTo: payload.movedTo,
    ).encode();
    if (bytes.length > maxSlotBytes) {
      throw const BackupRelayException(BackupRelayError.tooLarge);
    }
    await backend.writeBytes(
      ownSlotId,
      bytes,
      deviceName: payload.deviceName,
      platform: payload.platform,
    );
  }

  @override
  Future<void> delete(String slotId) => backend.delete(slotId);

  @override
  Stream<void> get changes => backend.changes;

  /// Delivers the background fetch completion outcome to the native plugin
  /// when a CloudKit silent push triggered the poll.
  Future<void> completePush(String outcome) async {
    final b = backend;
    if (b is CloudKitBackend) await b.completePush(outcome);
  }
}
