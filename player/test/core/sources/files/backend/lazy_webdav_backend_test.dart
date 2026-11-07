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
