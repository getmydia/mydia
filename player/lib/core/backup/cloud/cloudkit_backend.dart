import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import '../backup_meta_store.dart';
import '../backup_relay_client.dart';
import '../slot_transport.dart';
import 'cloud_backend.dart';

/// A [CloudBackend] over the iCloud private database, through the Swift
/// `CloudKitPlugin` in the iOS and macOS Runner targets. Each device's slot
/// is one `Slot` record named `slot-<slotId>` in the `Backup` zone of
/// container `iCloud.dev.mydia.player`.
///
/// Listing is incremental: the zone's change token and the slot table it
/// describes are kept in [BackupMetaStore], so a poll fetches only what
/// changed. The token is also the listing cursor.
///
/// Only constructed on iOS and macOS; it holds no platform checks itself.
class CloudKitBackend implements CloudBackend {
  CloudKitBackend({
    MethodChannel? channel,
    EventChannel? events,
    required this._meta,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _events = events ?? const EventChannel(eventChannelName);

  static const channelName = 'mydia/cloudkit';
  static const eventChannelName = 'mydia/cloudkit/changes';

  final MethodChannel _channel;
  final EventChannel _events;
  final BackupMetaStore _meta;

  /// Whether this instance saved the database subscription already.
  bool _subscribed = false;
  bool _pendingPush = false;

  late final Stream<void> _changes = _events.receiveBroadcastStream().map((
    event,
  ) {
    if (event == 'push') _pendingPush = true;
  });

  /// Acknowledges a pending push notification to the native plugin with the
  /// background poll outcome (`newData`, `noData`, or `failed`).
  Future<void> completePush(String result) async {
    if (!_pendingPush) return;
    _pendingPush = false;
    try {
      await _channel.invokeMethod<void>('completePush', {'result': result});
    } on PlatformException {
      // Best-effort completion; native timeout cleans up otherwise.
    } on MissingPluginException {
      // Non-Apple or test host without channel handler.
    }
  }

  /// Whether this build carries iCloud (it is opt-in per build; see
  /// docs/packaging.md), for gating the iCloud option. False on any error,
  /// and where there is no plugin (every platform but iOS and macOS).
  static Future<bool> isEnabled({MethodChannel? channel}) async {
    try {
      return await (channel ?? const MethodChannel(channelName))
              .invokeMethod<bool>('isEnabled') ??
          false;
    } catch (e) {
      return false;
    }
  }

  @override
  CloudStoreKind get kind => CloudStoreKind.icloud;

  /// iCloud has no account name to show, so the label is null. A build
  /// without iCloud (`disabled`) and a signed-out or restricted account are
  /// [CloudUnavailable]; a transient error reaching the account status
  /// throws instead (`network` or `rateLimited`), so it is retried rather
  /// than halting until Reconnect.
  @override
  Future<CloudAvailability> availability() async {
    try {
      await _requireAccount();
      return const CloudAvailable(null);
    } on BackupRelayException catch (e) {
      if (e.kind == BackupRelayError.network ||
          e.kind == BackupRelayError.rateLimited) {
        rethrow;
      }
      return const CloudUnavailable();
    }
  }

  @override
  Future<CloudListing?> list({String? cursor}) async {
    await _requireAccount();
    final before = _meta.cloudkitToken;
    var table = _readTable();
    // A missing token or unreadable table cannot be applied to: start over.
    var reset = before == null || table == null;
    if (reset && (before != null || table != null)) await _forgetZone();
    if (reset) table = null;
    Map<String, Object?> result;
    try {
      result = await _fetchChanges(reset ? null : before);
    } on PlatformException catch (e) {
      if (e.code != 'changeTokenExpired' && e.code != 'zoneNotFound') {
        throw _error(e);
      }
      // The token no longer applies (expired, or the zone was deleted and
      // recreated): what the table holds is unknown, so start over once.
      if (reset) throw _error(e);
      await _forgetZone();
      reset = true;
      try {
        result = await _fetchChanges(null);
      } on PlatformException catch (e) {
        throw _error(e);
      }
    }

    if (reset) table = null;
    table ??= <String, SlotInfo>{};
    final records = (result['records'] as List? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((m) => m.cast<String, Object?>());
    final deleted = (result['deleted'] as List? ?? const [])
        .whereType<String>();
    var changed = reset;
    for (final r in records) {
      final info = _slotInfo(r);
      if (info == null) continue;
      table[info.slotId] = info;
      changed = true;
    }
    for (final id in deleted) {
      table.remove(id);
      changed = true;
    }
    final token = result['token'] as String?;
    // Table first: a crash between the two refetches the same changes.
    await _meta.setCloudkitSlots(_encodeTable(table));
    await _meta.setCloudkitToken(token);
    await _subscribeOnce();

    if (cursor != null && cursor == before && !changed) return null;
    return CloudListing(cursor: token, slots: table.values.toList());
  }

  @override
  Future<List<int>> readBytes(String slotId) async {
    final Object? bytes;
    try {
      bytes = await _channel.invokeMethod<Object?>('fetchPayload', {
        'slotId': slotId,
      });
    } on PlatformException catch (e) {
      if (e.code == 'zoneNotFound') {
        throw const BackupRelayException(BackupRelayError.notFound);
      }
      throw _error(e);
    } on MissingPluginException {
      throw const BackupRelayException(BackupRelayError.cloudUnavailable);
    }
    if (bytes == null) {
      throw const BackupRelayException(BackupRelayError.notFound);
    }
    if (bytes is! Uint8List) {
      throw const BackupRelayException(BackupRelayError.server);
    }
    return bytes;
  }

  @override
  Future<void> writeBytes(
    String slotId,
    List<int> bytes, {
    required String deviceName,
    required String platform,
  }) => _invoke('save', {
    'slotId': slotId,
    'deviceName': deviceName,
    'platform': platform,
    'bytes': bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
  });

  /// A missing record (or zone) is already deleted: success.
  @override
  Future<void> delete(String slotId) async {
    try {
      await _channel.invokeMethod<void>('delete', {'slotId': slotId});
    } on PlatformException catch (e) {
      if (e.code == 'zoneNotFound') return;
      throw _error(e);
    } on MissingPluginException {
      throw const BackupRelayException(BackupRelayError.cloudUnavailable);
    }
  }

  /// Emits on each CloudKit silent push and on an iCloud account change.
  @override
  Stream<void> get changes => _changes;

  /// There is no iCloud sign-out from the app: forgets the token, the slot
  /// table and the account they belong to.
  @override
  Future<void> signOut() async {
    await _forgetZone();
    await _meta.setCloudkitUser(null);
    _subscribed = false;
  }

  // Internals

  /// Throws `cloudUnavailable` unless iCloud is signed in and usable. A
  /// different account than the one the token was fetched under drops the
  /// token, the table and the stored user first.
  Future<void> _requireAccount() async {
    final Map<String, Object?> status;
    try {
      status =
          (await _channel.invokeMapMethod<String, Object?>('accountStatus')) ??
          const {};
    } on PlatformException catch (e) {
      throw _error(e);
    } on MissingPluginException {
      throw const BackupRelayException(BackupRelayError.cloudUnavailable);
    }
    if (status['status'] == 'temporarilyUnavailable') {
      throw const BackupRelayException(BackupRelayError.network);
    }
    if (status['status'] != 'available') {
      throw const BackupRelayException(BackupRelayError.cloudUnavailable);
    }
    final user = status['userRecordName'] as String?;
    if (user == null) return;
    final stored = _meta.cloudkitUser;
    if (stored == user) return;
    if (stored != null) {
      debugPrint('[Backup] iCloud account changed; listing from scratch');
      await _forgetZone();
      _subscribed = false;
    }
    await _meta.setCloudkitUser(user);
  }

  Future<Map<String, Object?>> _fetchChanges(String? token) async {
    try {
      return (await _channel.invokeMapMethod<String, Object?>('fetchChanges', {
            'token': token,
          })) ??
          const {};
    } on MissingPluginException {
      throw const BackupRelayException(BackupRelayError.cloudUnavailable);
    }
  }

  /// Saves the `backup-changes` database subscription once per instance and
  /// account. Best effort: without it the engine still polls.
  Future<void> _subscribeOnce() async {
    if (_subscribed) return;
    try {
      await _channel.invokeMethod<void>('subscribe');
      _subscribed = true;
    } on PlatformException catch (e) {
      debugPrint('[Backup] CloudKit subscribe failed: ${e.code}');
    } on MissingPluginException {
      // Nothing to subscribe through.
    }
  }

  Future<void> _forgetZone() async {
    await _meta.setCloudkitToken(null);
    await _meta.setCloudkitSlots(null);
  }

  Future<void> _invoke(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      throw _error(e);
    } on MissingPluginException {
      throw const BackupRelayException(BackupRelayError.cloudUnavailable);
    }
  }

  /// The plugin's error codes as [BackupRelayError] kinds. A `network`
  /// error that carries `retryAfterMs` (CloudKit rate limiting or a busy
  /// service) is [BackupRelayError.rateLimited].
  BackupRelayException _error(PlatformException e) {
    switch (e.code) {
      case 'notAuthenticated':
      case 'unavailable':
        return const BackupRelayException(BackupRelayError.cloudUnavailable);
      case 'quotaExceeded':
        return const BackupRelayException(BackupRelayError.quotaFull);
      case 'network':
        final details = e.details;
        final retry = details is Map
            ? (details['retryAfterMs'] as num?)?.toInt()
            : null;
        return retry == null
            ? const BackupRelayException(BackupRelayError.network)
            : BackupRelayException(
                BackupRelayError.rateLimited,
                retryAfterMs: retry,
              );
      default:
        return const BackupRelayException(BackupRelayError.server);
    }
  }

  SlotInfo? _slotInfo(Map<String, Object?> r) {
    final slotId = r['slotId'];
    final tag = r['tag'];
    if (slotId is! String || tag is! String) return null;
    return SlotInfo(
      slotId: slotId,
      version: tag,
      deviceName: r['deviceName'] as String?,
      updatedAtMs: (r['updatedAt'] as num?)?.toInt(),
      size: (r['size'] as num?)?.toInt(),
    );
  }

  /// The stored slot table; null when none is stored or it is unreadable.
  Map<String, SlotInfo>? _readTable() {
    final raw = _meta.cloudkitSlots;
    if (raw == null) return null;
    try {
      final json = (jsonDecode(raw) as Map).cast<String, Object?>();
      return {
        for (final e in json.entries)
          if (e.value is Map)
            e.key: ?_slotInfo({
              'slotId': e.key,
              ...(e.value as Map).cast<String, Object?>(),
            }),
      };
    } catch (e) {
      debugPrint('[Backup] Unreadable CloudKit slot table: ${e.runtimeType}');
      return null;
    }
  }

  String _encodeTable(Map<String, SlotInfo> table) => jsonEncode({
    for (final s in table.values)
      s.slotId: {
        'tag': s.version,
        'deviceName': s.deviceName,
        'updatedAt': s.updatedAtMs,
        'size': s.size,
      },
  });
}
