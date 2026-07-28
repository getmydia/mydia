import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/native/lib.dart'
    show
        FlutterHlsStreamEvent_Header,
        FlutterHlsStreamEvent_Chunk,
        FlutterHlsStreamEvent_End,
        FlutterHlsStreamEvent_Error;

final localProxyServiceProvider = Provider<LocalProxyService>((ref) {
  final p2p = ref.watch(p2pServiceProvider);
  final service = LocalProxyService(p2p);
  ref.onDispose(() => service.stop());
  return service;
});

/// Local HTTP proxy for streaming HLS media over P2P.
///
/// This service creates a local HTTP server that proxies HLS requests
/// to the P2P network. The video player connects to this local server,
/// and requests are forwarded to the remote server via P2P.
///
/// URL Format: /hls/{session_id}/{path}
/// Example: /hls/abc123/index.m3u8
/// Example: /hls/abc123/segment_001.ts
///
/// Direct stream: /direct/{file_id}/stream
/// Download: /download/{job_id}/file
class LocalProxyService {
  final P2pService _p2p;
  HttpServer? _server;

  /// The peer ID to send HLS requests to
  String? _targetPeer;

  /// Auth token for HLS requests
  String? _authToken;

  /// Unguessable path prefix required on every request while LAN-exposed.
  /// A path prefix rather than a query parameter because HLS segment URLs are
  /// relative and would not carry a query string through manifest resolution.
  String? _lanToken;

  /// Cached non-loopback address used to build receiver-facing URLs.
  String? _lanAddress;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  /// Whether the proxy is currently reachable from other devices on the LAN.
  bool get isLanAccessible => _lanToken != null && _lanAddress != null;

  /// Base URL other devices on the LAN can reach, or null when loopback-only.
  String? get lanBaseUrl {
    if (!isLanAccessible || _server == null) return null;
    return 'http://$_lanAddress:${_server!.port}/g/$_lanToken';
  }

  /// Prefix applied to every locally built URL.
  String get _urlBase {
    if (_server == null) {
      throw StateError('LocalProxyService is not started');
    }
    return lanBaseUrl ?? 'http://127.0.0.1:${_server!.port}';
  }

  LocalProxyService(this._p2p);

  /// Test-only constructor: builds a service with no live P2P dependency.
  /// Requests that reach P2P will fail, which is fine for URL and gating tests.
  factory LocalProxyService.forTesting() => LocalProxyService(P2pService());

  /// Start the local proxy server.
  ///
  /// [targetPeer] - The peer ID or EndpointAddr JSON to send HLS requests to.
  /// [authToken] - Optional auth token for HLS requests.
  Future<void> start({
    required String targetPeer,
    String? authToken,
  }) async {
    if (_server != null) {
      // Update config if already running
      _targetPeer = targetPeer;
      _authToken = authToken;
      return;
    }

    _targetPeer = targetPeer;
    _authToken = authToken;

    // Bind to loopback on ephemeral port
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    debugPrint('[LocalProxy] Started on http://127.0.0.1:${_server!.port}');

    _server!.listen((HttpRequest request) {
      _handleRequest(request);
    });
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
    _targetPeer = null;
    _authToken = null;
    _lanToken = null;
    _lanAddress = null;
    debugPrint('[LocalProxy] Stopped');
  }

  /// Find a usable non-loopback IPv4 address for receiver-facing URLs.
  ///
  /// Returns null when the device has no LAN interface, in which case casting
  /// must fall back to the direct-server route.
  static Future<String?> resolveLanAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) return address.address;
        }
      }
    } catch (e) {
      debugPrint('[LocalProxy] Failed to resolve LAN address: $e');
    }
    return null;
  }

  /// Rebind the proxy so LAN devices can reach it, or return it to loopback.
  ///
  /// Rebinding drops in-flight local playback connections. Callers enable this
  /// only when starting a cast, at which point local playback is being paused
  /// anyway.
  Future<void> setLanAccess(bool enabled) async {
    if (enabled == isLanAccessible) return;

    final peer = _targetPeer;
    final token = _authToken;

    if (enabled) {
      final address = await resolveLanAddress();
      if (address == null) {
        debugPrint('[LocalProxy] No LAN interface available; staying loopback');
        return;
      }
      _lanAddress = address;
      _lanToken = _generateToken();
    } else {
      _lanAddress = null;
      _lanToken = null;
    }

    await _server?.close();
    _server = null;

    if (peer == null) return;

    _server = await HttpServer.bind(
      enabled ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4,
      0,
    );
    _targetPeer = peer;
    _authToken = token;
    _server!.listen(_handleRequest);

    debugPrint(
      '[LocalProxy] Rebound (lan=$enabled) on port ${_server!.port}',
    );
  }

  static String _generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Build the HLS URL for a session.
  ///
  /// Returns the local proxy URL for the HLS playlist.
  /// The video player should use this URL to start playback.
  String buildHlsUrl(String sessionId) => '$_urlBase/hls/$sessionId/index.m3u8';

  /// Build the base URL for HLS content. Manifests use relative segment URLs,
  /// which resolve against this base — including the LAN token prefix.
  String buildBaseUrl(String sessionId) => '$_urlBase/hls/$sessionId/';

  /// Build a direct stream URL for a media file.
  ///
  /// This uses the P2P HLS protocol with a "direct:" session ID prefix
  /// to stream the raw file without HLS transcoding.
  String buildDirectStreamUrl(String fileId) => '$_urlBase/direct/$fileId/stream';

  /// Build a download URL for a completed transcode job.
  ///
  /// Uses the P2P HLS protocol with a "download:" session ID prefix
  /// to proxy the transcoded file download.
  String buildDownloadUrl(String jobId) => '$_urlBase/download/$jobId/file';

  // Handle incoming HTTP requests
  Future<void> _handleRequest(HttpRequest request) async {
    final status = _authorizeAndStripPrefix(request.uri.path);

    if (status.statusCode != HttpStatus.ok) {
      request.response.statusCode = status.statusCode;
      _setCorsHeaders(request.response);
      request.response.write(status.statusCode == HttpStatus.forbidden
          ? 'Forbidden'
          : 'Not Found');
      await request.response.close();
      return;
    }

    final path = status.path;
    debugPrint('[LocalProxy] ${request.method} $path');

    if (path.startsWith('/hls/')) {
      await _handleHlsRequest(request, path);
    } else if (path.startsWith('/direct/')) {
      await _handleDirectRequest(request, path);
    } else if (path.startsWith('/download/')) {
      await _handleDownloadRequest(request, path);
    } else {
      request.response.statusCode = HttpStatus.notFound;
      _setCorsHeaders(request.response);
      request.response.write('Not Found');
      await request.response.close();
    }
  }

  /// Validates the LAN token prefix and returns the path with it removed.
  ///
  /// While LAN-exposed, every request must carry `/g/<token>`; without it the
  /// media would be readable by anything on the network.
  ({int statusCode, String path}) _authorizeAndStripPrefix(String rawPath) {
    final token = _lanToken;

    if (token == null) {
      // Loopback-only: no prefix expected, and any prefix is bogus.
      return rawPath.startsWith('/g/')
          ? (statusCode: HttpStatus.forbidden, path: rawPath)
          : (statusCode: HttpStatus.ok, path: rawPath);
    }

    final expected = '/g/$token';
    if (!rawPath.startsWith('$expected/')) {
      return (statusCode: HttpStatus.forbidden, path: rawPath);
    }

    return (statusCode: HttpStatus.ok, path: rawPath.substring(expected.length));
  }

  /// Test hook: returns the status code `_handleRequest` would produce for a
  /// path, without needing a live socket.
  Future<int> debugHandlePath(String path) async =>
      _authorizeAndStripPrefix(path).statusCode;

  Future<void> _handleHlsRequest(HttpRequest request, String path) async {
    final sw = Stopwatch()..start();
    try {
      // Parse path: /hls/{session_id}/{path...}
      final pathParts = path.substring('/hls/'.length).split('/');
      if (pathParts.length < 2) {
        request.response.statusCode = HttpStatus.badRequest;
        _setCorsHeaders(request.response);
        request.response.write(
            'Invalid HLS path format. Expected: /hls/{session_id}/{path}');
        await request.response.close();
        return;
      }

      final sessionId = pathParts[0];
      final hlsPath = pathParts.sublist(1).join('/');

      if (sessionId.isEmpty || hlsPath.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        _setCorsHeaders(request.response);
        request.response.write('Session ID and path are required');
        await request.response.close();
        return;
      }

      if (_targetPeer == null) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        _setCorsHeaders(request.response);
        request.response.write('No target peer configured');
        await request.response.close();
        return;
      }

      // Parse Range header for seeking support
      int? rangeStart;
      int? rangeEnd;
      final rangeHeader = request.headers.value('Range');
      if (rangeHeader != null) {
        final range = _parseRangeHeader(rangeHeader);
        rangeStart = range.$1;
        rangeEnd = range.$2;
      }

      final proxySetupMs = sw.elapsedMilliseconds;

      debugPrint(
          '[LocalProxy] HLS request: session=$sessionId, path=$hlsPath, range=$rangeStart-$rangeEnd');

      // Forward to P2P
      final response = await _p2p.sendHlsRequest(
        peer: _targetPeer!,
        sessionId: sessionId,
        path: hlsPath,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        authToken: _authToken,
      );
      final p2pRequestMs = sw.elapsedMilliseconds;

      // Set response status
      request.response.statusCode = response.header.status;

      // Set response headers
      request.response.headers.contentType =
          ContentType.parse(response.header.contentType);
      final payloadLength = response.data.length;
      final headerLength = response.header.contentLength.toInt();
      request.response.headers.contentLength =
          headerLength == payloadLength ? headerLength : payloadLength;

      if (response.header.contentRange != null) {
        request.response.headers
            .set('Content-Range', response.header.contentRange!);
      }
      if (response.header.cacheControl != null) {
        request.response.headers
            .set('Cache-Control', response.header.cacheControl!);
      }

      // Allow CORS for local playback
      _setCorsHeaders(request.response);

      // Write response body
      request.response.add(response.data);
      await request.response.close();

      final totalMs = sw.elapsedMilliseconds;
      debugPrint(
          '[p2p_metrics_dart] hls_request proxy_setup_ms=$proxySetupMs p2p_request_ms=$p2pRequestMs total_ms=$totalMs bytes=$payloadLength session=$sessionId path=$hlsPath');
    } catch (e, stack) {
      debugPrint('[LocalProxy] Error handling HLS request: $e');
      debugPrint('[LocalProxy] Stack: $stack');

      try {
        request.response.statusCode = HttpStatus.internalServerError;
        _setCorsHeaders(request.response);
        request.response.write('Error: $e');
      } catch (_) {
        // Response may already be started or closed, best-effort cleanup below.
      } finally {
        await request.response.close();
      }
    }
  }

  Future<void> _handleDirectRequest(HttpRequest request, String path) async {
    try {
      // Parse path: /direct/{file_id}/stream
      final pathParts = path.substring('/direct/'.length).split('/');
      if (pathParts.length < 2) {
        request.response.statusCode = HttpStatus.badRequest;
        _setCorsHeaders(request.response);
        request.response.write(
            'Invalid direct path format. Expected: /direct/{file_id}/stream');
        await request.response.close();
        return;
      }

      final fileId = pathParts[0];

      if (fileId.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        _setCorsHeaders(request.response);
        request.response.write('File ID is required');
        await request.response.close();
        return;
      }

      await _forwardRangeRequest(
        request: request,
        sessionId: 'direct:$fileId',
        path: 'stream',
        logLabel: 'direct:$fileId',
      );
    } catch (e, stack) {
      debugPrint('[LocalProxy] Error handling direct request: $e');
      debugPrint('[LocalProxy] Stack: $stack');

      try {
        request.response.statusCode = HttpStatus.internalServerError;
        _setCorsHeaders(request.response);
        request.response.write('Error: $e');
      } catch (_) {
        // Response may already be started or closed, best-effort cleanup below.
      } finally {
        await request.response.close();
      }
    }
  }

  Future<void> _handleDownloadRequest(HttpRequest request, String path) async {
    try {
      // Parse path: /download/{job_id}/file
      final pathParts = path.substring('/download/'.length).split('/');
      if (pathParts.length < 2) {
        request.response.statusCode = HttpStatus.badRequest;
        _setCorsHeaders(request.response);
        request.response.write(
            'Invalid download path format. Expected: /download/{job_id}/file');
        await request.response.close();
        return;
      }

      final jobId = pathParts[0];

      if (jobId.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        _setCorsHeaders(request.response);
        request.response.write('Job ID is required');
        await request.response.close();
        return;
      }

      await _forwardRangeRequest(
        request: request,
        sessionId: 'download:$jobId',
        path: 'file',
        logLabel: 'download:$jobId',
      );
    } catch (e, stack) {
      debugPrint('[LocalProxy] Error handling download request: $e');
      debugPrint('[LocalProxy] Stack: $stack');

      try {
        request.response.statusCode = HttpStatus.internalServerError;
        _setCorsHeaders(request.response);
        request.response.write('Error: $e');
      } catch (_) {
        // Response may already be started or closed, best-effort cleanup below.
      } finally {
        await request.response.close();
      }
    }
  }

  /// Shared logic for streaming range requests via P2P.
  ///
  /// Sends a single P2P streaming request for the entire range and pipes
  /// chunks directly to the HTTP response as they arrive from QUIC. This
  /// eliminates per-sub-request overhead (QUIC stream setup, CBOR, auth,
  /// file stat) and lets QUIC congestion control ramp up within one stream.
  Future<void> _forwardRangeRequest({
    required HttpRequest request,
    required String sessionId,
    required String path,
    required String logLabel,
  }) async {
    final sw = Stopwatch()..start();

    if (_targetPeer == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      _setCorsHeaders(request.response);
      request.response.write('No target peer configured');
      await request.response.close();
      return;
    }

    // Parse the client's Range header.
    int? rangeStart;
    int? rangeEnd;
    final rangeHeader = request.headers.value('Range');
    if (rangeHeader != null) {
      final range = _parseRangeHeader(rangeHeader);
      rangeStart = range.$1;
      rangeEnd = range.$2;
    }

    debugPrint('[LocalProxy] P2P stream $logLabel range=$rangeStart-$rangeEnd');

    var bytesServed = 0;
    var chunkCount = 0;
    var headersSent = false;
    int? firstHeaderMs;
    int? firstChunkMs;

    try {
      final stream = _p2p.sendHlsRequestStreaming(
        peer: _targetPeer!,
        sessionId: sessionId,
        path: path,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        authToken: _authToken,
      );

      await for (final event in stream) {
        switch (event) {
          case FlutterHlsStreamEvent_Header(:final field0):
            firstHeaderMs = sw.elapsedMilliseconds;
            final header = field0;
            request.response.statusCode = header.status;
            request.response.headers.contentType =
                ContentType.parse(header.contentType);
            request.response.headers.contentLength =
                header.contentLength.toInt();
            if (header.contentRange != null) {
              request.response.headers
                  .set('Content-Range', header.contentRange!);
            }
            if (header.cacheControl != null) {
              request.response.headers
                  .set('Cache-Control', header.cacheControl!);
            }
            request.response.headers.set('Accept-Ranges', 'bytes');
            _setCorsHeaders(request.response);
            headersSent = true;

          case FlutterHlsStreamEvent_Chunk(:final field0):
            firstChunkMs ??= sw.elapsedMilliseconds;
            request.response.add(field0);
            bytesServed += field0.length;
            chunkCount++;

          case FlutterHlsStreamEvent_End():
            break;

          case FlutterHlsStreamEvent_Error(:final field0):
            if (!headersSent) {
              request.response.statusCode = HttpStatus.badGateway;
              _setCorsHeaders(request.response);
              request.response.write('P2P error: $field0');
            }
            debugPrint('[LocalProxy] P2P stream error for $logLabel: $field0');
        }
      }
    } catch (e) {
      // Client likely closed the connection (seek / stop).
      debugPrint('[LocalProxy] Stream interrupted for $logLabel: $e');
      if (!headersSent) {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          _setCorsHeaders(request.response);
          request.response.write('Error: $e');
        } catch (_) {}
      }
    }

    try {
      await request.response.close();
    } catch (_) {}

    final totalMs = sw.elapsedMilliseconds;
    final throughputMbps = totalMs > 0
        ? (bytesServed * 8.0 / (totalMs * 1000.0)).toStringAsFixed(2)
        : '0.00';
    debugPrint(
        '[p2p_metrics_dart] range_stream first_header_ms=$firstHeaderMs first_chunk_ms=$firstChunkMs total_ms=$totalMs bytes=$bytesServed chunks=$chunkCount throughput_mbps=$throughputMbps session=$sessionId path=$path');
  }

  void _setCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
  }

  /// Parse HTTP Range header.
  /// Returns (start, end) tuple. End may be null for open-ended ranges.
  (int?, int?) _parseRangeHeader(String header) {
    // Format: "bytes=start-end" or "bytes=start-"
    final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(header);
    if (match == null) return (null, null);

    final start = int.tryParse(match.group(1) ?? '');
    final endStr = match.group(2);
    final end =
        endStr != null && endStr.isNotEmpty ? int.tryParse(endStr) : null;

    return (start, end);
  }
}
