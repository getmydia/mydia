import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/jellyfin/jellyfin_connections.dart';
import 'package:player/core/sources/source.dart';

void main() {
  final wan = Uri.parse('https://media.example.test');
  final lan = Uri.parse('http://192.168.1.30:8096');

  test('the entered URL first, then a private LAN address', () {
    expect(jellyfinConnections(wan, lan.toString()), [
      ServerConnection(uri: wan),
      ServerConnection(uri: lan, local: true),
    ]);
  });

  test('a public, missing, malformed or identical LAN address is ignored', () {
    for (final local in [
      'http://203.0.113.9:8096',
      null,
      '::not a uri',
      wan.toString(),
    ]) {
      expect(jellyfinConnections(wan, local), [ServerConnection(uri: wan)],
          reason: '$local');
    }
  });

  test('an entered private URL is itself local', () {
    expect(jellyfinConnections(lan, lan.toString()),
        [ServerConnection(uri: lan, local: true)]);
  });

  test('ranks the LAN first and drops plain HTTP to a public host', () {
    final publicHttp = ServerConnection(uri: Uri.parse('http://203.0.113.9'));
    expect(
      rankJellyfinConnections([
        ServerConnection(uri: wan),
        publicHttp,
        ServerConnection(uri: lan, local: true),
      ]),
      [ServerConnection(uri: lan, local: true), ServerConnection(uri: wan)],
    );
  });
}
