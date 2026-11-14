import 'package:player/core/p2p/media_proxy.dart';
import 'package:player/core/p2p/p2p_range_stream.dart';
import 'package:player/core/p2p/peer_files_transport.dart';

import 'fake_range_stream.dart';

/// A proxy that records which targets are started and stopped, and by whom.
class FakePeerProxy implements MediaProxy {
  final starts = <({String targetPeer, String target})>[];
  final stops = <String>[];

  /// Who holds each target: the owners of starts not yet stopped.
  final holders = <String, Set<Object>>{};

  @override
  Future<void> start({
    required Object owner,
    required String targetPeer,
    String? authToken,
    required String target,
  }) async {
    starts.add((targetPeer: targetPeer, target: target));
    (holders[target] ??= Set.identity()).add(owner);
  }

  @override
  Future<void> stop(Object owner, {required String target}) async {
    stops.add(target);
    holders[target]?.remove(owner);
  }

  @override
  String targetBaseUrl(String target) => 'http://127.0.0.1:4000/t/$target';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A transport whose range opens all answer with [answer]: a stream to
/// return, or an exception to throw.
class FakePeerRangeTransport implements PeerFilesTransport {
  FakePeerRangeTransport(this.answer);

  Object answer;
  final opens = <({
    String peer,
    String sessionId,
    String path,
    int? rangeStart,
    int? rangeEnd
  })>[];
  final streams = <FakeRangeStream>[];

  /// Every call in order: `dial <address>` and `open <peer>`.
  final calls = <String>[];

  /// Thrown by [dial] when set.
  Exception? dialFailure;

  @override
  Future<void> dial(String endpointAddrJson) async {
    calls.add('dial $endpointAddrJson');
    if (dialFailure case final e?) throw e;
  }

  @override
  Future<P2pRangeStream> openRangeStream({
    required String peer,
    required String sessionId,
    required String path,
    int? rangeStart,
    int? rangeEnd,
    String? authToken,
  }) async {
    calls.add('open $peer');
    opens.add((
      peer: peer,
      sessionId: sessionId,
      path: path,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
    ));
    final a = answer;
    if (a is FakeRangeStream) {
      streams.add(a);
      return a;
    }
    throw a as Exception;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A range stream whose header carries [status].
FakeRangeStream fakeStatusStream(int status) => FakeRangeStream(
      header: fakeRangeHeader(status: status, contentLength: 1),
      totalBytes: 1,
    );
