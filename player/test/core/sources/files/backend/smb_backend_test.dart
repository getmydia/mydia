import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/backend/smb_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/smb_discovery.dart';
import 'package:player/core/sources/files/smb_native.dart';

import '../fake_smb_discovery.dart';
import '../fake_smb_native.dart';

const _target = SmbTarget(host: 'nas.local', port: 445, share: 'media');

/// Holds the next [list] until [gate] completes.
class _GatedNative extends FakeSmbNative {
  Completer<void>? gate;

  @override
  Future<List<FileEntry>> list(
      SmbTarget t, SmbCredentials c, String dir) async {
    final g = gate;
    gate = null;
    if (g != null) await g.future;
    return super.list(t, c, dir);
  }
}

const _creds = SmbCredentials(user: 'quill', password: 'pw');

void main() {
  late FakeSmbNative native;

  setUp(() {
    native = FakeSmbNative()
      ..addFile('media', '/Films/Copper Valley (2018).mkv', size: 7)
      ..addDir('media', '/Shows');
  });

  SmbBackend backend() => SmbBackend(
        native: native,
        accountId: 'sabc',
        target: _target,
        credentials: _creds,
      );

  test('list_and_stat_pass_native_entries_through', () async {
    final b = backend();
    final entries = await b.list('/Films');
    expect(entries.single.path, '/Films/Copper Valley (2018).mkv');
    expect(entries.single.size, 7);
    final root = await b.list('/');
    expect(root.map((e) => e.path), unorderedEquals(['/Films', '/Shows']));
    expect((await b.stat('/Films'))?.isDir, isTrue);
    expect(await b.stat('/missing'), isNull);
  });

  test('playable_is_the_loopback_url_with_no_headers', () async {
    final p = await backend().playable('/Films/Copper Valley (2018).mkv');
    expect(p.url, 'http://127.0.0.1:1/smb/0');
    expect(p.headers, isEmpty);
    expect(native.opens, [('sabc', '/Films/Copper Valley (2018).mkv')]);
  });

  test('probe_checks_the_share_root', () async {
    await backend().probe();
    expect(native.probes, ['/']);
    native.failure = const BackendUnauthorized();
    await expectLater(backend().probe(), throwsA(isA<BackendUnauthorized>()));
  });

  group('LazySmbBackend', () {
    LazySmbBackend lazy(Future<String?> Function() credentials) =>
        LazySmbBackend(
          native: native,
          accountId: 'sabc',
          targets: [_target],
          credentials: credentials,
        );

    test('missing_or_unreadable_credentials_are_refused', () async {
      String? stored;
      final b = lazy(() async => stored);
      await expectLater(b.probe(), throwsA(isA<BackendUnauthorized>()));
      stored = 'not json';
      await expectLater(b.probe(), throwsA(isA<BackendUnauthorized>()));
      stored = _creds.toJson();
      await b.probe();
    });

    test('a_late_failure_never_drops_a_newer_build', () async {
      final gated = _GatedNative()..addDir('media', '/Films');
      final b = LazySmbBackend(
        native: gated,
        accountId: 'sabc',
        targets: [_target],
        credentials: () async => _creds.toJson(),
      );
      await b.list('/');
      expect(gated.probes, hasLength(1));

      // A slow call on the first build, failing only after a newer build.
      gated.gate = Completer<void>();
      final gate = gated.gate!;
      final slow = b.list('/');
      gated.hostFailures['nas.local'] = const BackendUnreachable();
      await expectLater(b.list('/'), throwsA(isA<BackendUnreachable>()));
      gated.hostFailures.remove('nas.local');
      await b.list('/');
      expect(gated.probes, hasLength(2));

      gated.hostFailures['nas.local'] = const BackendUnreachable();
      gate.complete();
      await expectLater(slow, throwsA(isA<BackendUnreachable>()));
      gated.hostFailures.remove('nas.local');
      await b.list('/');
      expect(gated.probes, hasLength(2), reason: 'the newer build is kept');
    });

    test('a_refused_call_rereads_the_credentials', () async {
      var reads = 0;
      final b = lazy(() async {
        reads++;
        return _creds.toJson();
      });
      await b.probe();
      await b.probe();
      expect(reads, 1);

      native.failure = const BackendUnauthorized();
      await expectLater(b.list('/'), throwsA(isA<BackendUnauthorized>()));
      native.failure = null;
      await b.list('/');
      expect(reads, 2);
    });
  });

  group('LazySmbBackend addresses', () {
    const a = SmbTarget(host: '192.168.1.5', port: 445, share: 'media');
    const b = SmbTarget(host: 'nas.local', port: 445, share: 'media');
    late FakeSmbDiscovery discovery;
    late List<(SmbTarget, List<SmbTarget>)> reached;

    setUp(() {
      discovery = FakeSmbDiscovery();
      reached = [];
    });

    LazySmbBackend lazy({
      List<SmbTarget> targets = const [a, b],
      String? serviceName = 'NAS',
      Duration browseTimeout = const Duration(seconds: 5),
    }) =>
        LazySmbBackend(
          native: native,
          accountId: 'sabc',
          targets: targets,
          credentials: () async => _creds.toJson(),
          serviceName: serviceName,
          discovery: discovery,
          onReachedVia: (t, d) async => reached.add((t, d)),
          browseTimeout: browseTimeout,
        );

    List<String> probedHosts() =>
        [for (final (t, _) in native.probeLogins) t.host];

    test('first_reachable_target_is_used_and_promoted', () async {
      native.hostFailures['192.168.1.5'] = const BackendUnreachable();
      final backend = lazy();
      await backend.list('/');
      await backend.stat('/Films');
      expect(probedHosts(), ['192.168.1.5', 'nas.local']);
      await pumpEventQueue();
      expect(reached.length, 1);
      expect(reached.single.$1.host, 'nas.local');
      expect(reached.single.$2, isEmpty);
    });

    test('first_target_answering_is_not_promoted', () async {
      await lazy().list('/');
      await pumpEventQueue();
      expect(probedHosts(), ['192.168.1.5']);
      expect(reached, isEmpty);
    });

    test('stale_ip_refusing_login_falls_through_to_the_hostname', () async {
      native.hostFailures['192.168.1.5'] = const BackendUnauthorized();
      await lazy().list('/');
      await pumpEventQueue();
      expect(probedHosts(), ['192.168.1.5', 'nas.local']);
      expect(reached.single.$1.host, 'nas.local');
    });

    test('every_target_refusing_login_rethrows_unauthorized_without_browsing',
        () async {
      native.hostFailures['192.168.1.5'] = const BackendUnauthorized();
      native.hostFailures['nas.local'] = const BackendUnauthorized();
      await expectLater(lazy().list('/'), throwsA(isA<BackendUnauthorized>()));
      expect(discovery.listenCount, 0);
    });

    test('a_refused_login_wins_over_an_unreachable_address', () async {
      native.hostFailures['192.168.1.5'] = const BackendUnreachable();
      native.hostFailures['nas.local'] = const BackendUnauthorized();
      await expectLater(
        lazy(browseTimeout: const Duration(milliseconds: 50)).list('/'),
        throwsA(isA<BackendUnauthorized>()),
      );
      expect(discovery.listenCount, 1);
    });

    test('all_unreachable_browses_by_service_name', () async {
      native.hostFailures['192.168.1.5'] = const BackendUnreachable();
      native.hostFailures['nas.local'] = const BackendUnreachable();
      final call = lazy().list('/');
      await pumpEventQueue();
      expect(discovery.listenCount, 1);
      discovery.emit(const [
        DiscoveredSmbServer(
          name: 'NAS',
          host: '10.0.0.9',
          port: 4455,
          hostname: 'nas.local',
        ),
      ]);
      await call;
      expect(probedHosts(), ['192.168.1.5', 'nas.local', '10.0.0.9']);
      expect(native.probeLogins.last.$1.port, 4455);
      expect(native.probeLogins.last.$1.share, 'media');
      expect(discovery.cancelCount, 1);
      await pumpEventQueue();
      final (t, d) = reached.single;
      expect(t.host, '10.0.0.9');
      expect(t.port, 4455);
      // The hostname on port 4455 is a new target: the stored one is on 445.
      expect([for (final x in d) '${x.host}:${x.port}'],
          ['10.0.0.9:4455', 'nas.local:4455']);
    });

    test('browse_ignores_other_names_and_times_out', () async {
      native.hostFailures['192.168.1.5'] = const BackendUnreachable('first');
      native.hostFailures['nas.local'] = const BackendUnreachable('last');
      final call =
          lazy(browseTimeout: const Duration(milliseconds: 50)).list('/');
      await pumpEventQueue();
      discovery.emit(const [
        DiscoveredSmbServer(name: 'Other', host: '10.0.0.7', port: 445),
      ]);
      await expectLater(
        call,
        throwsA(isA<BackendUnreachable>()
            .having((e) => e.message, 'message', 'last')),
      );
      expect(discovery.cancelCount, 1);
      expect(probedHosts(), ['192.168.1.5', 'nas.local']);
    });

    test('old_record_without_service_name_does_not_browse', () async {
      native.hostFailures['192.168.1.5'] = const BackendUnreachable();
      await expectLater(
        lazy(targets: const [a], serviceName: null).list('/'),
        throwsA(isA<BackendUnreachable>()),
      );
      expect(discovery.listenCount, 0);
    });

    test('smb1_only_surfaces_over_a_plain_unreachable', () async {
      native.hostFailures['192.168.1.5'] =
          const BackendUnreachable(kSmb1OnlyReason);
      native.hostFailures['nas.local'] = const BackendUnreachable();
      await expectLater(
        lazy(serviceName: null).list('/'),
        throwsA(isA<BackendUnreachable>()
            .having((e) => e.message, 'message', kSmb1OnlyReason)),
      );
      expect(probedHosts(), ['192.168.1.5', 'nas.local']);
    });

    test('a_later_target_that_answered_is_probed_first_after_a_drop', () async {
      native.hostFailures['192.168.1.5'] = const BackendUnreachable();
      final backend = lazy();
      await backend.list('/');
      expect(probedHosts(), ['192.168.1.5', 'nas.local']);

      native.hostFailures['nas.local'] = const BackendUnreachable();
      await expectLater(backend.list('/'), throwsA(isA<BackendUnreachable>()));
      native.hostFailures.remove('nas.local');
      await backend.list('/');

      expect(probedHosts(), ['192.168.1.5', 'nas.local', 'nas.local']);
      expect(discovery.listenCount, 0);
      await pumpEventQueue();
      expect(reached.single.$1.host, 'nas.local');
    });

    test('an_address_found_by_browsing_is_probed_first_after_a_drop', () async {
      native.hostFailures['192.168.1.5'] = const BackendUnreachable();
      native.hostFailures['nas.local'] = const BackendUnreachable();
      final backend = lazy();
      final call = backend.list('/');
      await pumpEventQueue();
      discovery.emit(const [
        DiscoveredSmbServer(name: 'NAS', host: '10.0.0.9', port: 445),
      ]);
      await call;

      native.hostFailures['10.0.0.9'] = const BackendUnreachable();
      await expectLater(backend.list('/'), throwsA(isA<BackendUnreachable>()));
      native.hostFailures.remove('10.0.0.9');
      await backend.list('/');

      expect(
          probedHosts(), ['192.168.1.5', 'nas.local', '10.0.0.9', '10.0.0.9']);
      expect(discovery.listenCount, 1);
    });

    test('stale_ip_refuses_hostname_unreachable_browse_finds_the_nas',
        () async {
      native.hostFailures['192.168.1.5'] = const BackendUnauthorized();
      native.hostFailures['nas.local'] = const BackendUnreachable();
      final backend = lazy();
      final call = backend.list('/');
      await pumpEventQueue();
      expect(discovery.listenCount, 1);
      discovery.emit(const [
        DiscoveredSmbServer(
            name: 'NAS', host: '10.0.0.9', port: 445, hostname: 'nas.local'),
      ]);

      await call;
      expect(probedHosts(), ['192.168.1.5', 'nas.local', '10.0.0.9']);
      await pumpEventQueue();
      expect(reached.single.$1.host, '10.0.0.9');
    });

    test('unreachable_call_drops_the_built_backend', () async {
      final backend = lazy();
      await backend.list('/');
      expect(probedHosts(), ['192.168.1.5']);
      native.hostFailures['192.168.1.5'] = const BackendUnreachable();
      await expectLater(backend.list('/'), throwsA(isA<BackendUnreachable>()));
      await backend.list('/');
      expect(probedHosts(), ['192.168.1.5', '192.168.1.5', 'nas.local']);
      await pumpEventQueue();
      expect(reached.single.$1.host, 'nas.local');
    });
  });
}
