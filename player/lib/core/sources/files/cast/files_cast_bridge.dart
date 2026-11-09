import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../p2p/local_proxy_service.dart';
import '../../../p2p/media_proxy.dart';
import '../backend/file_system_backend.dart';
import 'subtitle_vtt.dart';

/// A sidecar subtitle track registered on a [FilesCastBridge] session.
class FilesCastSubtitle {
  const FilesCastSubtitle({
    required this.file,
    required this.format,
  });

  final PlayableFile file;
  final String format;
}

/// Active session handle returned by [FilesCastBridge.openSession].
class FilesCastSession {
  const FilesCastSession({
    required this.sessionId,
    required this.baseUrl,
    required this.token,
    required this.containerExtension,
  });

  final String sessionId;
  final String baseUrl;
  final String token;
  final String containerExtension;

  String get mediaUrl => '$baseUrl/f/$token/media.$containerExtension';

  String subtitleUrl(String trackId) =>
      '$baseUrl/f/$token/sub/${Uri.encodeComponent(trackId)}.vtt';
}

class _ActiveSession {
  _ActiveSession({
    required this.sessionId,
    required this.token,
    required this.media,
    required this.mime,
    required this.subtitles,
  });

  final String sessionId;
  final String token;
  final PlayableFile media;
  final String mime;
  final Map<String, FilesCastSubtitle> subtitles;
}

/// On-demand LAN HTTP server that bridges `SourceKind.files` media and sidecar
/// subtitles to Chromecast and DLNA receivers on the local network.
///
/// The listener is bound to [InternetAddress.anyIPv4] on an ephemeral port
/// only while a cast session is active, and closed as soon as [closeSession]
/// or [dispose] tears the session down.
class FilesCastBridge {
  FilesCastBridge({
    Future<String?> Function()? lanAddressResolver,
    http.Client? client,
  })  : _lanAddressResolver =
            lanAddressResolver ?? LocalProxyService.resolveLanAddress,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final Future<String?> Function() _lanAddressResolver;
  final http.Client _client;
  final bool _ownsClient;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _listener;
  int? _boundPort;
  _ActiveSession? _session;
  int _sessionCounter = 0;
  Future<ProxyHeal>? _healing;

  /// The LAN port currently bound for an active cast session, or `null` when
  /// no `files` cast is active.
  int? get activePort => _server != null ? _boundPort : null;

  /// Opens (or replaces) the active cast bridge session and returns its LAN
  /// URLs. Throws a [StateError] if no private IPv4 LAN interface is available.
  Future<FilesCastSession> openSession({
    required PlayableFile media,
    required String mime,
    required Map<String, FilesCastSubtitle> subtitles,
  }) async {
    final lanIp = await _lanAddressResolver();
    if (lanIp == null) {
      throw StateError('No LAN network interface available for casting');
    }

    await _ensureBound();
    final port = _boundPort!;
    final sessionId = 'files-cast-${++_sessionCounter}';
    final token = _generateToken();
    _session = _ActiveSession(
      sessionId: sessionId,
      token: token,
      media: media,
      mime: mime,
      subtitles: Map.unmodifiable(subtitles),
    );

    return FilesCastSession(
      sessionId: sessionId,
      baseUrl: 'http://$lanIp:$port',
      token: token,
      containerExtension: _extensionForMime(mime, media.url),
    );
  }

  /// Closes [sessionId] if it is still the active session and shuts down the
  /// LAN listener.
  Future<void> closeSession(String sessionId) async {
    final current = _session;
    if (current == null || current.sessionId != sessionId) return;
    _session = null;
    await _closeServer();
  }

  /// Probes the active listener and rebinds if the OS reclaimed the socket
  /// while the app was backgrounded.
  Future<ProxyHeal> healListener() {
    return _healing ??= _heal().whenComplete(() => _healing = null);
  }

  Future<ProxyHeal> _heal() async {
    final server = _server;
    final port = _boundPort;
    if (server == null || port == null || _session == null) {
      return ProxyHeal.healthy;
    }
    if (await _accepting(port)) {
      return ProxyHeal.healthy;
    }
    if (!identical(_server, server) || _session == null) {
      return ProxyHeal.healthy;
    }

    await _closeServer();
    var samePort = true;
    HttpServer fresh;
    try {
      fresh = await HttpServer.bind(InternetAddress.anyIPv4, port);
    } on SocketException {
      samePort = false;
      fresh = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    if (_session == null) {
      await fresh.close(force: true);
      return ProxyHeal.healthy;
    }
    _adopt(fresh);
    return samePort ? ProxyHeal.reboundSamePort : ProxyHeal.reboundNewPort;
  }

  @visibleForTesting
  Future<void> debugDropListener() async {
    await _listener?.cancel();
    await _server?.close(force: true);
  }

  Future<void> dispose() async {
    _session = null;
    await _closeServer();
    if (_ownsClient) {
      _client.close();
    }
  }

  Future<void> _ensureBound() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _adopt(server);
  }

  void _adopt(HttpServer server) {
    _server = server;
    _boundPort = server.port;
    _listener = server.listen(
      _handleRequest,
      onError: (Object e) => debugPrint('[FilesCastBridge] Listener error: $e'),
    );
  }

  Future<void> _closeServer() async {
    final listener = _listener;
    final server = _server;
    _listener = null;
    _server = null;
    _boundPort = null;
    await listener?.cancel();
    await server?.close(force: true);
  }

  static Future<bool> _accepting(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 1),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    _setCorsHeaders(response);

    if (request.method == 'OPTIONS') {
      response.statusCode = HttpStatus.noContent;
      await response.close();
      return;
    }

    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }

    final session = _session;
    final segments = request.uri.pathSegments;
    // Expected routes:
    //   /f/<token>/media.<ext>
    //   /f/<token>/sub/<trackId>.vtt
    if (session == null ||
        segments.length < 3 ||
        segments[0] != 'f' ||
        segments[1] != session.token) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }

    try {
      if (segments.length == 3 && segments[2].startsWith('media.')) {
        await _serveMedia(request, session);
        return;
      }
      if (segments.length == 4 &&
          segments[2] == 'sub' &&
          segments[3].endsWith('.vtt')) {
        final rawTrack = segments[3].substring(0, segments[3].length - 4);
        final trackId = Uri.decodeComponent(rawTrack);
        await _serveSubtitle(request, session, trackId);
        return;
      }
      response.statusCode = HttpStatus.notFound;
      await response.close();
    } catch (e) {
      debugPrint('[FilesCastBridge] Request error: $e');
      try {
        response.statusCode = HttpStatus.badGateway;
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<void> _serveMedia(
    HttpRequest request,
    _ActiveSession session,
  ) async {
    final uri = Uri.parse(session.media.url);
    if (uri.scheme == 'file') {
      await _serveLocalFile(request, File(uri.toFilePath()), session.mime);
    } else {
      await _proxyHttpMedia(request, uri, session.media.headers, session.mime);
    }
  }

  Future<void> _serveLocalFile(
    HttpRequest request,
    File file,
    String mime,
  ) async {
    final response = request.response;
    if (!await file.exists()) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final length = await file.length();
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.contentTypeHeader, mime);

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader == null) {
      response.statusCode = HttpStatus.ok;
      response.headers.contentLength = length;
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      await response.addStream(file.openRead());
      await response.close();
      return;
    }

    final parsed = _parseRange(rangeHeader, length);
    if (parsed == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      response.headers.contentLength = 0;
      await response.close();
      return;
    }

    final (start, endInclusive) = parsed;
    final sliceLength = endInclusive - start + 1;
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$endInclusive/$length',
    );
    response.headers.contentLength = sliceLength;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    await response.addStream(file.openRead(start, endInclusive + 1));
    await response.close();
  }

  Future<void> _proxyHttpMedia(
    HttpRequest request,
    Uri upstreamUri,
    Map<String, String> authHeaders,
    String fallbackMime,
  ) async {
    final response = request.response;
    final upstreamReq = http.Request(request.method, upstreamUri);
    upstreamReq.headers.addAll(authHeaders);
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      upstreamReq.headers[HttpHeaders.rangeHeader] = range;
    }

    final upstreamResp = await _client.send(upstreamReq);
    response.statusCode = upstreamResp.statusCode;
    response.headers.set(
      HttpHeaders.acceptRangesHeader,
      upstreamResp.headers['accept-ranges'] ?? 'bytes',
    );
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      upstreamResp.headers['content-type'] ?? fallbackMime,
    );
    final contentRange = upstreamResp.headers['content-range'];
    if (contentRange != null) {
      response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
    }
    final contentLength = upstreamResp.contentLength;
    if (contentLength != null && contentLength >= 0) {
      response.headers.contentLength = contentLength;
    }

    if (request.method == 'HEAD') {
      await upstreamResp.stream.drain<void>();
      await response.close();
      return;
    }

    await response.addStream(upstreamResp.stream);
    await response.close();
  }

  Future<void> _serveSubtitle(
    HttpRequest request,
    _ActiveSession session,
    String trackId,
  ) async {
    final response = request.response;
    final sub = session.subtitles[trackId];
    if (sub == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final rawText = await _readSubtitleText(sub.file);
    if (rawText == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final vttBytes = utf8.encode(toWebVtt(rawText, format: sub.format));
    response.statusCode = HttpStatus.ok;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'text/vtt; charset=utf-8',
    );
    response.headers.contentLength = vttBytes.length;
    if (request.method != 'HEAD') {
      response.add(vttBytes);
    }
    await response.close();
  }

  Future<String?> _readSubtitleText(PlayableFile playable) async {
    final uri = Uri.parse(playable.url);
    if (uri.scheme == 'file') {
      final file = File(uri.toFilePath());
      if (!await file.exists()) return null;
      return utf8.decode(await file.readAsBytes(), allowMalformed: true);
    }
    final resp = await _client.get(uri, headers: playable.headers);
    if (resp.statusCode != HttpStatus.ok) return null;
    return utf8.decode(resp.bodyBytes, allowMalformed: true);
  }

  static void _setCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Range, Content-Type');
    response.headers.set(
      'Access-Control-Expose-Headers',
      'Content-Length, Content-Range, Accept-Ranges',
    );
  }

  /// Parses `bytes=start-end` or `bytes=start-` against [totalLength].
  /// Returns `(start, endInclusive)` or `null` when unsatisfiable.
  static (int, int)? _parseRange(String header, int totalLength) {
    if (totalLength <= 0) return null;
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    if (start == null || start < 0 || start >= totalLength) return null;
    final endStr = match.group(2)!;
    final end = endStr.isEmpty ? totalLength - 1 : int.tryParse(endStr);
    if (end == null || end < start) return null;
    final clampedEnd = end >= totalLength ? totalLength - 1 : end;
    return (start, clampedEnd);
  }

  static String _extensionForMime(String mime, String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final ext in ['mp4', 'm4v', 'mkv', 'webm', 'mov', 'avi', 'ts']) {
      if (path.endsWith('.$ext')) return ext;
    }
    return switch (mime.toLowerCase()) {
      'video/x-matroska' => 'mkv',
      'video/webm' => 'webm',
      'video/quicktime' => 'mov',
      'video/mp2t' => 'ts',
      'video/x-msvideo' => 'avi',
      _ => 'mp4',
    };
  }

  static String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
