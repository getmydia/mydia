import 'dart:async';

import 'package:player/core/backup/backup_relay_client.dart';
import 'package:player/core/backup/cloud/cloud_backend.dart';
import 'package:player/core/backup/slot_transport.dart';

/// One cloud account's slot files, shared by every [InMemoryCloudBackend]
/// signed in to it. Each write or delete bumps [counter], which is both the
/// slot version and the list cursor.
class InMemoryCloudStore {
  int counter = 0;
  final bytes = <String, List<int>>{};
  final versions = <String, int>{};
  final names = <String, String>{};
  final platforms = <String, String>{};
  final writes = <String, int>{};
  final deletes = <String>[];
}

/// Fake [CloudBackend] over an [InMemoryCloudStore].
class InMemoryCloudBackend implements CloudBackend {
  InMemoryCloudBackend(
    this.store, {
    this.kind = CloudStoreKind.gdrive,
    this.accountLabel = 'ana@example.com',
  });

  final InMemoryCloudStore store;

  @override
  final CloudStoreKind kind;

  final String accountLabel;

  bool signedIn = true;
  bool reachable = true;
  int signOuts = 0;

  /// Runs at the start of every [readBytes], as when another device acts
  /// between a listing and a read.
  Future<void> Function(String slotId)? beforeRead;
  BackupRelayException? _failNext;
  final _changes = StreamController<void>.broadcast();

  /// The next call that touches the store throws [e], once.
  void failNext(BackupRelayException e) => _failNext = e;

  void pushChange() => _changes.add(null);

  void _maybeFail() {
    final e = _failNext;
    if (e != null) {
      _failNext = null;
      throw e;
    }
    if (!signedIn) throw const BackupRelayException(BackupRelayError.signedOut);
    if (!reachable) {
      throw const BackupRelayException(BackupRelayError.cloudUnavailable);
    }
  }

  @override
  Future<CloudAvailability> availability() async {
    if (!signedIn) return const CloudSignedOut();
    if (!reachable) return const CloudUnavailable();
    return CloudAvailable(accountLabel);
  }

  @override
  Future<CloudListing?> list({String? cursor}) async {
    _maybeFail();
    final current = '${store.counter}';
    if (cursor == current) return null;
    return CloudListing(
      cursor: current,
      slots: [
        for (final id in store.bytes.keys.toList()..sort())
          SlotInfo(
            slotId: id,
            version: '${store.versions[id]}',
            deviceName: store.names[id],
            size: store.bytes[id]!.length,
          ),
      ],
    );
  }

  @override
  Future<List<int>> readBytes(String slotId) async {
    _maybeFail();
    await beforeRead?.call(slotId);
    final b = store.bytes[slotId];
    if (b == null) throw const BackupRelayException(BackupRelayError.notFound);
    return b;
  }

  @override
  Future<void> writeBytes(
    String slotId,
    List<int> bytes, {
    required String deviceName,
    required String platform,
  }) async {
    _maybeFail();
    store.bytes[slotId] = List.of(bytes);
    store.names[slotId] = deviceName;
    store.platforms[slotId] = platform;
    store.versions[slotId] = ++store.counter;
    store.writes[slotId] = (store.writes[slotId] ?? 0) + 1;
  }

  @override
  Future<void> delete(String slotId) async {
    _maybeFail();
    if (store.bytes.remove(slotId) == null) return;
    store.names.remove(slotId);
    store.platforms.remove(slotId);
    store.versions.remove(slotId);
    store.deletes.add(slotId);
    store.counter++;
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<void> signOut() async {
    signOuts++;
    signedIn = false;
  }
}
