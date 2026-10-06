import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/core/p2p/media_route.dart';

import 'test_p2p_service.dart';

void main() {
  late TestP2pService p2p;
  late LocalProxyService proxy;
  final playback = Object();
  final download = Object();

  // Two instances' account ids.
  const a = 'macct-a';
  const b = 'macct-b';

  setUp(() {
    p2p = TestP2pService()
      ..onSendHlsRequest = (_) async => testHlsResponse(
            status: HttpStatus.ok,
            contentType: 'application/vnd.apple.mpegurl',
            data: utf8.encode('#EXTM3U\n'),
          );
    proxy = LocalProxyService(p2p);
  });

  tearDown(() => proxy.shutdown());

  Future<int> get(String url) async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  test('every URL carries its target prefix', () async {
    await proxy.start(owner: download, targetPeer: 'peer-a', target: a);

    expect(proxy.targetBaseUrl(a), '${proxy.baseUrl}/t/$a');
    expect(proxy.buildHlsUrl('s1', target: a),
        '${proxy.baseUrl}/t/$a/hls/s1/index.m3u8');
  });

  test('a path without a target prefix is not served', () async {
    await proxy.start(owner: download, targetPeer: 'peer-a', target: a);

    expect(
        await get('${proxy.baseUrl}/hls/s1/index.m3u8'), HttpStatus.notFound);
    expect(await get('${proxy.baseUrl}/t/$a'), HttpStatus.notFound);
    expect(p2p.calls, isEmpty);
  });

  test('each target reaches its own peer with its own token', () async {
    await proxy.start(
        owner: download, targetPeer: 'peer-a', authToken: 'tok-a', target: a);
    await proxy.start(
        owner: playback, targetPeer: 'peer-b', authToken: 'tok-b', target: b);

    expect(await get(MediaRoutes.hls(proxy.targetBaseUrl(b), 's2')),
        HttpStatus.ok);
    expect(await get(proxy.buildHlsUrl('s1', target: a)), HttpStatus.ok);

    expect(p2p.calls.map((c) => (c.peer, c.authToken, c.sessionId)), [
      ('peer-b', 'tok-b', 's2'),
      ('peer-a', 'tok-a', 's1'),
    ]);
  });

  test('starting one target does not re-target another', () async {
    await proxy.start(owner: download, targetPeer: 'peer-a', target: a);
    await proxy.start(owner: playback, targetPeer: 'peer-b', target: b);

    await get(proxy.buildHlsUrl('s1', target: a));

    expect(p2p.calls.single.peer, 'peer-a');
  });

  test('stopping one target leaves the other serving', () async {
    await proxy.start(owner: download, targetPeer: 'peer-a', target: a);
    await proxy.start(owner: playback, targetPeer: 'peer-b', target: b);

    await proxy.stop(playback, target: b);

    expect(proxy.isRunning, isTrue);
    expect(await get(proxy.buildHlsUrl('s1', target: a)), HttpStatus.ok);
    expect(await get(MediaRoutes.hls('${proxy.baseUrl}/t/$b', 's2')),
        HttpStatus.serviceUnavailable);
  });

  test('the server stops when the last target is released', () async {
    await proxy.start(owner: download, targetPeer: 'peer-a', target: a);
    await proxy.start(owner: playback, targetPeer: 'peer-b', target: b);

    await proxy.stop(download, target: a);
    expect(proxy.isRunning, isTrue);
    await proxy.stop(playback, target: b);
    expect(proxy.isRunning, isFalse);
  });

  test('release lets go of every target the owner holds', () async {
    await proxy.start(owner: playback, targetPeer: 'peer-a', target: a);
    await proxy.start(owner: playback, targetPeer: 'peer-b', target: b);

    await proxy.release(playback);

    expect(proxy.isRunning, isFalse);
  });

  test('two targets, one release frees both', () async {
    const owner = Object();
    await proxy.start(owner: owner, targetPeer: 'a', target: a);
    await proxy.start(owner: owner, targetPeer: 'b', target: b);
    expect(proxy.targetBaseUrl(a), endsWith('/t/$a'));

    await proxy.release(owner);

    expect(proxy.isRunning, isFalse);
  });

  test('release keeps serving a target another owner still holds', () async {
    await proxy.start(owner: playback, targetPeer: 'peer-a', target: a);
    await proxy.start(owner: playback, targetPeer: 'peer-b', target: b);
    await proxy.start(owner: download, targetPeer: 'peer-a', target: a);

    await proxy.release(playback);

    expect(proxy.isRunning, isTrue);
    expect(await get(proxy.buildHlsUrl('s1', target: a)), HttpStatus.ok);
    expect(await get(MediaRoutes.hls('${proxy.baseUrl}/t/$b', 's2')),
        HttpStatus.serviceUnavailable);
  });

  test('release from an owner that holds nothing is a no-op', () async {
    await proxy.start(owner: download, targetPeer: 'peer-a', target: a);

    await proxy.release(playback);

    expect(proxy.isRunning, isTrue);
  });

  test('a stop for a target the owner never held is a no-op', () async {
    await proxy.start(owner: download, targetPeer: 'peer-a', target: a);

    await proxy.stop(download, target: b);

    expect(proxy.isRunning, isTrue);
    expect(await get(proxy.buildHlsUrl('s1', target: a)), HttpStatus.ok);
  });

  test('an unknown target answers 503', () async {
    await proxy.start(owner: download, targetPeer: 'peer-a', target: a);

    expect(await get(MediaRoutes.hls('${proxy.baseUrl}/t/nobody', 's1')),
        HttpStatus.serviceUnavailable);
    expect(p2p.calls, isEmpty);
  });

  test('refuses a target key that cannot be a path segment', () async {
    expect(
      () => proxy.start(owner: playback, targetPeer: 'p', target: 'a/b'),
      throwsArgumentError,
    );
  });

  test('targets survive a LAN rebind, under the LAN prefix', () async {
    await proxy.start(owner: download, targetPeer: 'peer-a', target: a);
    await proxy.start(owner: playback, targetPeer: 'peer-b', target: b);

    await proxy.setLanAccess(true);
    if (!proxy.isLanAccessible) return; // no LAN interface on this machine

    final url = MediaRoutes.hls(proxy.targetBaseUrl(b), 's2');
    expect(url, contains('/g/'));
    expect(url, contains('/t/$b/hls/'));
    expect(await get(url), HttpStatus.ok);
    expect(p2p.calls.single.peer, 'peer-b');
  });

  test('a joiner keeps the target alive after its starter stops', () async {
    await proxy.start(
        owner: playback, targetPeer: 'peer-a', authToken: 'tok-a', target: a);

    expect(proxy.joinTarget(download, target: a), isTrue);
    await proxy.stop(playback, target: a);

    expect(proxy.isRunning, isTrue);
    expect(await get(proxy.buildHlsUrl('s1', target: a)), HttpStatus.ok);
    expect(p2p.calls.single.peer, 'peer-a');
    expect(p2p.calls.single.authToken, 'tok-a');

    await proxy.stop(download, target: a);
    expect(proxy.isRunning, isFalse);
  });

  test('joinTarget refuses a target that is not served, and holds nothing',
      () async {
    expect(proxy.joinTarget(download, target: a), isFalse);
    expect(proxy.hasOwners, isFalse);

    await proxy.start(owner: playback, targetPeer: 'peer-b', target: b);
    expect(proxy.joinTarget(download, target: a), isFalse);

    await proxy.stop(playback, target: b);
    expect(proxy.isRunning, isFalse,
        reason: 'a refused join must not leave a lease behind');
  });

  test('one owner holding two targets releases them independently', () async {
    await proxy.start(owner: playback, targetPeer: 'peer-a', target: a);
    await proxy.start(owner: playback, targetPeer: 'peer-b', target: b);

    await proxy.stop(playback, target: b);
    expect(proxy.isRunning, isTrue);
    expect(await get(proxy.buildHlsUrl('s1', target: a)), HttpStatus.ok);

    await proxy.stop(playback, target: a);
    expect(proxy.isRunning, isFalse);
  });

  test('joinTarget waits for the bind rather than claiming a port-0 proxy',
      () async {
    final starting =
        proxy.start(owner: playback, targetPeer: 'peer-a', target: a);

    expect(proxy.joinTarget(download, target: a), isFalse);
    expect(proxy.isRunning, isFalse);
    expect(proxy.port, 0);

    await starting;
    expect(proxy.joinTarget(download, target: a), isTrue);

    await proxy.stop(playback, target: a);
    expect(proxy.isRunning, isTrue);
    await proxy.stop(download, target: a);
    expect(proxy.isRunning, isFalse);
  });

  test('concurrent starts for one target share a single bound server',
      () async {
    await Future.wait([
      proxy.start(owner: playback, targetPeer: 'peer-a', target: a),
      proxy.start(owner: download, targetPeer: 'peer-a', target: a),
    ]);
    final port = proxy.port;
    expect(port, isNot(0));

    await proxy.stop(playback, target: a);
    expect(proxy.isRunning, isTrue);
    expect(proxy.port, port);
    expect(await get(proxy.buildHlsUrl('s1', target: a)), HttpStatus.ok);

    await proxy.stop(download, target: a);
    expect(proxy.isRunning, isFalse);
  });
}
