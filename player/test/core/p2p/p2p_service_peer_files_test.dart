import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/core/p2p/peer_files_transport.dart';
import 'package:player/native/lib.dart';

/// Stands in for the native host. Only the peer files surface is exercised;
/// anything else lands in `noSuchMethod` and fails loudly.
class _FakeHost implements P2PHost {
  // Closed by each test through addTearDown.
  // ignore: close_sinks
  final inbound = StreamController<FlutterInboundPeerFilesRequest>();
  final responses = <(String, FlutterPeerFilesResponse)>[];
  final sent = <(String, FlutterPeerFilesRequest)>[];
  // Closed by each test through addTearDown.
  // ignore: close_sinks
  final grantRequests = StreamController<FlutterPeerFileGrantRequest>();
  final grantResponses = <(String, FlutterPeerFileGrant?)>[];
  final members = <List<String>>[];
  final invalidated = <String>[];

  @override
  Stream<FlutterPeerFileGrantRequest> peerFileGrantStream() =>
      grantRequests.stream;

  @override
  Future<void> respondPeerFileGrant({
    required String requestId,
    FlutterPeerFileGrant? grant,
  }) async {
    grantResponses.add((requestId, grant));
  }

  @override
  Future<void> setPeerFilesMembers({required List<String> nodeIds}) async {
    members.add(nodeIds);
  }

  @override
  Future<void> invalidatePeerFileGrants({required String accountId}) async {
    invalidated.add(accountId);
  }

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

  test('grant requests surface and the grant calls reach the host', () async {
    final host = _FakeHost();
    addTearDown(host.inbound.close);
    addTearDown(host.grantRequests.close);
    final service = P2pService()..debugSetHost(host);
    addTearDown(service.dispose);
    final transport = P2pPeerFilesTransport(service);

    final received = <FlutterPeerFileGrantRequest>[];
    transport.onPeerFileGrantRequest.listen(received.add);
    host.grantRequests.add(const FlutterPeerFileGrantRequest(
        requestId: 'g1', accountId: 'acct', path: 'a/b.txt'));
    await pumpEventQueue();
    expect(received.single.requestId, 'g1');
    expect(received.single.path, 'a/b.txt');

    const grant = FlutterPeerFileGrant(url: 'file:///x', headers: []);
    await transport.respondPeerFileGrant('g1', grant);
    await transport.respondPeerFileGrant('g2', null);
    await transport.setPeerFilesMembers(['n1', 'n2']);
    await transport.invalidatePeerFileGrants('acct');
    expect(host.grantResponses, [('g1', grant), ('g2', null)]);
    expect(host.members.single, ['n1', 'n2']);
    expect(host.invalidated.single, 'acct');
  });

  test('the adapter forwards peer files calls and requests', () async {
    final host = _FakeHost();
    addTearDown(host.inbound.close);
    addTearDown(host.grantRequests.close);
    final service = P2pService()..debugSetHost(host);
    addTearDown(service.dispose);
    final transport = P2pPeerFilesTransport(service);

    final received = <FlutterInboundPeerFilesRequest>[];
    transport.onPeerFilesRequest.listen(received.add);
    host.inbound.add(const FlutterInboundPeerFilesRequest(
      peer: 'peer1',
      requestId: 'req1',
      request: FlutterPeerFilesRequest.manifest(authProof: 'proof'),
    ));
    await pumpEventQueue();
    expect(received.single.requestId, 'req1');

    await transport.respondToPeerFiles(
        'req1', const FlutterPeerFilesResponse.staleRevision());
    expect(host.responses.single.$1, 'req1');
    final res = await transport.sendPeerFiles(
        'peer1', const FlutterPeerFilesRequest.manifest(authProof: 'p'));
    expect(res, const FlutterPeerFilesResponse.notAuthorized());
  });

  test('the member allowlist set before a host exists reaches each new host',
      () async {
    final service = P2pService();
    addTearDown(service.dispose);
    await service.setPeerFilesMembers(['n1', 'n2']);

    final first = _FakeHost();
    addTearDown(first.inbound.close);
    addTearDown(first.grantRequests.close);
    service.debugSetHost(first);
    expect(first.members, [
      ['n1', 'n2']
    ]);

    await service.setPeerFilesMembers(['n3']);
    expect(first.members.last, ['n3']);

    // A host built again (a reset, a relay change) starts with no list.
    final second = _FakeHost();
    addTearDown(second.inbound.close);
    addTearDown(second.grantRequests.close);
    service.debugSetHost(second);
    expect(second.members, [
      ['n3']
    ]);
  });

  test('a host with no list set is pushed none', () async {
    final host = _FakeHost();
    addTearDown(host.inbound.close);
    addTearDown(host.grantRequests.close);
    final service = P2pService()..debugSetHost(host);
    addTearDown(service.dispose);
    expect(host.members, isEmpty);
  });

  test('without a host the grant calls are no-ops', () async {
    final service = P2pService();
    addTearDown(service.dispose);
    await service.respondPeerFileGrant('g', null);
    await service.setPeerFilesMembers(['n']);
    await service.invalidatePeerFileGrants('acct');
  });
}
