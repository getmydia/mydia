import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/smb_addresses.dart';
import 'package:player/core/sources/files/smb_native.dart';
import 'package:player/core/sources/source.dart';

import 'fake_smb_native.dart';

List<String> _uris(List<ServerConnection> c) =>
    c.map((e) => e.uri.toString()).toList();

void main() {
  test('connections_dedupe_and_keep_order', () {
    final c = smbConnections(
      share: 'media',
      port: 445,
      hosts: ['192.168.1.5', 'NAS.local.', '192.168.1.5', '10.0.0.5'],
    );
    expect(_uris(c), [
      'smb://192.168.1.5/media',
      'smb://nas.local/media',
      'smb://10.0.0.5/media',
    ]);
    expect(c[0].local, isTrue);
    expect(c[1].local, isTrue);
  });

  test('non_default_port_is_kept', () {
    final c =
        smbConnections(share: 'media', port: 1445, hosts: ['192.168.1.5']);
    expect(_uris(c), ['smb://192.168.1.5:1445/media']);
  });

  test('cap_keeps_the_hostname', () {
    final hosts = [
      for (var i = 1; i <= 7; i++) '10.0.0.$i',
      'nas.local',
    ];
    final c = smbConnections(share: 'media', port: 445, hosts: hosts);
    expect(c, hasLength(kSmbMaxConnections));
    expect(_uris(c), contains('smb://nas.local/media'));
    expect(_uris(c), [
      for (var i = 1; i <= 5; i++) 'smb://10.0.0.$i/media',
      'smb://nas.local/media',
    ]);
  });

  test('cap_never_drops_the_first_entry', () {
    ServerConnection at(String host) =>
        smbConnectionOf(SmbTarget(host: host, port: 445, share: 'media'));
    final c = capSmbConnections([
      at('10.0.0.9'),
      for (var i = 1; i <= 6; i++) at('nas$i.local'),
    ]);
    expect(c, hasLength(kSmbMaxConnections));
    expect(_uris(c), [
      'smb://10.0.0.9/media',
      for (var i = 1; i <= 5; i++) 'smb://nas$i.local/media',
    ]);
  });

  test('cap_drops_ip_literals_before_hostnames_and_keeps_the_first', () {
    ServerConnection at(String host) =>
        smbConnectionOf(SmbTarget(host: host, port: 445, share: 'media'));
    final c = capSmbConnections([
      at('10.0.0.9'),
      at('nas1.local'),
      at('10.0.0.1'),
      for (var i = 2; i <= 6; i++) at('nas$i.local'),
    ]);
    expect(c, hasLength(kSmbMaxConnections));
    expect(_uris(c), [
      'smb://10.0.0.9/media',
      for (var i = 1; i <= 5; i++) 'smb://nas$i.local/media',
    ]);
  });

  test('promote_moves_reached_first_and_appends_discovered', () {
    final a = smbConnections(
        share: 'media',
        port: 445,
        hosts: ['10.0.0.1', 'nas.local', '10.0.0.2']);
    final extra = smbConnections(
        share: 'media', port: 445, hosts: ['10.0.0.2', '10.0.0.9']);
    final p = promoteSmbConnection(a, a[2], discovered: extra);
    expect(_uris(p), [
      'smb://10.0.0.2/media',
      'smb://10.0.0.1/media',
      'smb://nas.local/media',
      'smb://10.0.0.9/media',
    ]);
  });

  test('ipv6_literal_round_trips', () {
    final c = smbConnections(share: 'media', port: 445, hosts: ['fd00::5']);
    expect(c.single.uri.toString(), contains('[fd00::5]'));
    final t = smbTargetsOf(c).single;
    expect(t.host, 'fd00::5');
    expect(t.port, 445);
    expect(t.share, 'media');
  });

  test('connection_of_target_round_trips', () {
    for (final t in const [
      SmbTarget(host: '192.168.1.5', port: 445, share: 'media'),
      SmbTarget(host: 'nas.local', port: 1445, share: 'media'),
      SmbTarget(host: 'fd00::5', port: 445, share: 'media'),
      SmbTarget(host: 'fd00::5', port: 1445, share: 'media'),
    ]) {
      final c = smbConnectionOf(t);
      final back = smbTargetOf(c.uri);
      expect(back.host, t.host);
      expect(back.port, t.port);
      expect(back.share, t.share);
    }
    expect(
        smbConnectionOf(
                const SmbTarget(host: 'fd00::5', port: 445, share: 'media'))
            .uri
            .toString(),
        contains('[fd00::5]'));
  });

  test('host_helpers', () {
    expect(normalizeSmbHost(' NAS.Local. '), 'nas.local');
    expect(isIpLiteral('10.0.0.1'), isTrue);
    expect(isIpLiteral('fd00::5'), isTrue);
    expect(isIpLiteral('nas.local'), isFalse);
  });

  group('parseSmbAddress', () {
    test('ipv4_with_an_empty_port_is_445', () {
      expect(parseSmbAddress('192.168.1.5', ''),
          (host: '192.168.1.5', port: kSmbDefaultPort));
    });

    test('hostname_and_port_field_trimmed', () {
      expect(parseSmbAddress('  nas.example.test ', ' 4445 '),
          (host: 'nas.example.test', port: 4445));
    });

    test('bracketed_ipv6_loses_its_brackets', () {
      expect(parseSmbAddress('[fd00::5]', ''), (host: 'fd00::5', port: 445));
    });

    test('bracketed_ipv6_with_an_inline_port', () {
      expect(
          parseSmbAddress('[fd00::5]:1445', ''), (host: 'fd00::5', port: 1445));
      expect(parseSmbAddress(' [fd00::5]:1445 ', '139'),
          (host: 'fd00::5', port: 1445));
      expect(
          parseSmbAddress('[fd00::5]', '1445'), (host: 'fd00::5', port: 1445));
    });

    test('bracketed_ipv6_with_a_bad_inline_port_is_rejected', () {
      expect(parseSmbAddress('[fd00::5]:0', ''), isNull);
      expect(parseSmbAddress('[fd00::5]:x', ''), isNull);
      expect(parseSmbAddress('[fd00::5]:', ''), isNull);
      expect(parseSmbAddress('[fd00::5]x', ''), isNull);
    });

    test('bare_ipv6_is_a_host', () {
      expect(parseSmbAddress('2001:db8::1', '4455'),
          (host: '2001:db8::1', port: 4455));
    });

    test('host_colon_port_wins_over_the_port_field', () {
      expect(parseSmbAddress('nas.local:4455', '139'),
          (host: 'nas.local', port: 4455));
    });

    test('bad_ports_are_rejected', () {
      expect(parseSmbAddress('nas.local:0', ''), isNull);
      expect(parseSmbAddress('nas.local:x', ''), isNull);
      expect(parseSmbAddress('nas.local', '65536'), isNull);
      expect(parseSmbAddress('nas.local', 'abc'), isNull);
    });

    test('empty_or_malformed_hosts_are_rejected', () {
      expect(parseSmbAddress('', ''), isNull);
      expect(parseSmbAddress('   ', ''), isNull);
      expect(parseSmbAddress('[]', ''), isNull);
      expect(parseSmbAddress('nas local', ''), isNull);
      expect(parseSmbAddress('nas/share', ''), isNull);
    });
  });

  group('listSharesAtFirstReachable', () {
    const creds = SmbCredentials(user: 'viewer', password: 'pw');
    late _ListingNative native;

    setUp(() => native = _ListingNative()..addDir('media', '/Films'));

    test('moves_past_an_unreachable_address', () async {
      native.hostFailures['172.17.0.1'] = const BackendUnreachable();
      final (shares, host) = await listSharesAtFirstReachable(
          native, ['172.17.0.1', '192.168.1.5', 'nas.local'], 445, creds);
      expect(shares, ['media']);
      expect(host, '192.168.1.5');
      expect(native.listed, ['172.17.0.1', '192.168.1.5']);
    });

    test('stops_at_a_refused_login_or_smb1', () async {
      native.hostFailures['172.17.0.1'] = const BackendUnauthorized();
      await expectLater(
          listSharesAtFirstReachable(
              native, ['172.17.0.1', '192.168.1.5'], 445, creds),
          throwsA(isA<BackendUnauthorized>()));
      native.hostFailures['172.17.0.1'] =
          const BackendUnreachable(kSmb1OnlyReason);
      await expectLater(
          listSharesAtFirstReachable(
              native, ['172.17.0.1', '192.168.1.5'], 445, creds),
          throwsA(isA<BackendUnreachable>()));
      expect(native.listed, ['172.17.0.1', '172.17.0.1']);
    });

    test('the_last_unreachable_address_is_rethrown', () async {
      native.hostFailures['a'] = const BackendUnreachable('a');
      native.hostFailures['b'] = const BackendUnreachable('b');
      await expectLater(
          listSharesAtFirstReachable(native, ['a', 'b'], 445, creds),
          throwsA(isA<BackendUnreachable>()
              .having((e) => e.message, 'message', 'b')));
    });
  });
}

/// Records the host of every share listing.
class _ListingNative extends FakeSmbNative {
  final listed = <String>[];

  @override
  Future<List<String>> listShares(String host, int port, SmbCredentials c) {
    listed.add(host);
    return super.listShares(host, port, c);
  }
}
