import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_providers.dart';

void main() {
  test('a_refused_call_rereads_the_credentials', () async {
    String basic(String user, String pass) =>
        'Basic ${base64.encode(utf8.encode('$user:$pass'))}';
    final seen = <String?>[];
    final client = MockClient((request) async {
      final auth = request.headers['Authorization'];
      seen.add(auth);
      if (auth != basic('quill', 'new')) return http.Response('', 401);
      return http.Response(
          '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>', 207);
    });
    var stored = const WebDavCredentials(user: 'quill', password: 'old');
    var reads = 0;
    final backend = LazyWebDavBackend(
      base: Uri.parse('https://nas.example.test/media'),
      credentials: () async {
        reads++;
        return stored.toJson();
      },
      client: client,
    );

    await expectLater(backend.probe(), throwsA(isA<BackendUnauthorized>()));
    stored = const WebDavCredentials(user: 'quill', password: 'new');
    await backend.probe();
    expect(reads, 2);
    expect(seen, [basic('quill', 'old'), basic('quill', 'new')]);

    // A good backend is kept.
    await backend.probe();
    expect(reads, 2);
  });

  test('close_closes_the_client_it_made_and_not_a_given_one', () {
    Future<String?> creds() async =>
        const WebDavCredentials(user: 'u', password: 'p').toJson();
    final made = _TrackedClient();
    LazyWebDavBackend(
      base: Uri.parse('https://nas.example.test/media'),
      credentials: creds,
      newClient: () => made,
    ).close();
    expect(made.closed, isTrue);

    final given = _TrackedClient();
    LazyWebDavBackend(
      base: Uri.parse('https://nas.example.test/media'),
      credentials: creds,
      client: given,
    ).close();
    expect(given.closed, isFalse);
  });

  test('unreadable_credentials_are_refused', () async {
    final backend = LazyWebDavBackend(
      base: Uri.parse('https://nas.example.test'),
      credentials: () async => 'not json',
      client: _TrackedClient(),
    );
    await expectLater(backend.probe(), throwsA(isA<BackendUnauthorized>()));
  });

  test('missing_credentials_are_refused_and_not_cached', () async {
    String? stored;
    final backend = LazyWebDavBackend(
      base: Uri.parse('https://nas.example.test'),
      credentials: () async => stored,
      client: MockClient((_) async => http.Response(
          '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>', 207)),
    );
    await expectLater(backend.probe(), throwsA(isA<BackendUnauthorized>()));
    stored = const WebDavCredentials(user: 'u', password: 'p').toJson();
    await backend.probe();
  });
}

/// Records [close]; answers nothing a test reaches.
class _TrackedClient extends MockClient {
  _TrackedClient() : super((_) async => http.Response('', 500));

  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}
