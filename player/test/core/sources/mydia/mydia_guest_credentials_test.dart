import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';

void main() {
  const p2p = MydiaCredentials(
    instanceId: 'inst-2',
    instanceName: 'Lakeside',
    accessToken: 'access',
    mediaToken: 'media',
    deviceToken: 'device',
    nodeAddr: '{"id":"node-xyz","addrs":[]}',
  );

  test('round-trips through JSON', () {
    expect(MydiaCredentials.fromJson(p2p.toJson()), p2p);
  });

  test('round-trips through JSON with mediaTokenExpiry', () {
    final expiry = DateTime.parse('2026-10-06T12:00:00.000Z');
    final creds = p2p.copyWith(mediaTokenExpiry: expiry);
    expect(MydiaCredentials.fromJson(creds.toJson()), creds);
  });

  test('a p2p guest exposes its node id', () {
    expect(p2p.isP2p, isTrue);
    expect(p2p.nodeId, 'node-xyz');
  });

  test('a URL guest is not p2p', () {
    const direct = MydiaCredentials(
        instanceId: 'u1', accessToken: 'a', serverUrl: 'https://m.example');
    expect(direct.isP2p, isFalse);
    expect(direct.nodeId, isNull);
  });

  test('copyWith replaces tokens only', () {
    final next = p2p.copyWith(accessToken: 'fresh');
    expect(next.accessToken, 'fresh');
    expect(next.deviceToken, 'device');
    expect(next.instanceId, 'inst-2');
  });

  test('normalizeMydiaUrl drops a trailing slash and lowercases the host', () {
    expect(normalizeMydiaUrl('https://Media.Example:8443/'),
        'https://media.example:8443');
    expect(normalizeMydiaUrl('http://10.0.0.5:4000'), 'http://10.0.0.5:4000');
  });

  test('urlInstanceId is stable, prefixed and a valid id component', () {
    final a = urlInstanceId('https://media.example/');
    expect(a, urlInstanceId('https://MEDIA.example'));
    expect(a, startsWith('u'));
    expect(a, hasLength(17));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(a), isTrue);
  });

  test('nodeInstanceId prefixes the node id', () {
    expect(nodeInstanceId('node-xyz'), 'nnode-xyz');
  });
}
