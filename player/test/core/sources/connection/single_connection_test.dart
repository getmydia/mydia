import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/connection/source_connection.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/source_error.dart';

void main() {
  final lan =
      ServerConnection(uri: Uri.parse('http://192.168.1.20:9999'), local: true);

  test('probes once, then answers from memory', () async {
    var probes = 0;
    final connection = SingleConnection(
      connection: lan,
      probe: (_) async {
        probes++;
        return true;
      },
    );
    expect(await connection.base(), lan.uri);
    expect(await connection.base(), lan.uri);
    expect(probes, 1);
    expect(connection.status.value, SourceConnectionStatus.local);
  });

  test('reports unreachable and recovers on refresh', () async {
    var up = false;
    final connection =
        SingleConnection(connection: lan, probe: (_) async => up);
    await expectLater(connection.base(), throwsA(isA<SourceException>()));
    expect(connection.status.value, SourceConnectionStatus.unreachable);
    up = true;
    await connection.refresh();
    expect(connection.status.value, SourceConnectionStatus.local);
  });

  test('knows private hosts', () {
    for (final host in [
      '10.1.2.3',
      '172.16.0.1',
      '172.31.255.1',
      '192.168.0.9',
      '127.0.0.1',
      'localhost',
      'nas.local',
      '::1',
      'fd12:3456::1'
    ]) {
      expect(isPrivateHost(host), isTrue, reason: host);
    }
    for (final host in ['172.32.0.1', '8.8.8.8', 'stash.example.test']) {
      expect(isPrivateHost(host), isFalse, reason: host);
    }
  });
}
