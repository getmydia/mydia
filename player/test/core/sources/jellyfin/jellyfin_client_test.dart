import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_storage.dart';
import 'package:player/core/sources/jellyfin/jellyfin_client.dart';
import 'package:player/core/sources/jellyfin/jellyfin_identity.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/domain/sources/source_error.dart';

import '../../../test_utils/mock_auth_storage.dart';
import '../fixed_connection.dart';
import 'fake_jellyfin_server.dart';

const identity = JellyfinIdentity(
    deviceId: 'dev1', version: '1.2.3', deviceName: 'Mydia Player on Linux');

({JellyfinClient client, FakeJellyfinServer server, List<int> unauthorized})
    buildClient({Uri? base}) {
  final server = FakeJellyfinServer();
  final unauthorized = <int>[];
  final client = JellyfinClient(
    connection: FixedConnection(base ?? FakeJellyfinServer.base),
    http: SourceHttp(client: server.client),
    identity: () async => identity,
    token: () async => FakeJellyfinServer.token,
    userId: FakeJellyfinServer.userId,
    onUnauthorized: () => unauthorized.add(1),
  );
  return (client: client, server: server, unauthorized: unauthorized);
}

void main() {
  test('the authorization header names the app, device and token', () {
    expect(
      identity.authorization('t1'),
      'MediaBrowser Client="Mydia Player", Device="Mydia Player on Linux", '
      'DeviceId="dev1", Version="1.2.3", Token="t1"',
    );
    expect(identity.authorization(), isNot(contains('Token=')));
  });

  test('quotes in the device name cannot break the header', () {
    const odd =
        JellyfinIdentity(deviceId: 'd', version: '1', deviceName: 'Den "TV"');
    expect(odd.authorization(), contains('Device="Den \'TV\'"'));
  });

  test('the device id is made once and kept', () async {
    final AuthStorage storage = MockAuthStorage();
    final first = await JellyfinIdentity.loadDeviceId(storage);
    expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(await JellyfinIdentity.loadDeviceId(storage), first);
  });

  test('keeps a reverse-proxy subpath and merges queries', () {
    expect(
      jellyfinUnder(Uri.parse('https://h.test/jf/'), '/Items?a=1', {'b': '2'})
          .toString(),
      'https://h.test/jf/Items?a=1&b=2',
    );
    expect(
        jellyfinUnder(Uri.parse('http://h.test:8096'), '/UserViews').toString(),
        'http://h.test:8096/UserViews');
  });

  test('sends the token as a header and never in the URL', () async {
    final b = buildClient();
    await b.client.get('/UserViews', {'userId': FakeJellyfinServer.userId});
    final request = b.server.requests.single;
    expect(request.headers['Authorization'],
        contains('Token="${FakeJellyfinServer.token}"'));
    expect(request.url.toString(), isNot(contains(FakeJellyfinServer.token)));
  });

  test('an empty 204 reads as an empty map', () async {
    final b = buildClient();
    expect(await b.client.post('/Sessions/Playing', body: {'ItemId': 'm1'}),
        isEmpty);
  });

  test('a 401 calls onUnauthorized and rethrows', () async {
    final b = buildClient();
    b.server.status = 401;
    await expectLater(
        b.client.get('/UserViews'), throwsA(isA<SourceException>()));
    expect(b.unauthorized, [1]);
  });

  test('an HTTP error is an answer, not an unreachable server', () async {
    final server = FakeJellyfinServer();
    final connection = FixedConnection(FakeJellyfinServer.base);
    final client = JellyfinClient(
      connection: connection,
      http: SourceHttp(client: server.client),
      identity: () async => identity,
      token: () async => FakeJellyfinServer.token,
      userId: FakeJellyfinServer.userId,
    );
    server.status = 599;
    await expectLater(
        client.get('/UserViews'), throwsA(isA<SourceException>()));
    expect(connection.failures, isEmpty,
        reason: 'an HTTP error is an answer, not an unreachable server');
  });

  group('public info', () {
    test('reads id, name, version and LAN address', () async {
      final server = FakeJellyfinServer();
      final info = await jellyfinPublicInfo(
          SourceHttp(client: server.client), FakeJellyfinServer.base);
      expect(info.id, FakeJellyfinServer.serverId);
      expect(info.name, 'Harbor');
      expect(info.isJellyfin, isTrue);
      expect(info.supported, isTrue);
      expect(info.localAddress, 'http://192.168.1.30:8096');
    });

    for (final (version, ok) in [
      ('10.9.0', true),
      ('10.10.3', true),
      ('11.0.0', true),
      ('10.8.13', false),
      ('garbage', false),
    ]) {
      test('version $version supported: $ok', () {
        final info = JellyfinServerInfo.fromJson({
          'Id': 'x',
          'ServerName': 'n',
          'Version': version,
          'ProductName': 'Jellyfin Server',
        });
        expect(info.supported, ok);
      });
    }

    test('the probe returns the server id and sends no token', () async {
      final server = FakeJellyfinServer();
      expect(
          await jellyfinIdentityProbe(SourceHttp(client: server.client),
              FakeJellyfinServer.base, const Duration(seconds: 3)),
          FakeJellyfinServer.serverId);
      expect(server.requests.single.headers['Authorization'], isNull);
    });
  });
}
