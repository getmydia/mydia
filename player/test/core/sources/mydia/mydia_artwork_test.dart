import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/core/p2p/media_route.dart';
import 'package:player/core/sources/mydia/mydia_client.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/domain/sources/item.dart';

import 'fake_mydia_transport.dart';
import 'mydia_source_test.dart' show guest;

const _http = MydiaCredentials(
  instanceId: 'i',
  accessToken: 'a',
  serverUrl: 'https://media.example//',
);
const _p2p = MydiaCredentials(
  instanceId: 'i',
  accessToken: 'a',
  nodeAddr: '{"id":"abc"}',
);
const _hosted = ArtworkRef('/generated/posters/abc-0123abcd.png');

void main() {
  late LocalProxyService proxy;

  setUp(() => proxy = LocalProxyService.forTesting());
  tearDown(() => proxy.shutdown());

  MydiaSource source(MydiaCredentials creds) => MydiaSource(
        source: guest,
        client: MydiaClient(
          transport: FakeMydiaTransport(),
          load: () async => creds,
          save: (_) async {},
          onUnauthorized: () {},
        ),
        proxy: () => proxy,
      );

  test('over HTTP a hosted poster is the server URL plus its path, no header',
      () async {
    final req = await source(_http).artwork(_hosted, width: 300);
    expect(
        req!.url, 'https://media.example/generated/posters/abc-0123abcd.png');
    expect(req.headers, isEmpty);
    expect(req.cacheKey, contains('/generated/posters/abc-0123abcd.png|300'));
  });

  test('over p2p a hosted poster goes through the proxy artwork route',
      () async {
    final req = await source(_p2p).artwork(_hosted, width: 300);
    expect(req!.url,
        MediaRoutes.artwork(proxy.targetBaseUrl('mguest'), 'abc-0123abcd.png'));
    expect(req.headers, isEmpty);
    expect(proxy.isRunning, isTrue);
  });

  test('disposing releases the hold a p2p poster took', () async {
    final s = source(_p2p);
    await s.artwork(_hosted, width: 300);
    expect(proxy.isRunning, isTrue);
    s.dispose();
    await pumpEventQueue();
    expect(proxy.isRunning, isFalse);
  });

  test('disposing while credentials load takes no proxy hold', () async {
    final creds = Completer<MydiaCredentials>();
    final s = MydiaSource(
      source: guest,
      client: MydiaClient(
        transport: FakeMydiaTransport(),
        load: () => creds.future,
        save: (_) async {},
        onUnauthorized: () {},
      ),
      proxy: () => proxy,
    );

    final pending = s.artwork(_hosted, width: 300);
    await pumpEventQueue();
    s.dispose();
    creds.complete(_p2p);

    expect(await pending, isNull);
    await pumpEventQueue();
    expect(proxy.isRunning, isFalse);
  });

  test('other relative paths are still refused', () async {
    for (final path in const [
      '/relative.jpg',
      '/generated/avatars/a.png',
      '/generated/posters/',
      '/generated/posters/a/b.png',
      '/generated/posters/..',
      '/generated/posters/x?y.png',
      '/generated/posters/abc-0123abcd.gif',
      '/generated/posters/abc-0123abcd.png\n',
    ]) {
      expect(await source(_http).artwork(ArtworkRef(path), width: 300), isNull,
          reason: path);
    }
  });
}
