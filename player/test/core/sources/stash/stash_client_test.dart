import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/stash/stash_client.dart';
import 'package:player/core/sources/stash/stash_media_source.dart';
import 'package:player/domain/sources/item.dart';

import '../fixed_connection.dart';
import 'stash_media_source_test.dart' show stashRecord;

void main() {
  final proxied = Uri.parse('https://host.example.test/stash');

  test('stashUnder keeps the subpath for rooted and bare paths', () {
    expect(stashUnder(proxied, '/graphql').toString(),
        'https://host.example.test/stash/graphql');
    expect(stashUnder(proxied, 'graphql').toString(),
        'https://host.example.test/stash/graphql');
    expect(stashUnder(Uri.parse('http://192.168.1.20:9999'), '/graphql'),
        Uri.parse('http://192.168.1.20:9999/graphql'));
  });

  test('requests and artwork land under the proxy subpath', () async {
    final requested = <Uri>[];
    final client = StashClient(
      connection: FixedConnection(proxied),
      http: SourceHttp(client: MockClient((request) async {
        requested.add(request.url);
        return http.Response('{"data": {}}', 200);
      })),
      apiKey: () async => null,
    );
    await client.query('query SystemStatus { systemStatus { status } }');
    expect(
        requested.single.toString(), 'https://host.example.test/stash/graphql');

    final source =
        StashMediaSource(source: stashRecord.sources.single, client: client);
    final art = await source
        .artwork(const ArtworkRef('/scene/4/screenshot?t=1700'), width: 300);
    expect(
        art!.url, 'https://host.example.test/stash/scene/4/screenshot?t=1700');
  });

  test('the probe asks the server under its subpath', () async {
    final requested = <Uri>[];
    final up = await stashProbe(
      SourceHttp(client: MockClient((request) async {
        requested.add(request.url);
        return http.Response('{}', 200);
      })),
      proxied,
      () async => null,
    );
    expect(up, isTrue);
    expect(
        requested.single.toString(), 'https://host.example.test/stash/graphql');
  });
}
