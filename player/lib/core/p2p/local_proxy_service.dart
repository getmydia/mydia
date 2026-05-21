import 'dart:async';
import 'dart:io';
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
/// Torrent stream: /torrent/{session_id}/file/{file_id}/data
/// Direct stream: /direct/{file_id}/stream
/// Download: /download/{job_id}/file
class LocalProxyService {
  final P2pService _p2p;
  HttpServer? _server;

  /// The peer ID to send HLS requests to
  String? _targetPeer;

  /// Auth token for HLS requests
  String? _authToken;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  LocalProxyService(this._p2p);

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
    debugPrint('[LocalProxy] Stopped');
  }

  /// Build the HLS URL for a session.
  ///
  /// Returns the local proxy URL for the HLS playlist.
  /// The video player should use this URL to start playback.
  String buildHlsUrl(String sessionId) {
    if (_server == null) {
      throw StateError('LocalProxyService is not started');
    }
    return 'http://127.0.0.1:${_server!.port}/hls/$sessionId/index.m3u8';
  }

  /// Build the base URL for HLS content.
  ///
  /// HLS manifests will use relative URLs for segments,
  /// so they will resolve against this base URL.
  String buildBaseUrl(String sessionId) {
    if (_server == null) {
      throw StateError('LocalProxyService is not started');
    }
    return 'http://127.0.0.1:${_server!.port}/hls/$sessionId/';
  }

  /// Build a direct stream URL for a media file.
  ///
  /// This uses the P2P HLS protocol with a "direct:" session ID prefix
  /// to stream the raw file without HLS transcoding.
  String buildDirectStreamUrl(String fileId) {
    if (_server == null) {
      throw StateError('LocalProxyService is not started');
    }
    return 'http://127.0.0.1:${_server!.port}/direct/$fileId/stream';
  }

  /// Build a download URL for a completed transcode job.
  ///
  /// Uses the P2P HLS protocol with a "download:" session ID prefix
  /// to proxy the transcoded file download.
  String buildDownloadUrl(String jobId) {
    if (_server == null) {
      throw StateError('LocalProxyService is not started');
    }
    return 'http://127.0.0.1:${_server!.port}/download/$jobId/file';
  }

  /// Build a byte-stream URL for a torrent-backed file.
  String buildTorrentStreamUrl(String sessionId, int fileId) {
    if (_server == null) {
      throw StateError('LocalProxyService is not started');
    }
    return 'http://127.0.0.1:${_server!.port}/torrent/$sessionId/file/$fileId/data';
  }

  // Handle incoming HTTP requests
  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;

    debugPrint('[LocalProxy] ${request.method} $path');

    if (path.startsWith('/hls/')) {
      await _handleHlsRequest(request);
    } else if (path.startsWith('/torrent/')) {
      await _handleTorrentRequest(request);
    } else if (path.startsWith('/direct/')) {
      await _handleDirectRequest(request);
    } else if (path.startsWith('/download/')) {
      await _handleDownloadRequest(request);
    } else {
      request.response.statusCode = HttpStatus.notFound;
      _setCorsHeaders(request.response);
      request.response.write('Not Found');
      await request.response.close();
    }
  }

  Future<void> _handleTorrentRequest(HttpRequest request) async {
    try {
      final pathParts =
          request.uri.path.substring('/torrent/'.length).split('/');
      if (pathParts.length < 4) {
        request.response.statusCode = HttpStatus.badRequest;
        _setCorsHeaders(request.response);
        request.response.write(
            'Invalid torrent path format. Expected: /torrent/{session_id}/file/{file_id}/data');
        await request.response.close();
        return;
      }

      final sessionId = pathParts[0];
      final torrentPath = pathParts.sublist(1).join('/');

      if (sessionId.isEmpty || torrentPath.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        _setCorsHeaders(request.response);
        request.response.write('Session ID and path are required');
        await request.response.close();
        return;
      }

      await _forwardRangeRequest(
        request: request,
        sessionId: 'torrent:$sessionId',
        path: torrentPath,
        logLabel: 'torrent:$sessionId',
      );
    } catch (e, stack) {
      debugPrint('[LocalProxy] Error handling torrent request: $e');
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

  Future<void> _handleHlsRequest(HttpRequest request) async {
    final sw = Stopwatch()..start();
    try {
      // Parse path: /hls/{session_id}/{path...}
      final pathParts = request.uri.path.substring('/hls/'.length).split('/');
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

  Future<void> _handleDirectRequest(HttpRequest request) async {
    try {
      // Parse path: /direct/{file_id}/stream
      final pathParts =
          request.uri.path.substring('/direct/'.length).split('/');
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

  Future<void> _handleDownloadRequest(HttpRequest request) async {
    try {
      // Parse path: /download/{job_id}/file
      final pathParts =
          request.uri.path.substring('/download/'.length).split('/');
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
