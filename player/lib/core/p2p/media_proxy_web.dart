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
import 'package:player/native/lib.dart' show FlutterHlsResponseHeader;
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

/// The worker script, relative to the document's base href.
///
/// It has to sit beside index.html, not in a subdirectory. A worker controls
/// only clients whose URL falls inside its scope, and it then intercepts every
/// request those clients make, whatever the request URL is. A worker under
/// `p2p/` would have scope `p2p/`, which does not contain the app page, so it
/// would control nothing and every media fetch would go to the network. That
/// is measured: registering from `p2p/sw.js` leaves the page at
/// `active=true, controlling=false` until [_controlTimeout] elapses.
const _scriptPath = 'sw.js';

/// Serves media from the page's p2p connection through a Service Worker.
///
/// A browser cannot bind a socket, so the worker registered by [start] claims
/// the same paths `LocalProxyService` serves on desktop and forwards each one
/// here over a `MessageChannel`. The worker holds no p2p state of its own on
/// purpose: the browser is free to terminate an idle Service Worker, and a
/// QUIC connection living there would go with it mid-playback. This object,
/// which lives in the page, owns the connection.
class ServiceWorkerMediaProxy with MediaProxyLeases implements MediaProxy {
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
  Future<void> start({
    required Object owner,
    required String targetPeer,
    String? authToken,
  }) async {
    acquireLease(owner);

    // Assigned before the await so a request that arrives while an already
    // running proxy is being retargeted uses the new peer, matching
    // LocalProxyService's "update config if already running" behavior.
    _targetPeer = targetPeer;
    _authToken = authToken;
    if (_registration != null) return;

    final container = web.window.navigator.serviceWorker;

    // Relative, so it resolves against the document's base href: the build
    // copies web/sw.js next to index.html, wherever that is served from.
    final scriptUrl = _resolvedScriptUrl();
    final registration = await container.register(_scriptPath.toJS).toDart;
    await _awaitControl(container, registration, scriptUrl);

    container.onmessage = ((web.MessageEvent event) => _onMessage(event)).toJS;
    _registration = registration;

    debugPrint('[SwProxy] Serving media under ${_baseUrlFor(registration)}');
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
    final registration = _registration;
    _registration = null;
    _targetPeer = null;
    _authToken = null;

    // Fail them rather than just closing the port. The worker is waiting on a
    // reply for each one, and a closed port is not an answer: the fetch would
    // hang instead of failing. Closing the socket is what the loopback proxy
    // does, and an error is the closest equivalent here.
    for (final exchange in _inFlight.toList()) {
      _fail(exchange, 'Media proxy stopped');
    }

    if (registration == null) return;

    web.window.navigator.serviceWorker.onmessage = null;
    await registration.unregister().toDart;
    debugPrint('[SwProxy] Stopped');
  }

  static String _baseUrlFor(web.ServiceWorkerRegistration registration) =>
      '${Uri.parse(registration.scope).path}p2p';

  /// Absolute URL of [_scriptPath], resolved the way `register` resolves it.
  static String _resolvedScriptUrl() =>
      Uri.parse(web.document.baseURI).resolve(_scriptPath).toString();

  /// Wait for *our* worker to be activated and controlling this page.
  ///
  /// All three conditions matter. A worker that is active but has not claimed
  /// this client does not see its requests at all, so media fetches would
  /// silently bypass the proxy. And a scope holds exactly one registration, so
  /// the controller during a takeover can still be the script that held the
  /// scope before this one: without comparing script URLs, someone else's
  /// worker being in control reads as success and every media fetch 404s with
  /// nothing to point at the cause.
  ///
  /// Polled rather than driven off `controllerchange` because the worker can
  /// already be in either state when start() runs, in which case no further
  /// event is coming.
  Future<void> _awaitControl(
    web.ServiceWorkerContainer container,
    web.ServiceWorkerRegistration registration,
    String scriptUrl,
  ) async {
    final deadline = DateTime.now().add(_controlTimeout);

    while (registration.active?.scriptURL != scriptUrl ||
        container.controller?.scriptURL != scriptUrl) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'The media Service Worker did not take control of this page within '
          '${_controlTimeout.inSeconds}s. Expected $scriptUrl, but the worker '
          'is active=${registration.active?.scriptURL} '
          'controlling=${container.controller?.scriptURL}.',
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

      case MediaRouteMatch():
        // `/direct/` and `/download/`, both of which are native-only today:
        // direct play is gated on `!kIsWeb` and downloads are stubbed out in
        // the browser, so nothing here can build one of these URLs.
        //
        // Answered rather than implemented on purpose. A streaming version
        // shipped here would be dead code no test covers, and the one that was
        // written had a leak in it: cancelling the p2p subscription means
        // `onDone` never fires, so the completer it awaited never completed
        // and the exchange hung for the life of the page. A future change that
        // flips either gate should have to add the implementation and its
        // tests deliberately, not silently revive an untested path.
        _serveBody(
          exchange,
          501,
          'Byte-range streaming is native only; the browser proxy serves HLS.',
        );
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
  bool closed = false;

  void close() {
    if (closed) return;
    closed = true;
    port.close();
  }
}

MediaProxy createMediaProxy(Ref ref) {
  final proxy = ServiceWorkerMediaProxy(ref.watch(p2pServiceProvider));
  ref.onDispose(() => proxy.shutdown());
  return proxy;
}
