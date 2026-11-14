import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_files_backend.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';

import 'fake_peer_files.dart';

const _node = '0123456789abcdef0123456789abcdef';
const _target = 'peer_0123456789ab';

void main() {
  const path = '/media/films/Amber Tide (2019).mkv';
  late FakePeerProxy proxy;

  PeerFilesBackend backend(FakePeerRangeTransport transport,
          {bool connected = true, String nodeId = _node}) =>
      PeerFilesBackend(
        nodeId: nodeId,
        hostAccountId: 'flocal',
        proxy: proxy,
        transport: transport,
        isConnected: (_) => connected,
      );

  FakePeerRangeTransport answering(int status) =>
      FakePeerRangeTransport(fakeStatusStream(status));

  setUp(() => proxy = FakePeerProxy());
  tearDown(() => PeerFilesBackend.releaseHost(_node, () => proxy));

  test('playable_returns_proxy_url_after_2xx_probe', () async {
    final transport = answering(206);
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
    final transport = answering(404);
    await expectLater(
        backend(transport).playable(path), throwsA(isA<BackendNotFound>()));
    expect(transport.streams.single.isCancelled, isTrue);
  });

  test('probe_502_throws_unreachable', () async {
    await expectLater(
        backend(answering(502)).playable(path),
        throwsA(
            isA<BackendUnreachable>().having((e) => e.status, 'status', 502)));
  });

  test('open_failure_throws_unreachable', () async {
    await expectLater(
        backend(FakePeerRangeTransport(Exception('dial failed')))
            .playable(path),
        throwsA(isA<BackendUnreachable>()
            .having((e) => e.status, 'status', isNull)));
    expect(proxy.starts, isEmpty);
  });

  test('probe_403_throws_unauthorized', () async {
    await expectLater(backend(answering(403)).playable(path),
        throwsA(isA<BackendUnauthorized>()));
  });

  test('list_and_stat_throw', () async {
    final b = backend(answering(206));
    await expectLater(b.list('/media'), throwsA(isA<BackendUnreachable>()));
    await expectLater(b.stat(path), throwsA(isA<BackendUnreachable>()));
  });

  test('probe follows whether the peer is connected', () async {
    await backend(answering(206)).probe();
    await expectLater(backend(answering(206), connected: false).probe(),
        throwsA(isA<BackendUnreachable>()));
  });

  test('a missing node id fails before dialing or starting the proxy',
      () async {
    final transport = answering(206);
    final b = backend(transport, nodeId: '');
    await expectLater(b.playable(path), throwsA(isA<BackendUnreachable>()));
    await expectLater(b.probe(), throwsA(isA<BackendUnreachable>()));
    expect(transport.opens, isEmpty);
    expect(proxy.starts, isEmpty);
  });

  test('every account of a host shares one held target, released once',
      () async {
    await backend(answering(206)).playable(path);
    await PeerFilesBackend(
      nodeId: _node,
      hostAccountId: 'wshare',
      proxy: proxy,
      transport: answering(206),
      isConnected: (_) => true,
    ).playable(path);
    expect(proxy.holders[_target], hasLength(1));

    await PeerFilesBackend.releaseHost(_node, () => proxy);
    expect(proxy.stops, [_target]);
    expect(proxy.holders[_target], isEmpty);

    // Nothing held: a second release reads no proxy.
    await PeerFilesBackend.releaseHost(_node, () => throw StateError('read'));
    expect(proxy.stops, [_target]);
  });
}
