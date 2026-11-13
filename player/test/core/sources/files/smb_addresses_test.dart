import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/smb_addresses.dart';
import 'package:player/core/sources/files/smb_native.dart';
import 'package:player/core/sources/source.dart';

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
}
