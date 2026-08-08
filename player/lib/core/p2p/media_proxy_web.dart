import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

// Uint8List comes from here rather than dart:typed_data, which the analyzer
// flags as redundant alongside it.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/core/p2p/media_proxy.dart';
import 'package:player/core/p2p/media_route.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/p2p/sw_protocol.dart';
import 'package:player/native/lib.dart'
    show
        FlutterHlsResponseHeader,
        FlutterHlsStreamEvent,
        FlutterHlsStreamEvent_Header,
        FlutterHlsStreamEvent_Chunk,
        FlutterHlsStreamEvent_End,
        FlutterHlsStreamEvent_Error;
import 'package:web/web.dart' as web;

/// How long [ServiceWorkerMediaProxy.start] waits for the worker to activate
/// and take control of the page.
///
/// Registration and activation are local work with no network in the path, so
/// this only ever elapses when something is actually wrong. Failing loudly
/// matters more than failing fast here: without a controlling worker every
/// media fetch goes straight to the network and 404s, and the resulting
/// playback failure says nothing about the cause.
const _controlTimeout = Duration(seconds: 10);

const _pollInterval = Duration(milliseconds: 20);

/// Serves media from the page's p2p connection through a Service Worker.
///
/// A browser cannot bind a socket, so the worker registered by [start] claims
/// the same paths `LocalProxyService` serves on desktop and forwards each one
/// here over a `MessageChannel`. The worker holds no p2p state of its own on
/// purpose: the browser is free to terminate an idle Service Worker, and a
/// QUIC connection living there would go with it mid-playback. This object,
/// which lives in the page, owns the connection.
class ServiceWorkerMediaProxy implements MediaProxy {
  ServiceWorkerMediaProxy(this._p2p);

  final P2pService _p2p;

  web.ServiceWorkerRegistration? _registration;
  String? _targetPeer;
  String? _authToken;

  /// Exchanges still delivering bytes to the worker, so [stop] can end them
  /// rather than leaving the worker waiting on a reply that never comes.
  final _inFlight = <_Exchange>{};

  @override
  bool get isRunning => _registration != null;

  /// Derived from the worker's scope rather than hardcoded to `/p2p`, because
  /// the same build is served from the origin root on web.mydia.dev and from
  /// `/player/` when an instance hosts it. sw.js derives its prefix from the
  /// same scope, so the two cannot disagree.
  @override
  String get baseUrl {
    final registration = _registration;
    if (registration == null) {
      throw StateError('ServiceWorkerMediaProxy is not started');
    }
    return _baseUrlFor(registration);
  }

  @override
  String buildHlsUrl(String sessionId) => MediaRoutes.hls(baseUrl, sessionId);

  @override
  String buildDirectStreamUrl(String fileId) =>
      MediaRoutes.directStream(baseUrl, fileId);

  @override
  Future<void> start({required String targetPeer, String? authToken}) async {
    // Assigned before the await so a request that arrives while an already
    // running proxy is being retargeted uses the new peer, matching
    // LocalProxyService's "update config if already running" behavior.
    _targetPeer = targetPeer;
    _authToken = authToken;
    if (_registration != null) return;

    final container = web.window.navigator.serviceWorker;

    // Relative, so it resolves against the document's base href: the build
    // copies web/sw.js next to index.html, wherever that is served from.
    final registration = await container.register('sw.js'.toJS).toDart;
    await _awaitControl(container, registration);

    container.onmessage = ((web.MessageEvent event) => _onMessage(event)).toJS;
    _registration = registration;

    debugPrint('[SwProxy] Serving media under ${_baseUrlFor(registration)}');
  }

  @override
  Future<void> stop() async {
    final registration = _registration;
    _registration = null;
    _targetPeer = null;
    _authToken = null;

    for (final exchange in _inFlight.toList()) {
      _finish(exchange);
    }

    if (registration == null) return;

    web.window.navigator.serviceWorker.onmessage = null;
    await registration.unregister().toDart;
    debugPrint('[SwProxy] Stopped');
  }

  static String _baseUrlFor(web.ServiceWorkerRegistration registration) =>
      '${Uri.parse(registration.scope).path}p2p';

  /// Wait for the worker to be activated *and* controlling this page.
  ///
  /// Both conditions matter: a worker that is active but has not claimed this
  /// client does not see its requests at all, so media fetches would silently
  /// bypass the proxy. Polled rather than driven off `controllerchange`
  /// because the worker can already be in either state when start() runs, in
  /// which case no further event is coming.
  Future<void> _awaitControl(
    web.ServiceWorkerContainer container,
    web.ServiceWorkerRegistration registration,
  ) async {
    final deadline = DateTime.now().add(_controlTimeout);

    while (registration.active == null || container.controller == null) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'The media Service Worker did not take control of this page within '
          '${_controlTimeout.inSeconds}s '
          '(active=${registration.active != null}, '
          'controlling=${container.controller != null}).',
        );
      }
      await Future<void>.delayed(_pollInterval);
    }
  }

  void _onMessage(web.MessageEvent event) {
    final data = event.data;
    if (data.isUndefinedOrNull) return;

    final decoded = data!.dartify();
    if (decoded is! Map) return;

    final message = decoded.map((key, value) => MapEntry('$key', value));
    if (message['type'] != 'p2p-request') return;

    final ports = event.ports.toDart;
    if (ports.isEmpty) return;

    unawaited(_serve(SwRequest.fromMessage(message), ports.first));
  }

  Future<void> _serve(SwRequest request, web.MessagePort port) async {
    final exchange = _Exchange(port);
    _inFlight.add(exchange);

    // The worker's only message back is a cancel, sent when the browser drops
    // the response body (a seek, or a closed tab).
    port.onmessage = ((web.MessageEvent _) => _finish(exchange)).toJS;

    final peer = _targetPeer;
    if (peer == null) {
      _serveBody(exchange, 503, 'No target peer configured');
      return;
    }

    switch (MediaRoutes.resolve(request.path)) {
      case MediaRouteFailure(:final statusCode, :final message):
        _serveBody(exchange, statusCode, message);

      case final MediaRouteMatch route when route.kind == MediaRouteKind.hls:
        await _serveHls(exchange, peer, route, request);

      case final MediaRouteMatch route:
        await _serveStream(exchange, peer, route, request);
    }
  }

  /// One bounded response, requested whole. Mirrors
  /// `LocalProxyService._handleHlsRequest`, including its buffered p2p call:
  /// manifests and segments are small, and a single round trip is what the
  /// desktop proxy is tuned for.
  Future<void> _serveHls(
    _Exchange exchange,
    String peer,
    MediaRouteMatch route,
    SwRequest request,
  ) async {
    var headSent = false;

    try {
      final response = await _p2p.sendHlsRequest(
        peer: peer,
        sessionId: route.sessionId,
        path: route.path,
        rangeStart: request.rangeStart,
        rangeEnd: request.rangeEnd,
        authToken: _authToken,
      );

      headSent = true;
      _post(
        exchange,
        _head(
          response.header.status,
          _headersFor(response.header, payloadLength: response.data.length),
        ),
      );
      _postChunk(exchange, response.data);
      _end(exchange);
    } catch (e) {
      debugPrint('[SwProxy] HLS request failed for ${request.path}: $e');
      // 500 with the message as the body, which is what the loopback proxy
      // answers. Once a head is out the status is already committed, so the
      // only way left to say the body is short is to error the stream.
      if (headSent) {
        _fail(exchange, 'Error: $e');
      } else {
        _serveBody(exchange, 500, 'Error: $e');
      }
    }
  }

  /// A file's bytes, streamed. Mirrors
  /// `LocalProxyService._forwardRangeRequest`: one p2p stream for the whole
  /// range, piped through as chunks arrive.
  Future<void> _serveStream(
    _Exchange exchange,
    String peer,
    MediaRouteMatch route,
    SwRequest request,
  ) async {
    final done = Completer<void>();
    var headSent = false;

    void finish() {
      if (!done.isCompleted) done.complete();
    }

    exchange.subscription = _p2p
        .sendHlsRequestStreaming(
      peer: peer,
      sessionId: route.sessionId,
      path: route.path,
      rangeStart: request.rangeStart,
      rangeEnd: request.rangeEnd,
      authToken: _authToken,
    )
        .listen(
      (event) {
        switch (event) {
          case FlutterHlsStreamEvent_Header(:final field0):
            headSent = true;
            _post(exchange, _head(field0.status, _headersFor(field0)));

          case FlutterHlsStreamEvent_Chunk(:final field0):
            _postChunk(exchange, field0);

          case FlutterHlsStreamEvent_End():
            // The `end` message is posted when the stream closes, below.
            break;

          case FlutterHlsStreamEvent_Error(:final field0):
            debugPrint('[SwProxy] P2P stream error for ${route.sessionId}: '
                '$field0');
            if (headSent) {
              _fail(exchange, 'P2P error: $field0');
            } else {
              _serveBody(exchange, 502, 'P2P error: $field0');
            }
            finish();
        }
      },
      onError: (Object e) {
        debugPrint('[SwProxy] Stream interrupted for ${route.sessionId}: $e');
        // 500 for a thrown error and 502 for a reported stream error, the
        // same split the loopback proxy makes.
        if (headSent) {
          _fail(exchange, 'Error: $e');
        } else {
          _serveBody(exchange, 500, 'Error: $e');
        }
        finish();
      },
      onDone: () {
        _end(exchange);
        finish();
      },
    );

    await done.future;
  }

  /// Serve a short body under [status]: the routing table's own errors, and
  /// the states the desktop proxy answers with a plain-text explanation.
  void _serveBody(_Exchange exchange, int status, String body) {
    final bytes = Uint8List.fromList(utf8.encode(body));
    _post(
      exchange,
      _head(status, {
        'content-type': 'text/plain',
        'content-length': '${bytes.length}',
        'access-control-allow-origin': '*',
      }),
    );
    _postChunk(exchange, bytes);
    _end(exchange);
  }

  Map<String, String> _headersFor(
    FlutterHlsResponseHeader header, {
    int? payloadLength,
  }) {
    final declared = header.contentLength.toInt();

    return {
      'content-type': header.contentType,
      // The declared length is trusted unless the payload we actually hold
      // disagrees, which is what LocalProxyService does on its buffered path:
      // a Content-Length that overstates the body leaves the browser waiting
      // for bytes that are never coming.
      'content-length':
          '${payloadLength != null && declared != payloadLength ? payloadLength : declared}',
      if (header.contentRange != null) 'content-range': header.contentRange!,
      if (header.cacheControl != null) 'cache-control': header.cacheControl!,
      'accept-ranges': 'bytes',
      'access-control-allow-origin': '*',
    };
  }

  Map<String, Object?> _head(int status, Map<String, String> headers) =>
      {'type': 'head', 'status': status, 'headers': headers};

  void _post(_Exchange exchange, Map<String, Object?> message) {
    if (exchange.closed) return;
    exchange.port.postMessage(message.jsify());
  }

  void _postChunk(_Exchange exchange, Uint8List data) {
    if (exchange.closed) return;
    exchange.port.postMessage({'type': 'chunk', 'data': data}.jsify());
  }

  void _end(_Exchange exchange) {
    _post(exchange, const {'type': 'end'});
    _finish(exchange);
  }

  void _fail(_Exchange exchange, String message) {
    _post(exchange, {'type': 'error', 'message': message});
    _finish(exchange);
  }

  void _finish(_Exchange exchange) {
    _inFlight.remove(exchange);
    exchange.close();
  }
}

/// One request the worker forwarded, and the port its reply goes back on.
class _Exchange {
  _Exchange(this.port);

  final web.MessagePort port;
  StreamSubscription<FlutterHlsStreamEvent>? subscription;
  bool closed = false;

  void close() {
    if (closed) return;
    closed = true;
    unawaited(subscription?.cancel());
    port.close();
  }
}

MediaProxy createMediaProxy(Ref ref) {
  final proxy = ServiceWorkerMediaProxy(ref.watch(p2pServiceProvider));
  ref.onDispose(() => proxy.stop());
  return proxy;
}
