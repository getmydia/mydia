import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/auth/device_info_service.dart';

import '../../test_utils/mock_auth_storage.dart';
import '../../test_utils/stub_graphql_client.dart';

class _FakeDeviceInfo extends DeviceInfoService {
  @override
  Future<String> getDeviceId() async => 'device-1';
  @override
  Future<String> getDeviceName() async => 'Test Device';
  @override
  String getPlatform() => 'linux';
}

Map<String, dynamic> _login({
  String? token = 'tok',
  bool totp = false,
}) =>
    {
      '__typename': 'RootMutationType',
      'login': {
        '__typename': 'LoginPayload',
        'token': token,
        'user': {
          '__typename': 'User',
          'id': 'u1',
          'username': 'maya',
          'email': null,
          'displayName': null,
        },
        'expiresIn': 100,
        'totpRequired': totp,
        'challengeToken': totp ? 'challenge' : null,
      },
    };

void main() {
  late MockAuthStorage storage;
  late StubLink link;

  AuthService serviceFor(Object response) {
    link = StubLink.responses([response]);
    return AuthService(
      storage: storage,
      deviceInfo: _FakeDeviceInfo(),
      clientFactory: (_) => stubClient(link),
    );
  }

  setUp(() => storage = MockAuthStorage());

  test('requestLogin returns the grant and stores nothing', () async {
    final outcome = await serviceFor(_login()).requestLogin(
      serverUrl: 'https://friend.example/',
      username: 'maya',
      password: 'pw',
    );
    expect(outcome, isA<LoginGranted>());
    final g = outcome as LoginGranted;
    expect(g.token, 'tok');
    expect(g.userId, 'u1');
    expect(g.username, 'maya');
    expect(g.serverUrl, 'https://friend.example');
    expect(await storage.read('auth_token'), isNull);
    expect(storage.keys, isEmpty);
  });

  test('requestLogin returns a TOTP challenge', () async {
    final outcome = await serviceFor(_login(token: null, totp: true))
        .requestLogin(
            serverUrl: 'https://a.example', username: 'm', password: 'p');
    expect(outcome, isA<TotpChallenge>());
  });

  test('requestTotp returns the grant and stores nothing', () async {
    final service = serviceFor({
      '__typename': 'RootMutationType',
      'verifyTotp': {
        '__typename': 'LoginPayload',
        'token': 'tok2',
        'user': {
          '__typename': 'User',
          'id': 'u1',
          'username': 'maya',
          'email': null,
          'displayName': null,
        },
        'expiresIn': 100,
        'totpRequired': false,
      },
    });
    final g = await service.requestTotp(
      challenge: const TotpChallenge(
        serverUrl: 'https://a.example',
        challengeToken: 'challenge',
        username: 'm',
      ),
      code: '123456',
    );
    expect(g.token, 'tok2');
    expect(storage.keys, isEmpty);
  });

  test('loginWithGraphQL still stores the session', () async {
    final outcome = await serviceFor(_login()).loginWithGraphQL(
      serverUrl: 'https://home.example',
      username: 'maya',
      password: 'pw',
    );
    expect(outcome, isA<LoginSuccess>());
    expect(await storage.read('auth_token'), 'tok');
    expect(await storage.read('server_url'), 'https://home.example');
  });
}
