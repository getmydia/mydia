import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/media_proxy.dart';
import 'package:player/core/p2p/p2p_range_stream.dart';
import 'package:player/core/p2p/peer_files_backend.dart';
import 'package:player/core/p2p/peer_files_transport.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';

import 'fake_range_stream.dart';

const _node = '0123456789abcdef0123456789abcdef';
const _target = 'peer_0123456789ab';

class _FakeProxy implements MediaProxy {
  final starts = <({String targetPeer, String target})>[];

  @override
  Future<void> start({
    required Object owner,
    required String targetPeer,
    String? authToken,
    required String target,
  }) async =>
      starts.add((targetPeer: targetPeer, target: target));

  @override
  String targetBaseUrl(String target) => 'http://127.0.0.1:4000/t/$target';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeTransport implements PeerFilesTransport {
  _FakeTransport(this.answer);

  /// What each open does: a stream to return, or an error to throw.
  Object answer;
  final opens = <({
    String peer,
    String sessionId,
    String path,
    int? rangeStart,
    int? rangeEnd
  })>[];
  final streams = <FakeRangeStream>[];

  @override
  Future<P2pRangeStream> openRangeStream({
    required String peer,
    required String sessionId,
    required String path,
    int? rangeStart,
    int? rangeEnd,
    String? authToken,
  }) async {
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

FakeRangeStream _status(int status) => FakeRangeStream(
      header: fakeRangeHeader(status: status, contentLength: 1),
      totalBytes: 1,
    );

void main() {
  const path = '/media/films/Amber Tide (2019).mkv';
  late _FakeProxy proxy;

  PeerFilesBackend backend(_FakeTransport transport, {bool connected = true}) =>
      PeerFilesBackend(
        nodeId: _node,
        hostAccountId: 'flocal',
        proxy: proxy,
        transport: transport,
        isConnected: (_) => connected,
      );

  setUp(() => proxy = _FakeProxy());

  test('playable_returns_proxy_url_after_2xx_probe', () async {
    final transport = _FakeTransport(_status(206));
    final file = await backend(transport).playable(path);

    final open = transport.opens.single;
    expect(open.peer, _node);
    expect(open.sessionId, 'peerfile:flocal');
    expect(utf8.decode(base64Url.decode(base64Url.normalize(open.path))), path);
    expect((open.rangeStart, open.rangeEnd), (0, 0));
    expect(transport.streams.single.isCancelled, isTrue);

    expect(proxy.starts.single, (targetPeer: _node, target: _target));
    expect(
        file.url,
        'http://127.0.0.1:4000/t/$_target/peerfile/flocal/'
        '${open.path}/stream');
  });

  test('probe_404_throws_not_found', () async {
    final transport = _FakeTransport(_status(404));
    await expectLater(
        backend(transport).playable(path), throwsA(isA<BackendNotFound>()));
    expect(transport.streams.single.isCancelled, isTrue);
  });

  test('probe_502_throws_unreachable', () async {
    await expectLater(
        backend(_FakeTransport(_status(502))).playable(path),
        throwsA(
            isA<BackendUnreachable>().having((e) => e.status, 'status', 502)));
  });

  test('open_failure_throws_unreachable', () async {
    await expectLater(
        backend(_FakeTransport(Exception('dial failed'))).playable(path),
        throwsA(isA<BackendUnreachable>()
            .having((e) => e.status, 'status', isNull)));
    expect(proxy.starts, isEmpty);
  });

  test('probe_403_throws_unauthorized', () async {
    await expectLater(backend(_FakeTransport(_status(403))).playable(path),
        throwsA(isA<BackendUnauthorized>()));
  });

  test('list_and_stat_throw', () async {
    final b = backend(_FakeTransport(_status(206)));
    await expectLater(b.list('/media'), throwsA(isA<BackendUnreachable>()));
    await expectLater(b.stat(path), throwsA(isA<BackendUnreachable>()));
  });

  test('probe follows whether the peer is connected', () async {
    await backend(_FakeTransport(_status(206))).probe();
    await expectLater(
        backend(_FakeTransport(_status(206)), connected: false).probe(),
        throwsA(isA<BackendUnreachable>()));
  });
}
