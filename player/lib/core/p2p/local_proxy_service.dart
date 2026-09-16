import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/core/p2p/media_proxy.dart';
import 'package:player/core/p2p/media_route.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/p2p/p2p_range_stream.dart';
import 'package:player/core/p2p/range_source.dart';
import 'package:player/core/p2p/range_spool.dart';
import 'package:player/native/lib.dart' show FlutterHlsResponseHeader;

final localProxyServiceProvider = Provider<LocalProxyService>((ref) {
  final p2p = ref.watch(p2pServiceProvider);
  final service = LocalProxyService(p2p);
  ref.onDispose(() => service.shutdown());
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
class LocalProxyService with MediaProxyLeases implements MediaProxy {
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

  /// Byte-range transfers in flight, cancelled whenever the sockets they
  /// write to are closed.
  final Set<RangeSource> _activeSources = {};

  /// Counts those cancellations, so a request can tell the server it started
  /// on was closed while it was still opening its source.
  var _sourceCancellations = 0;

  int get port => _server?.port ?? 0;

  @override
  bool get isRunning => _server != null;

  /// Whether the proxy is currently reachable from other devices on the LAN.
  ///
  /// Requires a bound server, not just an address and token: without one there
  /// is nothing listening, and callers that trusted the looser check reported
  /// a nonexistent "port 0" to the user as the port to open in their firewall.
  bool get isLanAccessible =>
      _lanToken != null && _lanAddress != null && _server != null;

  /// Base URL other devices on the LAN can reach, or null when loopback-only.
  String? get lanBaseUrl {
    final server = _server;
    if (!isLanAccessible || server == null) return null;
    return 'http://$_lanAddress:${server.port}/g/$_lanToken';
  }

  /// Prefix applied to every locally built URL.
  String get _urlBase {
    if (_server == null) {
      throw StateError('LocalProxyService is not started');
    }
    return lanBaseUrl ?? 'http://127.0.0.1:${_server!.port}';
  }

  /// Delegates to [_urlBase] rather than reimplementing it: [_urlBase] is
  /// exactly what [_authorizeAndStripPrefix] expects callers to have used
  /// (loopback with no prefix, or the LAN address with `/g/<token>`), and
  /// every existing `buildXxxUrl` method is already proven against that
  /// contract. A separate implementation here could drift from it.
  @override
  String get baseUrl => _urlBase;

  LocalProxyService(
    this._p2p, {
    RangeSpoolSettings spool = const RangeSpoolSettings.platform(),
  }) : _spoolSettings = spool;

  final RangeSpoolSettings _spoolSettings;

  /// Where spool files go. Prepared the first time a spool is needed, which
  /// also clears whatever a crash left behind. Null when there is nowhere
  /// to spool.
  Future<Directory?>? _spoolDirectory;

  /// Test-only constructor: builds a service with no live P2P dependency.
  /// Requests that reach P2P will fail, which is fine for URL and gating tests.
  factory LocalProxyService.forTesting() => LocalProxyService(P2pService());

  /// Start the local proxy server.
  ///
  /// [targetPeer] - The peer ID or EndpointAddr JSON to send HLS requests to.
  /// [authToken] - Optional auth token for HLS requests.
  @override
  Future<void> start({
    required Object owner,
    required String targetPeer,
    String? authToken,
  }) async {
    acquireLease(owner);

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

  @override
  Future<void> stop(Object owner) async {
    if (!releaseLease(owner)) return;
    await _tearDown();
  }

  @override
  Future<void> shutdown() async {
    clearLeases();
    await _tearDown();
  }

  Future<void> _tearDown() async {
    // Forced. An ordinary close stops the listener and returns, but leaves
    // connections already accepted to carry on being served — by a proxy
    // whose target peer and auth token the next few lines null out. The
    // connection open here is the video pipeline's own: mpv holds a range
    // request for the whole file, so unforced it is left waiting on a socket
    // nothing will ever answer instead of seeing its stream end.
    await _cancelActiveSources();
    await _server?.close(force: true);
    _server = null;
    _targetPeer = null;
    _authToken = null;
    _lanToken = null;
    _lanAddress = null;
    debugPrint('[LocalProxy] Stopped');
  }

  /// Interface name prefixes that are never the address a TV on the sofa can
  /// reach: VPN tunnels, Apple's peer-to-peer radio, container and VM bridges.
  /// Advertising one of these to a receiver produces a URL that times out.
  static const _nonLanInterfacePrefixes = [
    'utun', // macOS/iOS VPN tunnels
    'ipsec',
    'ppp',
    'tun',
    'tap',
    'wg', // WireGuard
    'awdl', // Apple Wireless Direct Link
    'llw',
    'docker',
    'br-', // Docker user-defined bridges
    'veth',
    'vboxnet',
    'vmnet',
  ];

  /// Find a usable non-loopback IPv4 address for receiver-facing URLs.
  ///
  /// Returns null when the device has no LAN interface, in which case casting
  /// must fall back to the direct-server route.
  ///
  /// Interface order from the OS is arbitrary, so "the first non-loopback
  /// IPv4" happily hands a receiver a VPN or Docker-bridge address. Real LAN
  /// interfaces are preferred by name and by RFC 1918 range, with anything
  /// else used only as a last resort.
  static Future<String?> resolveLanAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );

      String? fallback;

      for (final interface in interfaces) {
        final excluded = isNonLanInterface(interface.name);

        for (final address in interface.addresses) {
          if (address.isLoopback) continue;

          if (!excluded && isPrivateIPv4(address.address)) {
            return address.address;
          }

          fallback ??= excluded ? null : address.address;
        }
      }

      return fallback;
    } catch (e) {
      debugPrint('[LocalProxy] Failed to resolve LAN address: $e');
    }
    return null;
  }

  /// Whether [name] is an interface that cannot carry LAN traffic to a
  /// receiver. Exposed for tests: the real interface list is machine specific.
  static bool isNonLanInterface(String name) {
    final lower = name.toLowerCase();
    return _nonLanInterfacePrefixes.any(lower.startsWith);
  }

  /// Whether [address] is in an RFC 1918 private range — where home LANs live.
  static bool isPrivateIPv4(String address) {
    final parts = address.split('.');
    if (parts.length != 4) return false;

    final first = int.tryParse(parts[0]);
    final second = int.tryParse(parts[1]);
    if (first == null || second == null) return false;

    if (first == 10) return true;
    if (first == 192 && second == 168) return true;
    if (first == 172 && second >= 16 && second <= 31) return true;
    return false;
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

    // Forced for the same reason as [_tearDown]: rebinding on a fresh port
    // invalidates whatever URL the video pipeline is holding regardless, and
    // the caller restarts local playback afterwards. Left unforced, the
    // request in flight against the old port would hang rather than end.
    await _cancelActiveSources();
    await _server?.close(force: true);
    _server = null;

    if (peer == null) {
      // Nothing to rebind: there is no proxy running to expose. Drop the
      // address and token again so `isLanAccessible` does not claim a
      // listener that was never created.
      _lanAddress = null;
      _lanToken = null;
      debugPrint('[LocalProxy] setLanAccess($enabled) with no proxy running');
      return;
    }

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
  @override
  String buildHlsUrl(String sessionId) => MediaRoutes.hls(_urlBase, sessionId);

  /// Build the base URL for HLS content. Manifests use relative segment URLs,
  /// which resolve against this base — including the LAN token prefix.
  String buildBaseUrl(String sessionId) =>
      MediaRoutes.hlsBase(_urlBase, sessionId);

  /// Build a direct stream URL for a media file.
  ///
  /// This uses the P2P HLS protocol with a "direct:" session ID prefix
  /// to stream the raw file without HLS transcoding.
  @override
  String buildDirectStreamUrl(String fileId) =>
      MediaRoutes.directStream(_urlBase, fileId);

  /// Build a download URL for a completed transcode job.
  ///
  /// Uses the P2P HLS protocol with a "download:" session ID prefix
  /// to proxy the transcoded file download.
  String buildDownloadUrl(String jobId) =>
      MediaRoutes.download(_urlBase, jobId);

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

    // The routing table is shared with the browser's Service Worker rather
    // than repeated here: both have to take apart the same URLs the same way.
    switch (MediaRoutes.resolve(path)) {
      case MediaRouteFailure(:final statusCode, :final message):
        request.response.statusCode = statusCode;
        _setCorsHeaders(request.response);
        request.response.write(message);
        await request.response.close();

      case final MediaRouteMatch route when route.kind == MediaRouteKind.hls:
        await _handleHlsRequest(request, route);

      case final MediaRouteMatch route:
        await _forwardRangeRequest(request: request, route: route);
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

    return (
      statusCode: HttpStatus.ok,
      path: rawPath.substring(expected.length)
    );
  }

  /// Test hook: returns the status code `_handleRequest` would produce for a
  /// path, without needing a live socket.
  Future<int> debugHandlePath(String path) async =>
      _authorizeAndStripPrefix(path).statusCode;

  Future<void> _handleHlsRequest(
      HttpRequest request, MediaRouteMatch route) async {
    final sw = Stopwatch()..start();
    try {
      final sessionId = route.sessionId;
      final hlsPath = route.path;

      if (_targetPeer == null) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        _setCorsHeaders(request.response);
        request.response.write('No target peer configured');
        await request.response.close();
        return;
      }

      // Parse Range header for seeking support
      final (rangeStart, rangeEnd) = _requestedRange(request);

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

  /// Streams a byte range from the server to the client.
  ///
  /// The body comes from a [RangeSource] and is pulled as the socket takes
  /// it. The source is cancelled as soon as the client goes away: mpv closes
  /// its connection on every seek and opens a new one, and a transfer left
  /// running would carry on to the end of the file, sharing the p2p link
  /// with the one that is playing.
  Future<void> _forwardRangeRequest({
    required HttpRequest request,
    required MediaRouteMatch route,
  }) async {
    final sessionId = route.sessionId;
    final path = route.path;
    final response = request.response;
    final sw = Stopwatch()..start();
    final cancellations = _sourceCancellations;

    RangeSource? source;
    var bytesServed = 0;
    var chunkCount = 0;
    int? firstHeaderMs;
    int? firstChunkMs;

    // Everything is inside the try, including the checks before the stream is
    // opened. The dispatcher does not await this, so anything that escapes
    // here surfaces as an unhandled async error rather than a response.
    try {
      final peer = _targetPeer;
      if (peer == null) {
        response.statusCode = HttpStatus.serviceUnavailable;
        _setCorsHeaders(response);
        response.write('No target peer configured');
        return;
      }

      final (rangeStart, rangeEnd) = _requestedRange(request);
      debugPrint(
          '[LocalProxy] P2P stream $sessionId range=$rangeStart-$rangeEnd');

      final P2pRangeStream upstream;
      try {
        upstream = await _p2p.openRangeStream(
          peer: peer,
          sessionId: sessionId,
          path: path,
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
          authToken: _authToken,
        );
      } catch (e) {
        debugPrint('[LocalProxy] P2P stream error for $sessionId: $e');
        response.statusCode = HttpStatus.badGateway;
        _setCorsHeaders(response);
        response.write('P2P error: $e');
        return;
      }
      firstHeaderMs = sw.elapsedMilliseconds;
      _applyUpstreamHeaders(response, upstream.header);

      // Opening a spool waits on the disk, so the upstream is tracked on its
      // own until then: a shutdown in that window still has to cancel it.
      final opening = PassThroughSource(upstream);
      _activeSources.add(opening);
      final RangeSource active;
      try {
        active = source = await _openSource(upstream, sessionId);
      } finally {
        _activeSources.remove(opening);
        if (source == null) await opening.cancel();
      }

      // The server was closed while the source was opening, so nothing will
      // read it. The `finally` below cancels it.
      if (cancellations != _sourceCancellations) return;
      _activeSources.add(active);

      // `done` is the only sign dart:io gives of a client that hung up:
      // writes to its socket still succeed and are dropped. It fires on the
      // first write after the hang-up, so a stalled upstream, which writes
      // nothing, is cancelled once it resumes.
      final clientGone = response.done
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(active.cancel);

      final body = active.bytes().map((chunk) {
        firstChunkMs ??= sw.elapsedMilliseconds;
        bytesServed += chunk.length;
        chunkCount++;
        return chunk;
      });

      // Raced with the hang-up because addStream is not guaranteed to
      // complete once its socket is gone.
      await Future.any([response.addStream(body), clientGone]);
    } catch (e) {
      debugPrint('[LocalProxy] Stream interrupted for $sessionId: $e');
    } finally {
      final finished = source;
      if (finished != null) {
        _activeSources.remove(finished);
        await finished.cancel();
      }

      try {
        await response.close();
      } catch (_) {}

      final totalMs = sw.elapsedMilliseconds;
      final throughputMbps = totalMs > 0
          ? (bytesServed * 8.0 / (totalMs * 1000.0)).toStringAsFixed(2)
          : '0.00';
      debugPrint(
          '[p2p_metrics_dart] range_stream first_header_ms=$firstHeaderMs first_chunk_ms=$firstChunkMs total_ms=$totalMs bytes=$bytesServed chunks=$chunkCount throughput_mbps=$throughputMbps spooled=${finished?.spooledBytes ?? 0} truncations=${finished?.truncations ?? 0} session=$sessionId path=$path');
    }
  }

  /// The source a byte-range response is served from.
  ///
  /// Direct playback spools to disk, so a stream that is never seeked
  /// downloads the whole file ahead of the player. Downloads do not: the
  /// download job is already writing the bytes to a file of its own.
  Future<RangeSource> _openSource(
    P2pRangeStream upstream,
    String sessionId,
  ) async {
    if (!sessionId.startsWith(MediaRoutes.directSessionPrefix)) {
      return PassThroughSource(upstream);
    }

    final directory = await (_spoolDirectory ??= _prepareSpoolDirectory());
    final spool = directory == null
        ? null
        : await RangeSpool.open(
            upstream: upstream,
            directory: directory,
            diskSpace: _spoolSettings.diskSpace,
            policy: _spoolSettings.policy,
          );
    if (spool != null) return spool;

    debugPrint(
        '[LocalProxy] No room to spool $sessionId, streaming without read-ahead');
    return PassThroughSource(upstream);
  }

  Future<Directory?> _prepareSpoolDirectory() async {
    try {
      final root = await _spoolSettings.rootDirectory();
      final directory = Directory('${root.path}/mydia-proxy-spool');
      if (await directory.exists()) await directory.delete(recursive: true);
      return await directory.create(recursive: true);
    } catch (e) {
      debugPrint('[LocalProxy] No spool directory: $e');
      return null;
    }
  }

  /// Cancels every byte-range transfer in flight. Their sockets are about to
  /// close, and the transfers must not outlive them.
  Future<void> _cancelActiveSources() async {
    _sourceCancellations++;
    final sources = _activeSources.toList();
    _activeSources.clear();
    await Future.wait(sources.map((source) => source.cancel()));
  }

  void _applyUpstreamHeaders(
    HttpResponse response,
    FlutterHlsResponseHeader header,
  ) {
    response.statusCode = header.status;
    response.headers.contentType = ContentType.parse(header.contentType);
    response.headers.contentLength = header.contentLength.toInt();
    final contentRange = header.contentRange;
    if (contentRange != null) {
      response.headers.set('Content-Range', contentRange);
    }
    final cacheControl = header.cacheControl;
    if (cacheControl != null) {
      response.headers.set('Cache-Control', cacheControl);
    }
    response.headers.set('Accept-Ranges', 'bytes');
    _setCorsHeaders(response);
  }

  /// The request's Range header as (start, end), either of which may be null.
  (int?, int?) _requestedRange(HttpRequest request) {
    final header = request.headers.value('Range');
    return header == null ? (null, null) : _parseRangeHeader(header);
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
