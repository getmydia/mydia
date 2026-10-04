import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/sources/plex/plex_identity.dart';
import 'package:player/core/sources/plex/plex_tv_client.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/domain/sources/source_error.dart';

import 'plex_home_fixtures.dart';

const identity =
    PlexIdentity(clientIdentifier: 'cid', version: '1', platform: 'Linux');

const resourcesJson = '''
[
  {"name": "Attic", "product": "Plex Media Server", "provides": "server",
   "clientIdentifier": "aa11", "owned": true, "presence": true,
   "accessToken": "server-token-1", "httpsRequired": false,
   "connections": [
     {"protocol": "https", "uri": "https://10-0-0-5.aa11.plex.direct:32400", "local": true, "relay": false},
     {"protocol": "http", "uri": "http://10.0.0.5:32400", "local": true, "relay": false},
     {"protocol": "https", "uri": "https://relay-1.aa11.plex.direct:8443", "local": false, "relay": true}
   ]},
  {"name": "Cousin's Box", "provides": "server", "clientIdentifier": "bb22",
   "owned": false, "presence": false, "accessToken": "server-token-2",
   "httpsRequired": true, "connections": []},
  {"name": "Living Room TV", "provides": "client,player",
   "clientIdentifier": "cc33", "owned": true, "presence": true,
   "accessToken": "x", "connections": []},
  {"name": "Odd", "provides": "server", "clientIdentifier": "has:colon",
   "owned": true, "presence": true, "accessToken": "y", "connections": []}
]
''';

void main() {
  late List<http.Request> requests;

  PlexTvClient client(Map<String, http.Response Function()> routes) {
    requests = [];
    return PlexTvClient(
      identity: identity,
      http: SourceHttp(client: MockClient((request) async {
        requests.add(request);
        final route = routes['${request.method} ${request.url.path}'];
        return route == null ? http.Response('', 404) : route();
      })),
    );
  }

  test('creates a PIN with the identity headers', () async {
    final tv = client({
      'POST /api/v2/pins': () =>
          http.Response(jsonEncode({'id': 7, 'code': 'QZ4K'}), 201),
    });
    final pin = await tv.createPin();
    expect(pin.id, 7);
    expect(pin.code, 'QZ4K');
    expect(requests.single.headers['X-Plex-Client-Identifier'], 'cid');
    expect(requests.single.url.queryParameters.containsKey('strong'), isFalse,
        reason: 'plex.tv/link only accepts the short code');
  });

  test('a PIN without a token yet answers null', () async {
    final tv = client({
      'GET /api/v2/pins/7': () =>
          http.Response(jsonEncode({'id': 7, 'authToken': null}), 200),
    });
    expect(await tv.checkPin(7), isNull);
  });

  test('a claimed PIN answers its token', () async {
    final tv = client({
      'GET /api/v2/pins/7': () =>
          http.Response(jsonEncode({'id': 7, 'authToken': 'acct'}), 200),
    });
    expect(await tv.checkPin(7), 'acct');
  });

  test('reads the user with the token in a header', () async {
    final tv = client({
      'GET /api/v2/user': () => http.Response(
          jsonEncode({'uuid': 'u1', 'username': 'quill', 'title': 'Quill'}),
          200),
    });
    final user = await tv.user('acct');
    expect(user.username, 'quill');
    expect(requests.single.headers['X-Plex-Token'], 'acct');
    expect(requests.single.url.query, isNot(contains('acct')));
  });

  test('keeps servers with valid ids and parses connections', () async {
    final tv = client({
      'GET /api/v2/resources': () => http.Response(resourcesJson, 200),
    });
    final servers = await tv.servers('acct');
    expect([for (final s in servers) s.clientIdentifier], ['aa11', 'bb22']);
    final attic = servers.first;
    expect(attic.owned, isTrue);
    expect(attic.connections, hasLength(3));
    expect(attic.connections.last.relay, isTrue);
    expect(servers.last.presence, isFalse);
    expect(servers.last.httpsRequired, isTrue);
    expect(requests.single.url.queryParameters['includeRelay'], '1');

    final server = attic.toServer(accountId: 'acc1', profileId: 'owner');
    expect(server.id, 'aa11');
    expect(server.machineIdentifier, 'aa11');
    expect(server.name, 'Attic');
  });

  test('reconcile updates known servers and marks missing ones gone', () {
    final stored = [
      const SourceServer(
          id: 'aa11', accountId: 'acc1', profileId: 'owner', name: 'Old name'),
      const SourceServer(
          id: 'zz99', accountId: 'acc1', profileId: 'owner', name: 'Sold'),
    ];
    final resources = [
      PlexResource(
        name: 'Attic',
        clientIdentifier: 'aa11',
        owned: true,
        presence: false,
        accessToken: 't',
        httpsRequired: false,
        connections: [
          ServerConnection(uri: Uri.parse('https://a.plex.direct:32400')),
        ],
      ),
      const PlexResource(
        name: 'New',
        clientIdentifier: 'nn55',
        owned: true,
        presence: true,
        accessToken: 't',
        httpsRequired: false,
        connections: [],
      ),
    ];
    final result = reconcilePlexServers(stored, resources);
    expect(result, hasLength(2), reason: 'new servers are offered, not added');
    expect(result.first.name, 'Attic');
    expect(result.first.presence, isFalse);
    expect(result.first.connections, hasLength(1));
    expect(result.last.gone, isTrue);
  });

  group('Plex Home', () {
    test('lists home users with the admin as owner and odd ids skipped',
        () async {
      final tv = client({
        'GET /api/v2/home/users': () => http.Response(homeUsersJson, 200),
      });
      final users = await tv.homeUsers('acct');
      expect([for (final u in users) u.title], ['Quill', 'Pip', 'Wren']);
      expect(users.first.profileId, 'owner');
      expect(users[1].profileId, 'kid0001');
      expect(users[1].protected, isTrue);
      expect(requests.single.headers['X-Plex-Token'], 'acct');

      final profile = users[1].toProfile('acc1');
      expect(profile.id, 'kid0001');
      expect(profile.accountId, 'acc1');
      expect(profile.isOwner, isFalse);
      expect(profile.protected, isTrue);
    });

    test('reads a bare list too', () async {
      final users =
          (jsonDecode(homeUsersJson) as Map<String, dynamic>)['users'];
      final tv = client({
        'GET /api/v2/home/users': () => http.Response(jsonEncode(users), 200),
      });
      expect(await tv.homeUsers('acct'), hasLength(3));
    });

    test('an account with no Home has no home users', () async {
      final tv = client({});
      expect(await tv.homeUsers('acct'), isEmpty);
    });

    test('switching answers the user token, PIN in the query only', () async {
      final tv = client({
        'POST /api/v2/home/users/kid0001/switch': () =>
            http.Response(kidSwitchJson, 201),
      });
      expect(await tv.switchUser('acct', 'kid0001', pin: '1234'), 'kid-token');
      final request = requests.single;
      expect(request.url.queryParameters['pin'], '1234');
      expect(request.url.query, isNot(contains('acct')));
      expect(request.headers['X-Plex-Token'], 'acct');
    });

    test('a refused PIN is wrongPin', () async {
      final tv = client({
        'POST /api/v2/home/users/kid0001/switch': () =>
            http.Response(wrongPinJson, 401),
      });
      expect(
        () => tv.switchUser('acct', 'kid0001', pin: '0000'),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.wrongPin)),
      );
    });

    test('a refusal without a PIN stays unauthorized', () async {
      final tv = client({
        'POST /api/v2/home/users/guest02/switch': () => http.Response('', 401),
      });
      expect(
        () => tv.switchUser('acct', 'guest02'),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.unauthorized)),
      );
    });

    test('a switch reply without a token is a server error', () async {
      final tv = client({
        'POST /api/v2/home/users/guest02/switch': () =>
            http.Response('{"id": 13}', 201),
      });
      expect(
        () => tv.switchUser('acct', 'guest02'),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.server)),
      );
    });
  });
}
