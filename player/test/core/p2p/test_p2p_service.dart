import 'dart:typed_data';

import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/native/lib.dart';

/// One request a proxy forwarded over p2p, recorded for assertions.
class P2pRequestCall {
  final String peer;
  final String sessionId;
  final String path;
  final int? rangeStart;
  final int? rangeEnd;
  final String? authToken;

  const P2pRequestCall({
    required this.peer,
    required this.sessionId,
    required this.path,
    required this.rangeStart,
    required this.rangeEnd,
    required this.authToken,
  });
}

/// A P2pService that answers from a handler instead of a QUIC connection.
///
/// Shared by the loopback proxy's tests and the conformance suite, which both
/// need a peer that returns known bytes. Lives outside either test file so
/// there is one fake to keep in step with `P2pService`, not two.
class TestP2pService extends P2pService {
  final List<P2pRequestCall> calls = [];

  Future<FlutterHlsResponse> Function(P2pRequestCall call)? onSendHlsRequest;

  /// Set only by tests that need to control the event sequence itself. When
  /// left null, streaming replays [onSendHlsRequest]'s response as a header,
  /// one chunk and an end, so a test that configures the buffered handler gets
  /// consistent answers on both paths.
  Stream<FlutterHlsStreamEvent> Function(P2pRequestCall call)?
      onSendHlsRequestStreaming;

  @override
  Future<FlutterHlsResponse> sendHlsRequest({
    required String peer,
    required String sessionId,
    required String path,
    int? rangeStart,
    int? rangeEnd,
    String? authToken,
  }) async {
    final call = _record(
      peer: peer,
      sessionId: sessionId,
      path: path,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      authToken: authToken,
    );

    return _respond(call);
  }

  @override
  Stream<FlutterHlsStreamEvent> sendHlsRequestStreaming({
    required String peer,
    required String sessionId,
    required String path,
    int? rangeStart,
    int? rangeEnd,
    String? authToken,
  }) async* {
    final call = _record(
      peer: peer,
      sessionId: sessionId,
      path: path,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      authToken: authToken,
    );

    final streaming = onSendHlsRequestStreaming;
    if (streaming != null) {
      yield* streaming(call);
      return;
    }

    final response = await _respond(call);
    yield FlutterHlsStreamEvent.header(response.header);
    yield FlutterHlsStreamEvent.chunk(response.data);
    yield const FlutterHlsStreamEvent.end();
  }

  P2pRequestCall _record({
    required String peer,
    required String sessionId,
    required String path,
    required int? rangeStart,
    required int? rangeEnd,
    required String? authToken,
  }) {
    final call = P2pRequestCall(
      peer: peer,
      sessionId: sessionId,
      path: path,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      authToken: authToken,
    );
    calls.add(call);
    return call;
  }

  Future<FlutterHlsResponse> _respond(P2pRequestCall call) {
    final handler = onSendHlsRequest;
    if (handler == null) {
      throw Exception('P2P handler not configured');
    }
    return handler(call);
  }
}

/// Build a response the way the remote instance would.
FlutterHlsResponse testHlsResponse({
  required int status,
  required String contentType,
  required List<int> data,
  String? contentRange,
  String? cacheControl,
  int? declaredLength,
}) {
  return FlutterHlsResponse(
    header: FlutterHlsResponseHeader(
      status: status,
      contentType: contentType,
      contentLength: BigInt.from(declaredLength ?? data.length),
      contentRange: contentRange,
      cacheControl: cacheControl,
    ),
    data: Uint8List.fromList(data),
  );
}
