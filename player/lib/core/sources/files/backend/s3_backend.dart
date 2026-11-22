import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'file_system_backend.dart';
import 's3_errors.dart';
import 's3_signer.dart';

/// How long a presigned playback URL stays valid. Matches the server's
/// presigned URLs.
const kS3PresignExpiry = Duration(hours: 12);

/// How long one S3 request may take, headers and body each, before the
/// endpoint counts as unreachable.
const kS3Timeout = Duration(seconds: 20);

/// How requests address the bucket: `<endpoint>/<bucket>/<key>` (path) or
/// `<bucket>.<endpoint>/<key>` (virtual-hosted).
enum S3Style { path, vhost }

/// One bucket at one endpoint, narrowed to a key prefix.
class S3Location {
  const S3Location({
    required this.endpoint,
    required this.bucket,
    required this.prefix,
    required this.region,
    required this.style,
  });

  /// `http` or `https`, a host, an optional port, no path.
  final Uri endpoint;
  final String bucket;

  /// Empty, or ending in `/`; never starts with `/`. Case is kept: keys are
  /// case sensitive.
  final String prefix;
  final String region;
  final S3Style style;

  /// `s3+<scheme>://<host>[:port]/<bucket>/<prefix>?region=<r>&style=<s>`.
  ///
  /// Built from path segments, so a literal `%` in a key is sent as `%25`
  /// and a prefix such as `a%20b/` reads back as itself, not as `a b/`.
  Uri toConnectionUri() => Uri(
    scheme: 's3+${endpoint.scheme}',
    host: endpoint.host,
    port: endpoint.hasPort ? endpoint.port : null,
    pathSegments: [...bucket.split('/'), ...prefix.split('/')],
    queryParameters: {'region': region, 'style': style.name},
  );

  /// The location [u] names, or null when [u] is not a complete S3
  /// connection URI.
  static S3Location? fromConnectionUri(Uri u) {
    final scheme = switch (u.scheme.toLowerCase()) {
      's3+https' => 'https',
      's3+http' => 'http',
      _ => null,
    };
    if (scheme == null || u.host.isEmpty) return null;
    final region = u.queryParameters['region'];
    if (region == null || region.isEmpty) return null;
    final style = S3Style.values
        .where((s) => s.name == u.queryParameters['style'])
        .firstOrNull;
    if (style == null) return null;

    // The first non-empty segment is the bucket. The rest is the prefix, in
    // which only leading and trailing slashes are rewritten: keys are case
    // sensitive and may hold `//`, so `a//b/` is not `a/b/`.
    final segments = u.pathSegments.skipWhile((s) => s.isEmpty).toList();
    if (segments.isEmpty) return null;
    final rest = segments
        .skip(1)
        .skipWhile((s) => s.isEmpty)
        .join('/')
        .replaceFirst(RegExp(r'/+$'), '');
    return S3Location(
      endpoint: Uri(
        scheme: scheme,
        host: u.host,
        port: u.hasPort ? u.port : null,
      ),
      bucket: segments.first,
      prefix: rest.isEmpty ? '' : '$rest/',
      region: region,
      style: style,
    );
  }

  /// The host requests go to: the endpoint's, or the bucket's subdomain of it.
  String get _host =>
      style == S3Style.vhost ? '$bucket.${endpoint.host}' : endpoint.host;

  String get _origin => Uri(
    scheme: endpoint.scheme,
    host: _host,
    port: endpoint.hasPort ? endpoint.port : null,
  ).toString();

  String get _bucketPath =>
      style == S3Style.path ? '/${s3UriEncode(bucket, encodeSlash: true)}' : '';

  /// The URL of the object [key]. Encoded with [s3UriEncode] so the path on
  /// the wire is the one the signer canonicalizes: `Uri(path:)` leaves
  /// characters such as `+` and `&` raw.
  Uri objectUri(String key) =>
      Uri.parse('$_origin$_bucketPath/${s3UriEncode(key, encodeSlash: false)}');

  /// The bucket's URL with [query], each key and value encoded with
  /// [s3UriEncode], in the order given.
  Uri bucketUri([Map<String, String> query = const {}]) {
    final path = _bucketPath.isEmpty ? '/' : _bucketPath;
    final q = query.entries
        .map(
          (e) =>
              '${s3UriEncode(e.key, encodeSlash: true)}='
              '${s3UriEncode(e.value, encodeSlash: true)}',
        )
        .join('&');
    return Uri.parse('$_origin$path${q.isEmpty ? '' : '?$q'}');
  }

  /// Host and port for messages: never a URL, which could carry a query.
  String get displayHost =>
      endpoint.hasPort ? '${endpoint.host}:${endpoint.port}' : endpoint.host;
}

const _archivedClasses = {'GLACIER', 'DEEP_ARCHIVE'};

/// Reads media from an S3-compatible bucket with SigV4-signed requests.
///
/// Paths are relative to the location's prefix and start with `/`: under
/// prefix `media/`, the key `media/Movies/x.mkv` is the path `/Movies/x.mkv`.
class S3Backend implements FileSystemBackend {
  S3Backend({
    required S3Location location,
    required String accessKeyId,
    required String secretAccessKey,
    http.Client? client,
    DateTime Function()? clock,
    this._timeout = kS3Timeout,
  }) : _location = location,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _signer = S3Signer(
         accessKeyId: accessKeyId,
         secretAccessKey: secretAccessKey,
         region: location.region,
         clock: clock,
       );

  final S3Location _location;
  final http.Client _client;
  final bool _ownsClient;
  final Duration _timeout;
  final S3Signer _signer;

  /// Closes the client this backend made; a given one is its owner's.
  void close() {
    if (_ownsClient) _client.close();
  }

  @override
  Future<List<FileEntry>> list(String dir) async {
    final listed = _dirKey(dir);
    final entries = <FileEntry>[];
    String? token;
    do {
      final page = await _listPage({
        'list-type': '2',
        'delimiter': '/',
        'prefix': listed,
        'max-keys': '1000',
        'continuation-token': ?token,
      });
      for (final p in page.prefixes) {
        // A folder's key ends in exactly one `/` of its own: `media/a//`
        // is the folder `/a/`, which holds `media/a//x.mkv`.
        final path = _pathOf(p.substring(0, p.length - 1));
        // `<prefix>/` at the root, an empty first segment, has no path
        // apart from the root itself.
        if (path == '/') continue;
        entries.add(_dirEntry(path));
      }
      for (final o in page.objects) {
        // The zero-byte marker web consoles create for a folder.
        if (o.key == listed) continue;
        final path = _pathOf(o.key);
        entries.add(
          FileEntry(
            path: path,
            name: _nameOf(path),
            isDir: false,
            size: o.size,
            modified: o.modified,
            unreadable: _archivedClasses.contains(o.storageClass),
          ),
        );
      }
      if (!page.truncated) break;
      // A truncated page that cannot be continued (no token, as a V1-style
      // server answers, or the same token again) would read as a complete
      // listing and drop every indexed file past it.
      final next = page.nextToken;
      if (next == null || next == token) {
        throw BackendUnreachable(
          'S3 at ${_location.displayHost} sent an incomplete listing',
        );
      }
      token = next;
    } while (true);
    return entries;
  }

  @override
  Future<FileEntry?> stat(String path) async {
    final key = _keyOf(path);
    if (_isRoot(path)) return _dirEntry('/');
    final response = await _send('HEAD', _location.objectUri(key));
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      return FileEntry(
        path: path,
        name: _nameOf(path),
        isDir: false,
        size: int.tryParse(response.headers['content-length'] ?? '') ?? 0,
        modified: _httpDate(response.headers['last-modified']),
      );
    }
    if (status != 404) {
      // A HEAD answer has no body to read a code from.
      throw _failure(response, atProbe: false);
    }
    // No object: a folder when anything sits under it.
    final page = await _listPage({
      'list-type': '2',
      'prefix': _dirKey(path),
      'max-keys': '1',
    });
    if (page.objects.isEmpty && page.prefixes.isEmpty) return null;
    return _dirEntry(path);
  }

  /// The folder at [path]. Its identity is its key prefix in the bucket
  /// (the root's is the location prefix, or `/` without one): a walk that
  /// trims one trailing `/` from paths would take the folder `/a/` (key
  /// `<prefix>a//`) for its parent `/a` and never enter it, while the keys
  /// `<prefix>a/` and `<prefix>a//` stay apart after that trim.
  FileEntry _dirEntry(String path) {
    final key = _dirKey(path);
    return FileEntry(
      path: _isRoot(path) ? '/' : path,
      name: _isRoot(path) ? '/' : _nameOf(path),
      identity: key.isEmpty ? '/' : key,
      isDir: true,
      size: 0,
      modified: _epoch,
    );
  }

  @override
  Future<PlayableFile> playable(String path) async => PlayableFile(
    url: _signer
        .presign(
          method: 'GET',
          uri: _location.objectUri(_keyOf(path)),
          expires: kS3PresignExpiry,
        )
        .toString(),
  );

  @override
  Future<void> probe() async {
    await _listPage({
      'list-type': '2',
      'delimiter': '/',
      'prefix': _location.prefix,
      'max-keys': '1',
    });
  }

  /// The key [path] names: the prefix, then [path] without its leading `/`.
  String _keyOf(String path) =>
      _location.prefix + (path.startsWith('/') ? path.substring(1) : path);

  static bool _isRoot(String path) => path.isEmpty || path == '/';

  /// The key prefix that lists [dir]: the location's prefix for the root,
  /// otherwise its key plus one `/`, always. A path is never trimmed: the
  /// folder `/a/` is the key prefix `<prefix>a//`, not `<prefix>a/`.
  String _dirKey(String dir) =>
      _isRoot(dir) ? _location.prefix : '${_keyOf(dir)}/';

  /// The backend path of [key], a key under the prefix, kept as is: keys
  /// may hold `//` and end in `/`, and each is its own path.
  String _pathOf(String key) {
    final rel = key.startsWith(_location.prefix)
        ? key.substring(_location.prefix.length)
        : key;
    return '/$rel';
  }

  /// The last segment of [path]; `/` for one that is empty (a folder whose
  /// key ends in `//`), which a viewer cannot otherwise see.
  static String _nameOf(String path) {
    final i = path.lastIndexOf('/');
    final name = i < 0 ? path : path.substring(i + 1);
    return name.isEmpty ? '/' : name;
  }

  Future<_ListPage> _listPage(Map<String, String> query) async {
    final response = await _send('GET', _location.bucketUri(query));
    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      throw _failure(response, atProbe: true);
    }
    return _parseList(utf8.decode(response.bodyBytes, allowMalformed: true));
  }

  BackendFailure _failure(http.Response response, {required bool atProbe}) =>
      s3Failure(
        status: response.statusCode,
        body: utf8.decode(response.bodyBytes, allowMalformed: true),
        host: _location.displayHost,
        bucket: _location.bucket,
        atProbe: atProbe,
        regionHeader: response.headers['x-amz-bucket-region'],
      );

  /// Signs and sends one request. Redirects are not followed: S3 answers a
  /// wrong region with a 301, and following one would resend the signed
  /// headers elsewhere.
  Future<http.Response> _send(String method, Uri uri) async {
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll(_signer.sign(method: method, uri: uri));
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      return await http.Response.fromStream(streamed).timeout(_timeout);
    } on Exception catch (e) {
      // The error's text can carry the signed URL; it is dropped.
      throw s3TransportFailure(e, host: _location.displayHost);
    }
  }

  _ListPage _parseList(String body) {
    final XmlElement? root;
    try {
      root = XmlDocument.parse(body).childElements.firstOrNull;
    } on XmlException {
      throw BackendUnreachable(
        'S3 at ${_location.displayHost} sent a malformed listing',
      );
    }
    // A proxy's or login page's XML read as an empty folder would drop
    // every indexed file under it.
    if (root == null || root.name.local != 'ListBucketResult') {
      throw BackendUnreachable(
        'S3 at ${_location.displayHost} did not send a bucket listing',
      );
    }
    // Keys are not trimmed: a key may end in a space.
    String? child(XmlElement e, String local) => e.childElements
        .where((c) => c.name.local == local)
        .map((c) => c.innerText)
        .firstOrNull;

    final objects = <_S3Object>[];
    final prefixes = <String>[];
    for (final e in root.childElements) {
      switch (e.name.local) {
        case 'Contents':
          final key = child(e, 'Key');
          if (key == null || key.isEmpty) continue;
          objects.add(
            _S3Object(
              key: key,
              size: int.tryParse(child(e, 'Size')?.trim() ?? '') ?? 0,
              modified:
                  DateTime.tryParse(child(e, 'LastModified')?.trim() ?? '')
                      ?.toUtc() ??
                  _epoch,
              storageClass: child(e, 'StorageClass')?.trim(),
            ),
          );
        case 'CommonPrefixes':
          final p = child(e, 'Prefix');
          if (p != null && p.isNotEmpty) prefixes.add(p);
      }
    }
    final token = child(root, 'NextContinuationToken')?.trim();
    return _ListPage(
      objects: objects,
      prefixes: prefixes,
      truncated: child(root, 'IsTruncated')?.trim() == 'true',
      nextToken: (token == null || token.isEmpty) ? null : token,
    );
  }

  static DateTime _httpDate(String? text) {
    if (text != null) {
      try {
        return HttpDate.parse(text);
      } on HttpException {
        // fall through
      } on FormatException {
        // fall through
      }
    }
    return _epoch;
  }

  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

class _S3Object {
  const _S3Object({
    required this.key,
    required this.size,
    required this.modified,
    required this.storageClass,
  });

  final String key;
  final int size;
  final DateTime modified;
  final String? storageClass;
}

class _ListPage {
  const _ListPage({
    required this.objects,
    required this.prefixes,
    required this.truncated,
    required this.nextToken,
  });

  final List<_S3Object> objects;
  final List<String> prefixes;
  final bool truncated;
  final String? nextToken;
}
