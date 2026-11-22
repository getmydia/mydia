import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// One file in the fake appDataFolder.
class FakeDriveFile {
  FakeDriveFile(this.id, this.name, this.appProperties);

  final String id;
  String name;
  Map<String, String> appProperties;
  List<int> bytes = const [];
  int version = 0;
  DateTime modified = DateTime.utc(2026, 1, 1);
}

/// A canned error for the next matching request.
class FakeDriveFailure {
  FakeDriveFailure(this.status, {this.body = '', this.headers = const {}});

  final int status;
  final String body;
  final Map<String, String> headers;
}

/// In-memory Drive v3 `appDataFolder` behind a [MockClient]. It asserts the
/// request shapes the backend must send: bearer token, `spaces`, `fields`,
/// and multipart/related bodies (JSON metadata part, then the media part).
class FakeDriveServer {
  static const listFields =
      'files(id,name,version,modifiedTime,size,appProperties),nextPageToken';

  final files = <String, FakeDriveFile>{};
  int _nextId = 1;
  int _clock = 0;

  /// The access token the server accepts.
  String validToken = 'token-1';

  /// Page size the server applies, whatever `pageSize` asks for.
  int? pageLimit;

  /// Every request as `METHOD path`, in order.
  final requests = <String>[];

  /// Failures served to the next requests whose `METHOD path` contains the
  /// key, once each.
  final failures = <String, List<FakeDriveFailure>>{};

  /// Throws this instead of answering, once.
  Exception? throwNext;

  late final MockClient client = MockClient(_handle);

  void failOnce(String match, FakeDriveFailure f) =>
      failures.putIfAbsent(match, () => []).add(f);

  http.Response _json(
    int status,
    Object body, {
    Map<String, String> headers = const {},
  }) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json', ...headers},
  );

  Future<http.Response> _handle(http.Request r) async {
    final key = '${r.method} ${r.url.path}';
    requests.add(key);
    final thrown = throwNext;
    if (thrown != null) {
      throwNext = null;
      throw thrown;
    }
    if (r.headers['Authorization'] != 'Bearer $validToken') {
      return _json(401, {
        'error': {'code': 401, 'status': 'UNAUTHENTICATED'},
      });
    }
    for (final entry in failures.entries) {
      if (key.contains(entry.key) && entry.value.isNotEmpty) {
        final f = entry.value.removeAt(0);
        return http.Response(f.body, f.status, headers: f.headers);
      }
    }
    final path = r.url.path;
    if (path == '/drive/v3/files' && r.method == 'GET') return _list(r);
    if (path == '/upload/drive/v3/files' && r.method == 'POST') {
      return _upload(r, null);
    }
    final upload = RegExp(r'^/upload/drive/v3/files/([^/]+)$').firstMatch(path);
    if (upload != null && r.method == 'PATCH') {
      return _upload(r, upload.group(1));
    }
    final one = RegExp(r'^/drive/v3/files/([^/]+)$').firstMatch(path);
    if (one != null) {
      final file = files[one.group(1)];
      if (file == null) {
        return _json(404, {
          'error': {'code': 404, 'status': 'NOT_FOUND'},
        });
      }
      if (r.method == 'GET') {
        expectParam(r, 'alt', 'media');
        return http.Response.bytes(file.bytes, 200);
      }
      if (r.method == 'DELETE') {
        files.remove(file.id);
        return http.Response('', 204);
      }
    }
    throw StateError('Unexpected request: $key');
  }

  void expectParam(http.Request r, String name, String value) {
    if (r.url.queryParameters[name] != value) {
      throw StateError('Expected $name=$value in ${r.url}');
    }
  }

  http.Response _list(http.Request r) {
    expectParam(r, 'spaces', 'appDataFolder');
    expectParam(r, 'fields', listFields);
    final asked = int.parse(r.url.queryParameters['pageSize']!);
    final size = pageLimit ?? asked;
    final all = files.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    final start = int.tryParse(r.url.queryParameters['pageToken'] ?? '') ?? 0;
    final page = all.skip(start).take(size).toList();
    final more = start + page.length < all.length;
    return _json(200, {
      'files': [
        for (final f in page)
          {
            'id': f.id,
            'name': f.name,
            'version': '${f.version}',
            'modifiedTime': f.modified.toIso8601String(),
            'size': '${f.bytes.length}',
            'appProperties': f.appProperties,
          },
      ],
      if (more) 'nextPageToken': '${start + page.length}',
    });
  }

  http.Response _upload(http.Request r, String? id) {
    expectParam(r, 'uploadType', 'multipart');
    final type = r.headers['Content-Type'] ?? '';
    final m = RegExp(r'^multipart/related; boundary=(.+)$').firstMatch(type);
    if (m == null) throw StateError('Not multipart/related: $type');
    final parts = _parts(r.bodyBytes, m.group(1)!);
    if (parts.length != 2) throw StateError('Expected 2 parts');
    if (!parts[0].header.contains('application/json')) {
      throw StateError('First part is not JSON metadata');
    }
    final meta = jsonDecode(utf8.decode(parts[0].body)) as Map<String, dynamic>;
    FakeDriveFile? file;
    if (id == null) {
      if (meta['parents'] is! List ||
          (meta['parents'] as List).single != 'appDataFolder') {
        throw StateError('Create needs parents: [appDataFolder]');
      }
      final slot = (meta['appProperties'] as Map?)?['slotId'];
      if (meta['name'] != 'slot-$slot.json.gz') {
        throw StateError('Bad file name: ${meta['name']}');
      }
      final newId = 'file-${_nextId++}';
      file = files[newId] = FakeDriveFile(newId, meta['name'] as String, {});
    } else {
      file = files[id];
      if (meta.containsKey('parents')) {
        throw StateError('Update must not send parents');
      }
      if (file == null) {
        return _json(404, {
          'error': {'code': 404, 'status': 'NOT_FOUND'},
        });
      }
    }
    if (meta['name'] != null) file.name = meta['name'] as String;
    file.appProperties = {
      ...file.appProperties,
      ...(meta['appProperties'] as Map<String, dynamic>? ?? {}).map(
        (k, v) => MapEntry(k, v as String),
      ),
    };
    file.bytes = parts[1].body;
    file.version = ++_clock;
    file.modified = DateTime.utc(2026, 1, 1).add(Duration(minutes: _clock));
    return _json(200, {'id': file.id, 'name': file.name});
  }

  List<({String header, List<int> body})> _parts(
    List<int> body,
    String boundary,
  ) {
    final text = latin1.decode(body);
    final delim = '--$boundary';
    final out = <({String header, List<int> body})>[];
    var pos = text.indexOf(delim);
    while (pos >= 0) {
      final after = pos + delim.length;
      if (text.startsWith('--', after)) break;
      final next = text.indexOf('\r\n$delim', after);
      final chunk = text.substring(after + 2, next);
      final split = chunk.indexOf('\r\n\r\n');
      out.add((
        header: chunk.substring(0, split),
        body: latin1.encode(chunk.substring(split + 4)),
      ));
      pos = next + 2;
    }
    return out;
  }
}
