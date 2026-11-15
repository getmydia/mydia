import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../backup_meta_store.dart';
import '../backup_relay_client.dart';
import '../slot_transport.dart';
import 'cloud_backend.dart';
import 'google_auth.dart';

/// A [CloudBackend] over Drive v3's hidden `appDataFolder`. Each device's
/// slot is one file named `slot-<slotId>.json.gz`, tagged with `appProperties`
/// `slotId` and `deviceName`.
class GoogleDriveBackend implements CloudBackend {
  GoogleDriveBackend({
    required GoogleAuth auth,
    required http.Client client,
    required BackupMetaStore meta,
  })  : _auth = auth,
        _client = client,
        _meta = meta;

  static const _filesUrl = 'https://www.googleapis.com/drive/v3/files';
  static const _uploadUrl = 'https://www.googleapis.com/upload/drive/v3/files';
  static const _listFields =
      'files(id,name,version,modifiedTime,size,appProperties),nextPageToken';
  static const _timeout = Duration(seconds: 30);

  final GoogleAuth _auth;
  final http.Client _client;
  final BackupMetaStore _meta;

  /// Slot id to the newest Drive file id, from the last listing.
  final _fileIds = <String, String>{};

  /// Slot id to every Drive file id seen for that slot, for complete delete.
  final _allFileIds = <String, List<String>>{};

  @override
  CloudStoreKind get kind => CloudStoreKind.gdrive;

  @override
  Future<CloudAvailability> availability() async {
    final email = await _auth.currentEmail();
    return email == null ? const CloudSignedOut() : CloudAvailable(email);
  }

  @override
  Future<CloudListing?> list({String? cursor}) async {
    final files = <Map<String, dynamic>>[];
    String? pageToken;
    do {
      final uri = Uri.parse(_filesUrl).replace(queryParameters: {
        'spaces': 'appDataFolder',
        'fields': _listFields,
        'pageSize': '100',
        if (pageToken != null) 'pageToken': pageToken,
      });
      final r = await _send('GET', uri);
      _expectOk(r);
      final json = _decodeObject(r.body);
      files.addAll(
          (json['files'] as List? ?? const []).cast<Map<String, dynamic>>());
      pageToken = json['nextPageToken'] as String?;
    } while (pageToken != null);

    final pairs = [
      for (final f in files) '${f['name']}:${f['id']}:${f['version']}',
    ]..sort();
    final current = sha256.convert(utf8.encode(pairs.join('\n'))).toString();

    // Several files may carry one slotId (a lost cached id used to create
    // a second); the newest by modifiedTime stands for the slot.
    final newest = <String, SlotInfo>{};
    final newestFile = <String, String>{};
    final allFiles = <String, List<String>>{};
    for (final f in files) {
      final props = (f['appProperties'] as Map?)?.cast<String, dynamic>();
      final slotId = props?['slotId'] as String?;
      if (slotId == null) continue;
      final fileId = f['id'] as String;
      (allFiles[slotId] ??= []).add(fileId);
      final info = SlotInfo(
        slotId: slotId,
        version: '$fileId:${f['version']}',
        deviceName: props?['deviceName'] as String?,
        updatedAtMs:
            DateTime.tryParse('${f['modifiedTime']}')?.millisecondsSinceEpoch,
        size: int.tryParse('${f['size']}'),
      );
      final seen = newest[slotId];
      if (seen != null && (info.updatedAtMs ?? 0) <= (seen.updatedAtMs ?? 0)) {
        continue;
      }
      newest[slotId] = info;
      newestFile[slotId] = fileId;
    }
    _fileIds
      ..clear()
      ..addAll(newestFile);
    _allFileIds
      ..clear()
      ..addAll(allFiles);
    if (cursor == current) return null;
    return CloudListing(cursor: current, slots: newest.values.toList());
  }

  @override
  Future<List<int>> readBytes(String slotId) async {
    var id = _fileIds[slotId];
    if (id == null) {
      await list();
      id = _fileIds[slotId];
    }
    if (id == null) throw const BackupRelayException(BackupRelayError.notFound);
    final uri =
        Uri.parse('$_filesUrl/$id').replace(queryParameters: {'alt': 'media'});
    final r = await _send('GET', uri);
    if (r.statusCode == 404) {
      _fileIds.remove(slotId);
      throw const BackupRelayException(BackupRelayError.notFound);
    }
    _expectOk(r);
    return r.bodyBytes;
  }

  @override
  Future<void> writeBytes(String slotId, List<int> bytes,
      {required String deviceName, required String platform}) async {
    final cached = _meta.gdriveOwnFileId;
    if (cached != null) {
      final r = await _upload('PATCH', cached, slotId, bytes, deviceName);
      if (r.statusCode != 404) {
        _expectOk(r);
        return;
      }
      await _meta.setGdriveOwnFileId(null);
    }
    // No cached id (first write, or the meta store was lost): reuse the
    // file a fresh listing already holds for this slot before creating.
    await list();
    final existing = _fileIds[slotId];
    if (existing != null) {
      final r = await _upload('PATCH', existing, slotId, bytes, deviceName);
      if (r.statusCode != 404) {
        _expectOk(r);
        await _meta.setGdriveOwnFileId(existing);
        return;
      }
    }
    final r = await _upload('POST', null, slotId, bytes, deviceName);
    _expectOk(r);
    final id = _decodeObject(r.body)['id'] as String?;
    if (id == null) throw const BackupRelayException(BackupRelayError.server);
    await _meta.setGdriveOwnFileId(id);
    _fileIds[slotId] = id;
  }

  @override
  Future<void> delete(String slotId) async {
    var ids = _allFileIds[slotId];
    if (ids == null || ids.isEmpty) {
      final cached = _fileIds[slotId];
      if (cached != null) {
        ids = [cached];
      } else {
        await list();
        ids = _allFileIds[slotId];
      }
    }
    if (ids == null || ids.isEmpty) return;
    for (final id in ids.toList()) {
      final r = await _send('DELETE', Uri.parse('$_filesUrl/$id'));
      if (r.statusCode != 404) _expectOk(r);
      if (_meta.gdriveOwnFileId == id) await _meta.setGdriveOwnFileId(null);
    }
    _fileIds.remove(slotId);
    _allFileIds.remove(slotId);
  }

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<void> signOut() async {
    await _auth.signOut();
    await _meta.setGdriveOwnFileId(null);
    _fileIds.clear();
  }

  Future<http.Response> _upload(String method, String? fileId, String slotId,
      List<int> bytes, String deviceName) {
    final boundary =
        'mydia-${Random.secure().nextInt(1 << 32).toRadixString(36)}'
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final metadata = jsonEncode({
      if (fileId == null) 'name': 'slot-$slotId.json.gz',
      if (fileId == null) 'parents': ['appDataFolder'],
      'appProperties': {'slotId': slotId, 'deviceName': deviceName},
    });
    final body = <int>[
      ...utf8.encode('--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '$metadata\r\n'
          '--$boundary\r\n'
          'Content-Type: application/gzip\r\n\r\n'),
      ...bytes,
      ...utf8.encode('\r\n--$boundary--\r\n'),
    ];
    final uri = Uri.parse(fileId == null ? _uploadUrl : '$_uploadUrl/$fileId')
        .replace(queryParameters: {'uploadType': 'multipart'});
    return _send(method, uri,
        body: body, contentType: 'multipart/related; boundary=$boundary');
  }

  /// Sends one request; a 401 is retried once with a refreshed token.
  Future<http.Response> _send(String method, Uri uri,
      {List<int>? body, String? contentType}) async {
    var r = await _once(method, uri, body, contentType, false);
    if (r.statusCode == 401) {
      r = await _once(method, uri, body, contentType, true);
      if (r.statusCode == 401) {
        throw const BackupRelayException(BackupRelayError.signedOut);
      }
    }
    return r;
  }

  Future<http.Response> _once(String method, Uri uri, List<int>? body,
      String? contentType, bool forceRefresh) async {
    final token = await _auth.accessToken(forceRefresh: forceRefresh);
    final req = http.Request(method, uri)
      ..headers['Authorization'] = 'Bearer $token';
    if (contentType != null) req.headers['Content-Type'] = contentType;
    if (body != null) req.bodyBytes = body;
    try {
      final streamed = await _client.send(req).timeout(_timeout);
      return await http.Response.fromStream(streamed).timeout(_timeout);
    } on SocketException {
      throw const BackupRelayException(BackupRelayError.network);
    } on TimeoutException {
      throw const BackupRelayException(BackupRelayError.network);
    } on http.ClientException {
      throw const BackupRelayException(BackupRelayError.network);
    }
  }

  Map<String, dynamic> _decodeObject(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map<String, dynamic>) return json;
    } on FormatException {
      // Falls through to the server error.
    }
    throw const BackupRelayException(BackupRelayError.server);
  }

  void _expectOk(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    throw _errorFor(r);
  }

  BackupRelayException _errorFor(http.Response r) {
    final secs = int.tryParse(r.headers['retry-after'] ?? '');
    BackupRelayException rateLimited() =>
        BackupRelayException(BackupRelayError.rateLimited,
            retryAfterMs: secs == null ? null : secs * 1000);
    switch (r.statusCode) {
      case 404:
        return const BackupRelayException(BackupRelayError.notFound);
      case 429:
        return rateLimited();
      case 403:
        final reasons = _reasons(r.body);
        if (reasons.contains('storageQuotaExceeded')) {
          return const BackupRelayException(BackupRelayError.quotaFull);
        }
        if (reasons.contains('rateLimitExceeded') ||
            reasons.contains('userRateLimitExceeded')) {
          return rateLimited();
        }
        // The token lacks drive.appdata (the box was unticked on Google's
        // granular consent screen): signed out, so the UI offers Reconnect
        // instead of backing off on a server error forever.
        if (reasons.contains('insufficientPermissions') ||
            reasons.contains('ACCESS_TOKEN_SCOPE_INSUFFICIENT')) {
          return const BackupRelayException(BackupRelayError.signedOut,
              code: googleScopeMissingCode);
        }
        return const BackupRelayException(BackupRelayError.server);
      default:
        return const BackupRelayException(BackupRelayError.server);
    }
  }

  /// `error.errors[0].reason`, `error.status` and every
  /// `error.details[].reason` of a Drive error body.
  Set<String> _reasons(String body) {
    try {
      final error = (jsonDecode(body) as Map)['error'];
      if (error is! Map) return {};
      final errors = error['errors'];
      final details = error['details'];
      return {
        if (errors is List && errors.isNotEmpty && errors.first is Map)
          if ((errors.first as Map)['reason'] is String)
            (errors.first as Map)['reason'] as String,
        if (error['status'] is String) error['status'] as String,
        if (details is List)
          for (final d in details)
            if (d is Map && d['reason'] is String) d['reason'] as String,
      };
    } catch (_) {
      return {};
    }
  }
}
