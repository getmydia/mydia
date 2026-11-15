import '../slot_transport.dart';

/// A cloud store the backup can live in. [name] is the store id written in
/// a moved stub (`movedTo`).
enum CloudStoreKind { icloud, gdrive }

/// Whether a [CloudBackend] can be used now.
sealed class CloudAvailability {
  const CloudAvailability();
}

/// Signed in; [accountLabel] names the account for the status line (the
/// Google email). Null when the store has no name to show (iCloud).
class CloudAvailable extends CloudAvailability {
  const CloudAvailable(this.accountLabel);

  final String? accountLabel;
}

/// No account is signed in, or its grant was revoked.
class CloudSignedOut extends CloudAvailability {
  const CloudSignedOut();
}

/// The service is unreachable or disabled on this device.
class CloudUnavailable extends CloudAvailability {
  const CloudUnavailable();
}

/// A [SlotListing] without `ownStale`: a cloud store has no epochs.
class CloudListing {
  const CloudListing({required this.cursor, required this.slots});

  /// Pass back to [CloudBackend.list]; null means the store is never
  /// conditional.
  final String? cursor;

  /// Every slot, this device's own included.
  final List<SlotInfo> slots;
}

/// One cloud provider's per-device slot files, as raw bytes. Every method
/// that reaches the store throws `BackupRelayException` with the cloud kinds
/// (`signedOut`, `quotaFull`, `cloudUnavailable`) or the generic ones
/// (`network`, `rateLimited`, `server`, `notFound`).
abstract class CloudBackend {
  CloudStoreKind get kind;

  Future<CloudAvailability> availability();

  /// Null means unchanged since [cursor].
  Future<CloudListing?> list({String? cursor});

  Future<List<int>> readBytes(String slotId);

  Future<void> writeBytes(String slotId, List<int> bytes,
      {required String deviceName, required String platform});

  Future<void> delete(String slotId);

  /// Emits when the store may have changed remotely (CloudKit pushes; Drive
  /// never emits).
  Stream<void> get changes;

  /// Forgets the local credentials only; the store is untouched.
  Future<void> signOut();
}
