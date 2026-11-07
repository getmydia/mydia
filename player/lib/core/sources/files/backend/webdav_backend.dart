import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'file_system_backend.dart';

/// How long a WebDAV request may take before the server counts as
/// unreachable.
const kWebDavTimeout = Duration(seconds: 20);

const _propfindBody = '<?xml version="1.0" encoding="utf-8"?>'
    '<d:propfind xmlns:d="DAV:"><d:prop>'
    '<d:resourcetype/><d:getcontentlength/><d:getlastmodified/>'
    '</d:prop></d:propfind>';

/// Reads media from a WebDAV server with HTTP Basic auth.
class WebDavBackend implements FileSystemBackend {
  WebDavBackend({
    required Uri base,
    required String user,
    required String password,
    http.Client? client,
    Duration timeout = kWebDavTimeout,
  })  : _base = base,
        _client = client ?? http.Client(),
        _timeout = timeout,
        _auth = 'Basic ${base64.encode(utf8.encode('$user:$password'))}';

  final Uri _base;
  final http.Client _client;
  final String _auth;

  /// How long one request may take, headers and body each: a server that
  /// accepts the connection and never answers would otherwise hold a probe,
  /// a folder check or a whole scan open for good.
  final Duration _timeout;

  @override
  Future<List<FileEntry>> list(String dir) async {
    final body = await _propfind(_asCollection(dir), depth: 1);
    final self = _normalize(dir);
    return _parse(body).where((e) => _normalize(e.path) != self).toList();
  }

  @override
  Future<FileEntry?> stat(String path) async {
    try {
      final entries = _parse(await _propfind(path, depth: 0));
      return entries.isEmpty ? null : entries.first;
    } on BackendNotFound {
      return null;
    }
  }

  @override
  Future<PlayableFile> playable(String path) async =>
      PlayableFile(url: _url(path).toString(), headers: {
        'Authorization': _auth,
      });

  @override
  Future<void> probe() async {
    await _propfind(_asCollection(_base.path), depth: 0);
  }

  /// [dir] as a collection URL, with its trailing slash (RFC 4918, 5.2).
  /// Apache mod_dav, behind most NAS WebDAV shares, answers a collection
  /// requested without one with a 301, which reads as unreachable.
  static String _asCollection(String dir) => dir.endsWith('/') ? dir : '$dir/';

  Uri _url(String path) {
    final encoded = path.split('/').map(_encodeSegment).join('/');
    final withSlash = encoded.startsWith('/') ? encoded : '/$encoded';
    final port = _base.hasPort ? ':${_base.port}' : '';
    return Uri.parse('${_base.scheme}://${_base.host}$port$withSlash');
  }

  Future<String> _propfind(String path, {required int depth}) async {
    final request = http.Request('PROPFIND', _url(path))
      ..headers['Depth'] = '$depth'
      ..headers['Authorization'] = _auth
      ..headers['Content-Type'] = 'application/xml; charset=utf-8'
      ..body = _propfindBody;
    final http.Response response;
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      response = await http.Response.fromStream(streamed).timeout(_timeout);
    } on SocketException catch (e) {
      throw BackendUnreachable(e.message);
    } on http.ClientException catch (e) {
      throw BackendUnreachable(e.message);
    } on TimeoutException {
      throw const BackendUnreachable('timed out');
    }
    final code = response.statusCode;
    if (code == 401 || code == 403) throw BackendUnauthorized('HTTP $code');
    if (code == 404) throw BackendNotFound(path);
    if (code != 207 && (code < 200 || code >= 300)) {
      throw BackendUnreachable('HTTP $code');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  List<FileEntry> _parse(String body) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(body);
    } on XmlException catch (e) {
      throw BackendUnreachable('malformed multistatus: ${e.message}');
    }
    final entries = <FileEntry>[];
    for (final response in doc.descendantElements.where(_isDav('response'))) {
      final href = response.descendantElements
          .where(_isDav('href'))
          .map((e) => e.innerText.trim())
          .firstOrNull;
      if (href == null || href.isEmpty) continue;
      final path = _decodePath(href);
      final isDir = href.endsWith('/') ||
          response.descendantElements.where(_isDav('collection')).isNotEmpty;
      final length = response.descendantElements
          .where(_isDav('getcontentlength'))
          .map((e) => int.tryParse(e.innerText.trim()))
          .firstOrNull;
      final modifiedText = response.descendantElements
          .where(_isDav('getlastmodified'))
          .map((e) => e.innerText.trim())
          .firstOrNull;
      final normalized = _normalize(path);
      final segments = normalized.split('/')..removeWhere((s) => s.isEmpty);
      entries.add(FileEntry(
        path: path,
        name: segments.isEmpty ? '/' : segments.last,
        isDir: isDir,
        size: isDir ? 0 : (length ?? 0),
        modified: _parseDate(modifiedText),
      ));
    }
    return entries;
  }

  static bool Function(XmlElement) _isDav(String local) => (e) =>
      e.name.local == local &&
      (e.name.namespaceUri == null || e.name.namespaceUri == 'DAV:');

  static String _decodePath(String href) {
    final raw = href.contains('://') ? Uri.parse(href).path : href;
    return raw.split('/').map((s) {
      try {
        return Uri.decodeComponent(s);
      } on FormatException {
        // Not valid UTF-8 (a Latin-1 name, say): keep the segment as the
        // server sent it so [_encodeSegment] can send the same bytes back.
        return s;
      } on ArgumentError {
        return s;
      }
    }).join('/');
  }

  static final _percentByte = RegExp(r'%[0-9A-Fa-f]{2}');

  /// Encodes one decoded path segment. A segment that still holds percent
  /// escapes which are not valid UTF-8 is a raw leftover from [_decodePath],
  /// so it is passed through rather than double-encoded.
  static String _encodeSegment(String s) {
    if (_percentByte.hasMatch(s)) {
      try {
        Uri.decodeComponent(s);
      } on FormatException {
        return s;
      } on ArgumentError {
        return s;
      }
    }
    return Uri.encodeComponent(s);
  }

  static String _normalize(String path) {
    var p = path;
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static DateTime _parseDate(String? text) {
    if (text != null) {
      try {
        return HttpDate.parse(text);
      } on HttpException {
        // fall through
      } on FormatException {
        // fall through
      }
    }
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }
}
