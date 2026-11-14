import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/native/lib.dart';

/// Stands in for the native host. Only the peer files surface is exercised;
/// anything else lands in `noSuchMethod` and fails loudly.
class _FakeHost implements P2PHost {
  // Closed by each test through addTearDown.
  // ignore: close_sinks
  final inbound = StreamController<FlutterInboundPeerFilesRequest>();
  final responses = <(String, FlutterPeerFilesResponse)>[];
  final sent = <(String, FlutterPeerFilesRequest)>[];

  @override
  Stream<FlutterInboundPeerFilesRequest> peerFilesStream() => inbound.stream;

  @override
  Future<void> respondToPeerFiles({
    required String requestId,
    required FlutterPeerFilesResponse res,
  }) async {
    responses.add((requestId, res));
  }

  @override
  Future<FlutterPeerFilesResponse> sendPeerFiles({
    required String peer,
    required FlutterPeerFilesRequest req,
  }) async {
    sent.add((peer, req));
    return const FlutterPeerFilesResponse.notAuthorized();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('an inbound peer files request surfaces on onPeerFilesRequest',
      () async {
    final host = _FakeHost();
    addTearDown(host.inbound.close);
    final service = P2pService()..debugSetHost(host);
    addTearDown(service.dispose);

    final received = <FlutterInboundPeerFilesRequest>[];
    service.onPeerFilesRequest.listen(received.add);

    host.inbound.add(const FlutterInboundPeerFilesRequest(
      peer: 'peer1',
      requestId: 'req1',
      request: FlutterPeerFilesRequest.manifest(authProof: 'proof'),
    ));
    await pumpEventQueue();

    expect(received, hasLength(1));
    expect(received.single.requestId, 'req1');
    expect(received.single.request,
        const FlutterPeerFilesRequest.manifest(authProof: 'proof'));
  });

  test('respondToPeerFiles and sendPeerFiles reach the host', () async {
    final host = _FakeHost();
    addTearDown(host.inbound.close);
    final service = P2pService()..debugSetHost(host);
    addTearDown(service.dispose);

    await service.respondToPeerFiles(
        'req1', const FlutterPeerFilesResponse.staleRevision());
    expect(host.responses.single.$1, 'req1');
    expect(host.responses.single.$2,
        const FlutterPeerFilesResponse.staleRevision());

    final res = await service.sendPeerFiles(
        'peer1', const FlutterPeerFilesRequest.manifest(authProof: 'p'));
    expect(res, const FlutterPeerFilesResponse.notAuthorized());
    expect(host.sent.single.$1, 'peer1');
  });

  test('without a host, respond is a no-op and send throws', () async {
    final service = P2pService();
    addTearDown(service.dispose);
    await service.respondToPeerFiles(
        'req1', const FlutterPeerFilesResponse.notAuthorized());
    expect(
      () => service.sendPeerFiles(
          'p', const FlutterPeerFilesRequest.manifest(authProof: 'x')),
      throwsException,
    );
  });
}
