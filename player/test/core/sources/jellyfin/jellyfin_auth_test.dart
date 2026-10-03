import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/jellyfin/jellyfin_auth.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/domain/sources/source_error.dart';

import 'fake_jellyfin_server.dart';
import 'jellyfin_client_test.dart' show identity;

void main() {
  late FakeJellyfinServer server;
  late JellyfinAuth auth;

  setUp(() {
    server = FakeJellyfinServer();
    auth = JellyfinAuth(
      http: SourceHttp(client: server.client),
      base: FakeJellyfinServer.base,
      identity: identity,
    );
  });

  test('password sign-in returns token and user', () async {
    final s = await auth.withPassword(
        FakeJellyfinServer.username, FakeJellyfinServer.password);
    expect(s.accessToken, FakeJellyfinServer.token);
    expect(s.userId, FakeJellyfinServer.userId);
    expect(s.userName, FakeJellyfinServer.username);
    expect(s.isAdmin, isTrue);
    final header = server.requests.last.headers['Authorization']!;
    expect(header, startsWith('MediaBrowser Client="Mydia Player"'));
    expect(header, isNot(contains('Token=')));
  });

  test('a wrong password is unauthorized', () async {
    await expectLater(
      auth.withPassword(FakeJellyfinServer.username, 'nope'),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.unauthorized)),
    );
  });

  test('Quick Connect: enabled, code, approval, token', () async {
    expect(await auth.quickConnectEnabled(), isTrue);
    final code = await auth.initiateQuickConnect();
    expect(code.code, '482913');
    expect(await auth.quickConnectApproved(code.secret), isFalse);
    server.quickConnectApproved = true;
    expect(await auth.quickConnectApproved(code.secret), isTrue);
    final s = await auth.withQuickConnect(code.secret);
    expect(s.accessToken, FakeJellyfinServer.token);
  });

  test('an expired code reads as notFound', () async {
    server.quickConnectExpired = true;
    await expectLater(
      auth.quickConnectApproved('qc-secret'),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.notFound)),
    );
  });

  test('Quick Connect disabled, or the check failing, reads as off', () async {
    server.quickConnectEnabled = false;
    expect(await auth.quickConnectEnabled(), isFalse);
    server.status = 500;
    expect(await auth.quickConnectEnabled(), isFalse);
  });
}
