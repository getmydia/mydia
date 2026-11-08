import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'file_system_backend.dart';

/// How long a WebDAV request may take before the server counts as
/// unreachable.
const kWebDavTimeout = Duration(seconds: 20);

/// [path], a URL path as typed or as a server sends it (`/my%20share`), in
/// the decoded form [WebDavBackend] takes and hands out (`/my share`). A
/// segment that is not valid UTF-8 (a Latin-1 name, say) is kept as sent,
/// so the backend sends the same bytes back.
String webDavDecodePath(String path) => path.split('/').map((s) {
      try {
        return Uri.decodeComponent(s);
      } on FormatException {
        return s;
      } on ArgumentError {
        return s;
      }
    }).join('/');

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

  // Each oddity is logged once per backend: a scan lists hundreds of
  // folders, and one line says how this server behaves.
  var _loggedReplyShape = false;
  var _loggedMissingSelf = false;
  var _loggedForeignChild = false;

  @override
  Future<List<FileEntry>> list(String dir) async {
    final body = await _propfind(_asCollection(dir), depth: 1);
    final self = _normalize(dir);
    final all = _parse(body);
    if (!_loggedReplyShape) {
      // How this server shapes a reply, without its content: a reply can
      // carry signed URLs, and logs are shared.
      _loggedReplyShape = true;
      debugPrint('[WebDavBackend] PROPFIND $dir: ${body.length} chars, '
          '${all.length} entries, ${all.where((e) => e.isDir).length} '
          'folders, ${all.where((e) => !e.isDir && e.size > 0).length} sized '
          'files, ${all.where((e) => e.unreadable).length} unreadable, '
          '${_absoluteHref.allMatches(body).length} absolute hrefs');
    }
    final children = all.where((e) => _normalize(e.path) != self).toList();
    if (all.isNotEmpty &&
        all.length == children.length &&
        !_loggedMissingSelf) {
      _loggedMissingSelf = true;
      debugPrint('[WebDavBackend] $dir: no entry for the folder itself among '
          '${all.length}');
    }
    // A child outside the folder asked for means the server's hrefs are not
    // the paths the client sent, and every path built from them is wrong.
    // Counted, not shown: a relative href keeps its query, which can be a
    // signature.
    final prefix = _asCollection(self);
    final foreign =
        children.where((e) => !_normalize(e.path).startsWith(prefix)).length;
    if (foreign > 0 && !_loggedForeignChild) {
      _loggedForeignChild = true;
      debugPrint('[WebDavBackend] $dir: $foreign of ${children.length} '
          'entries outside the folder asked for');
    }
    return children;
  }

  static final _absoluteHref = RegExp(r'href>\s*https?://');

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
    await _propfind(_asCollection(webDavDecodePath(_base.path)), depth: 0);
  }

  /// [dir] as a collection URL, with its trailing slash (RFC 4918, 5.2).
  /// Apache mod_dav, behind most NAS WebDAV shares, answers a collection
  /// requested without one with a 301, which reads as unreachable.
  static String _asCollection(String dir) => dir.endsWith('/') ? dir : '$dir/';

  /// [path] is decoded, as [list] hands it out. Built with [Uri.new], which
  /// brackets an IPv6 host and keeps the escapes [_encodeSegment] wrote.
  Uri _url(String path) {
    final encoded = path.split('/').map(_encodeSegment).join('/');
    final withSlash = encoded.startsWith('/') ? encoded : '/$encoded';
    return Uri(
      scheme: _base.scheme,
      host: _base.host,
      port: _base.hasPort ? _base.port : null,
      path: withSlash,
    );
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
    // A login page or a proxy's error page is well-formed XML too; read as
    // an empty folder it would drop every indexed file under it.
    final root = doc.childElements.firstOrNull;
    if (root == null || !_isDav('multistatus')(root)) {
      throw const BackendUnreachable('not a WebDAV multistatus response');
    }
    final entries = <FileEntry>[];
    var withoutHref = 0;
    for (final response in root.childElements.where(_isDav('response'))) {
      final href = response.descendantElements
          .where(_isDav('href'))
          .map((e) => e.innerText.trim())
          .firstOrNull;
      if (href == null || href.isEmpty) {
        withoutHref++;
        continue;
      }
      final path = _decodePath(href);
      final isDir = href.endsWith('/') ||
          response.descendantElements.where(_isDav('collection')).isNotEmpty;
      // An entry the server answers with an error (one file or folder it
      // denies) is listed as unreadable: left out, it would read as deleted
      // and take its indexed files with it; failing the listing would
      // freeze the whole library on it.
      final unreadable = !_classified(response);
      if (unreadable) {
        // The decoded path, not the href: it carries no query.
        debugPrint('[WebDavBackend] $path refused; listed as unreadable');
      }
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
        unreadable: unreadable,
      ));
    }
    if (withoutHref > 0) {
      debugPrint('[WebDavBackend] dropped $withoutHref responses without '
          'an href');
    }
    return entries;
  }

  static bool Function(XmlElement) _isDav(String local) => (e) =>
      e.name.local == local &&
      (e.name.namespaceUri == null || e.name.namespaceUri == 'DAV:');

  static final _statusCode = RegExp(r'^HTTP/\S+\s+(\d{3})');

  /// Whether a `<status>` child of [e], if any, is 2xx.
  static bool _statusOk(XmlElement e) {
    final text = e.childElements
        .where(_isDav('status'))
        .map((s) => s.innerText.trim())
        .firstOrNull;
    if (text == null) return true;
    final code = int.tryParse(_statusCode.firstMatch(text)?.group(1) ?? '');
    return code != null && code >= 200 && code < 300;
  }

  /// Whether [response] says what its resource is: the response itself is
  /// not an error, and the propstat holding `resourcetype` is 2xx, or, with
  /// no `resourcetype` sent, not every propstat failed.
  static bool _classified(XmlElement response) {
    if (!_statusOk(response)) return false;
    final propstats = response.childElements.where(_isDav('propstat'));
    final typed = propstats
        .where((p) => p.descendantElements.any(_isDav('resourcetype')))
        .firstOrNull;
    if (typed != null) return _statusOk(typed);
    // No resourcetype anywhere: readable only if some propstat succeeded
    // (or the server sent none at all).
    return propstats.isEmpty || propstats.any(_statusOk);
  }

  /// The path [href] names, decoded. A query is dropped from a relative href
  /// as [Uri.path] drops it from an absolute one: a `?` in a name arrives
  /// escaped, so a raw one starts a query, which can be a signature that
  /// would otherwise travel with the path into every log line naming it.
  static String _decodePath(String href) {
    final String raw;
    if (href.contains('://')) {
      raw = Uri.parse(href).path;
    } else {
      final query = href.indexOf('?');
      raw = query < 0 ? href : href.substring(0, query);
    }
    return webDavDecodePath(raw);
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
