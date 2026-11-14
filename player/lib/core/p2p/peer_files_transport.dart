import 'dart:async';

import '../../native/lib.dart';
import 'p2p_range_stream.dart';
import 'p2p_service.dart';

/// The slice of [P2pService] that peer file sharing needs. Services depend on
/// this rather than on [P2pService] so tests can substitute a fake.
abstract interface class PeerFilesTransport {
  Stream<FlutterInboundPeerFilesRequest> get onPeerFilesRequest;
  Stream<FlutterPeerFileGrantRequest> get onPeerFileGrantRequest;
  Future<FlutterPeerFilesResponse> sendPeerFiles(
    String peer,
    FlutterPeerFilesRequest request,
  );
  Future<void> respondToPeerFiles(
    String requestId,
    FlutterPeerFilesResponse response,
  );
  Future<void> respondPeerFileGrant(
    String requestId,
    FlutterPeerFileGrantAnswer answer,
  );
  Future<void> setPeerFilesMembers(List<String> nodeIds);
  Future<void> invalidatePeerFileGrants(String accountId);

  /// Connects to a peer by its EndpointAddr JSON, as the roster stores it.
  Future<void> dial(String endpointAddrJson);
  Future<P2pRangeStream> openRangeStream({
    required String peer,
    required String sessionId,
    required String path,
    int? rangeStart,
    int? rangeEnd,
    String? authToken,
  });
}

class P2pPeerFilesTransport implements PeerFilesTransport {
  P2pPeerFilesTransport(this._p2pService);

  final P2pService _p2pService;

  @override
  Stream<FlutterInboundPeerFilesRequest> get onPeerFilesRequest =>
      _p2pService.onPeerFilesRequest;

  @override
  Stream<FlutterPeerFileGrantRequest> get onPeerFileGrantRequest =>
      _p2pService.onPeerFileGrantRequest;

  @override
  Future<FlutterPeerFilesResponse> sendPeerFiles(
    String peer,
    FlutterPeerFilesRequest request,
  ) =>
      _p2pService.sendPeerFiles(peer, request);

  @override
  Future<void> respondToPeerFiles(
    String requestId,
    FlutterPeerFilesResponse response,
  ) =>
      _p2pService.respondToPeerFiles(requestId, response);

  @override
  Future<void> respondPeerFileGrant(
    String requestId,
    FlutterPeerFileGrantAnswer answer,
  ) =>
      _p2pService.respondPeerFileGrant(requestId, answer);

  @override
  Future<void> setPeerFilesMembers(List<String> nodeIds) =>
      _p2pService.setPeerFilesMembers(nodeIds);

  @override
  Future<void> invalidatePeerFileGrants(String accountId) =>
      _p2pService.invalidatePeerFileGrants(accountId);

  @override
  Future<void> dial(String endpointAddrJson) =>
      _p2pService.dial(endpointAddrJson);

  @override
  Future<P2pRangeStream> openRangeStream({
    required String peer,
    required String sessionId,
    required String path,
    int? rangeStart,
    int? rangeEnd,
    String? authToken,
  }) =>
      _p2pService.openRangeStream(
        peer: peer,
        sessionId: sessionId,
        path: path,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        authToken: authToken,
      );
}
