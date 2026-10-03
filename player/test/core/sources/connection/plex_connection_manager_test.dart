import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/connection/plex_connection_manager.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/source_error.dart';

ServerConnection c(String uri, {bool local = false, bool relay = false}) =>
    ServerConnection(uri: Uri.parse(uri), local: local, relay: relay);

final local = c('https://10-0-0-5.m1.plex.direct:32400', local: true);
final httpLocal = c('http://10.0.0.5:32400', local: true);
final remote = c('https://203-0-113-9.m1.plex.direct:32400');
final httpRemote = c('http://203.0.113.9:32400');
final relay = c('https://relay-1.m1.plex.direct:8443', relay: true);

/// Each candidate answers after its delay with its machine id; a null id
/// refuses. A candidate missing from the map never answers.
class ScriptedProbe {
  final answers = <Uri, (Duration, String?)>{};
  final calls = <Uri>[];

  Future<String?> call(Uri base, Duration timeout) async {
    calls.add(base);
    final answer = answers[base];
    if (answer == null) return Completer<String?>().future;
    await Future<void>.delayed(answer.$1);
    if (answer.$2 == null) throw Exception('refused');
    return answer.$2;
  }
}

void main() {
  test('ranks local, then remote, then relay, HTTPS before HTTP', () {
    expect(
      rankPlexConnections([relay, httpRemote, remote, httpLocal, local],
          allowInsecureLocal: true),
      [local, httpLocal, remote, relay],
      reason: 'plain HTTP is only ever tried on the LAN',
    );
    expect(
      rankPlexConnections([relay, remote, httpLocal, local],
          allowInsecureLocal: false),
      [local, remote, relay],
    );
  });

  test('the first answer is used at once, a better one replaces it', () {
    fakeAsync((async) {
      final probe = ScriptedProbe()
        ..answers[relay.uri] = (const Duration(milliseconds: 100), 'm1')
        ..answers[local.uri] = (const Duration(milliseconds: 900), 'm1')
        ..answers[remote.uri] = (const Duration(milliseconds: 50), null);
      final manager = PlexConnectionManager(
        machineIdentifier: 'm1',
        candidates: [local, remote, relay],
        probe: probe.call,
      );
      Uri? got;
      manager.base().then((uri) => got = uri);

      async.elapse(const Duration(milliseconds: 100));
      expect(got, relay.uri);
      expect(manager.status.value, SourceConnectionStatus.relay);

      async.elapse(const Duration(milliseconds: 800));
      expect(manager.currentBase, local.uri);
      expect(manager.status.value, SourceConnectionStatus.local);
      manager.dispose();
    });
  });

  test('an answer from a different server is ignored', () {
    fakeAsync((async) {
      final probe = ScriptedProbe()
        ..answers[local.uri] = (const Duration(milliseconds: 10), 'other')
        ..answers[relay.uri] = (const Duration(milliseconds: 200), 'm1');
      final manager = PlexConnectionManager(
        machineIdentifier: 'm1',
        candidates: [local, relay],
        probe: probe.call,
      );
      Uri? got;
      manager.base().then((uri) => got = uri);
      async.elapse(const Duration(milliseconds: 300));
      expect(got, relay.uri);
      manager.dispose();
    });
  });

  test('probes time out: 3s direct, 6s relay', () {
    fakeAsync((async) {
      final probe = ScriptedProbe()
        ..answers[local.uri] = (const Duration(seconds: 4), 'm1')
        ..answers[relay.uri] = (const Duration(seconds: 5), 'm1');
      final manager = PlexConnectionManager(
        machineIdentifier: 'm1',
        candidates: [local, relay],
        probe: probe.call,
      );
      manager.base();
      async.elapse(const Duration(seconds: 7));
      expect(manager.currentBase, relay.uri);
      manager.dispose();
    });
  });

  test('nothing answers: unreachable, then a refresh recovers', () {
    fakeAsync((async) {
      final probe = ScriptedProbe()
        ..answers[local.uri] = (const Duration(milliseconds: 10), null)
        ..answers[relay.uri] = (const Duration(milliseconds: 10), null);
      final manager = PlexConnectionManager(
        machineIdentifier: 'm1',
        candidates: [local, relay],
        probe: probe.call,
      );
      Object? error;
      manager.base().catchError((Object e) {
        error = e;
        return Uri();
      });
      async.elapse(const Duration(seconds: 1));
      expect(
          error,
          isA<SourceException>()
              .having((e) => e.kind, 'kind', SourceErrorKind.unreachable));
      expect(manager.status.value, SourceConnectionStatus.unreachable);

      probe.answers[local.uri] = (const Duration(milliseconds: 10), 'm1');
      manager.refresh();
      async.elapse(const Duration(seconds: 1));
      expect(manager.status.value, SourceConnectionStatus.local);
      manager.dispose();
    });
  });

  test('a refresh never downgrades a connection that still answers', () {
    fakeAsync((async) {
      final probe = ScriptedProbe()
        ..answers[local.uri] = (const Duration(milliseconds: 10), 'm1')
        ..answers[relay.uri] = (const Duration(milliseconds: 500), 'm1');
      final manager = PlexConnectionManager(
        machineIdentifier: 'm1',
        candidates: [local, relay],
        probe: probe.call,
      );
      manager.base();
      async.elapse(const Duration(seconds: 1));
      expect(manager.currentBase, local.uri);

      probe.answers[local.uri] = (const Duration(milliseconds: 900), 'm1');
      probe.answers[relay.uri] = (const Duration(milliseconds: 10), 'm1');
      final seen = <SourceConnectionStatus>[];
      manager.status.addListener(() => seen.add(manager.status.value));
      manager.refresh();
      async.elapse(const Duration(seconds: 2));
      expect(manager.currentBase, local.uri);
      expect(seen, isNot(contains(SourceConnectionStatus.relay)));
      manager.dispose();
    });
  });

  test('a refresh moves off a connection that stopped answering', () {
    fakeAsync((async) {
      final probe = ScriptedProbe()
        ..answers[local.uri] = (const Duration(milliseconds: 10), 'm1')
        ..answers[remote.uri] = (const Duration(milliseconds: 20), 'm1');
      final manager = PlexConnectionManager(
        machineIdentifier: 'm1',
        candidates: [local, remote],
        probe: probe.call,
      );
      manager.base();
      async.elapse(const Duration(seconds: 1));
      expect(manager.currentBase, local.uri);

      probe.answers[local.uri] = (const Duration(milliseconds: 10), null);
      manager.refresh();
      async.elapse(const Duration(seconds: 4));
      expect(manager.currentBase, remote.uri);
      expect(manager.status.value, SourceConnectionStatus.remote);
      manager.dispose();
    });
  });

  test('a failure of the connection in use re-races at once', () {
    fakeAsync((async) {
      final probe = ScriptedProbe()
        ..answers[local.uri] = (const Duration(milliseconds: 10), 'm1')
        ..answers[relay.uri] = (const Duration(milliseconds: 20), 'm1');
      final manager = PlexConnectionManager(
        machineIdentifier: 'm1',
        candidates: [local, relay],
        probe: probe.call,
      );
      manager.base();
      async.elapse(const Duration(seconds: 1));
      probe.answers[local.uri] = (const Duration(milliseconds: 10), null);

      manager.reportFailure(local.uri);
      expect(manager.status.value, SourceConnectionStatus.connecting);
      async.elapse(const Duration(seconds: 4));
      expect(manager.currentBase, relay.uri);
      manager.dispose();
    });
  });

  test('re-fetches candidates every 15 minutes, and stops when disposed', () {
    fakeAsync((async) {
      var fetches = 0;
      final probe = ScriptedProbe()
        ..answers[local.uri] = (const Duration(milliseconds: 10), 'm1')
        ..answers[remote.uri] = (const Duration(milliseconds: 10), 'm1');
      final manager = PlexConnectionManager(
        machineIdentifier: 'm1',
        candidates: [local],
        probe: probe.call,
        refetch: () async {
          fetches++;
          return [remote];
        },
      );
      manager.base();
      async.elapse(const Duration(minutes: 15, seconds: 5));
      expect(fetches, 1);
      expect(manager.currentBase, remote.uri,
          reason: 'the old LAN address is no longer advertised');

      manager.dispose();
      async.elapse(const Duration(minutes: 30));
      expect(fetches, 1);
    });
  });
}
