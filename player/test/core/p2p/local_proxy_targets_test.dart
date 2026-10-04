import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/core/p2p/media_proxy.dart';
import 'package:player/core/p2p/media_route.dart';

import 'test_p2p_service.dart';

void main() {
  late TestP2pService p2p;
  late LocalProxyService proxy;
  final playback = Object();
  final download = Object();

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

  test('home URLs carry no target prefix', () async {
    await proxy.start(owner: download, targetPeer: 'home-peer');

    expect(proxy.targetBaseUrl(MediaProxy.homeTarget), proxy.baseUrl);
    expect(proxy.buildHlsUrl('s1'), '${proxy.baseUrl}/hls/s1/index.m3u8');
  });

  test('each target reaches its own peer with its own token', () async {
    await proxy.start(
        owner: download, targetPeer: 'home-peer', authToken: 'home-tok');
    await proxy.start(
        owner: playback,
        targetPeer: 'guest-peer',
        authToken: 'guest-tok',
        target: 'mguest');

    expect(await get(MediaRoutes.hls(proxy.targetBaseUrl('mguest'), 's2')),
        HttpStatus.ok);
    expect(await get(proxy.buildHlsUrl('s1')), HttpStatus.ok);

    expect(p2p.calls.map((c) => (c.peer, c.authToken, c.sessionId)), [
      ('guest-peer', 'guest-tok', 's2'),
      ('home-peer', 'home-tok', 's1'),
    ]);
  });

  test('starting a guest target does not re-target home', () async {
    await proxy.start(owner: download, targetPeer: 'home-peer');
    await proxy.start(
        owner: playback, targetPeer: 'guest-peer', target: 'mguest');

    await get(proxy.buildHlsUrl('s1'));

    expect(p2p.calls.single.peer, 'home-peer');
  });

  test('stopping one target leaves the other serving', () async {
    await proxy.start(owner: download, targetPeer: 'home-peer');
    await proxy.start(
        owner: playback, targetPeer: 'guest-peer', target: 'mguest');

    await proxy.stop(playback, target: 'mguest');

    expect(proxy.isRunning, isTrue);
    expect(await get(proxy.buildHlsUrl('s1')), HttpStatus.ok);
    expect(await get(MediaRoutes.hls('${proxy.baseUrl}/t/mguest', 's2')),
        HttpStatus.serviceUnavailable);
  });

  test('the server stops when the last target is released', () async {
    await proxy.start(owner: download, targetPeer: 'home-peer');
    await proxy.start(
        owner: playback, targetPeer: 'guest-peer', target: 'mguest');

    await proxy.stop(download);
    expect(proxy.isRunning, isTrue);
    await proxy.stop(playback, target: 'mguest');
    expect(proxy.isRunning, isFalse);
  });

  test('a stop for a target the owner never held is a no-op', () async {
    await proxy.start(owner: download, targetPeer: 'home-peer');

    await proxy.stop(download, target: 'mguest');

    expect(proxy.isRunning, isTrue);
    expect(await get(proxy.buildHlsUrl('s1')), HttpStatus.ok);
  });

  test('an unknown target answers 503', () async {
    await proxy.start(owner: download, targetPeer: 'home-peer');

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
    await proxy.start(owner: download, targetPeer: 'home-peer');
    await proxy.start(
        owner: playback, targetPeer: 'guest-peer', target: 'mguest');

    await proxy.setLanAccess(true);
    if (!proxy.isLanAccessible) return; // no LAN interface on this machine

    final url = MediaRoutes.hls(proxy.targetBaseUrl('mguest'), 's2');
    expect(url, contains('/g/'));
    expect(url, contains('/t/mguest/hls/'));
    expect(await get(url), HttpStatus.ok);
    expect(p2p.calls.single.peer, 'guest-peer');
  });
}
