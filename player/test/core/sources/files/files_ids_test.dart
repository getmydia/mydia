import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_ids.dart';

void main() {
  test('provisional key is p plus 16 hex and stable', () {
    final k = provisionalKey('copper valley|2018');
    expect(k, matches(RegExp(r'^p[0-9a-f]{16}$')));
    expect(provisionalKey('copper valley|2018'), k);
    expect(provisionalKey('other'), isNot(k));
  });

  test('builds and parses every kind', () {
    final p = provisionalKey('x');
    expect(episodeId('42', 1, 2), '42-1-2');
    expect(seasonId(p, 3), '$p-3');

    final e = parseFilesId('42-1-2')!;
    expect((e.tmdbId, e.season, e.episode, e.isProvisional), (42, 1, 2, false));
    final s = parseFilesId('$p-3')!;
    expect((s.base, s.season, s.episode, s.isProvisional), (p, 3, null, true));
    expect(parseFilesId('42')!.tmdbId, 42);
    final f = parseFilesId(unmatchedFileId('abcdef0123456789'))!;
    expect(f.isUnmatchedFile, isTrue);
    expect(f.fileKey, 'abcdef0123456789');
    expect(parseFilesId('nonsense'), isNull);
  });

  group('SMB account ids', () {
    String id(String url) => smbAccountId(Uri.parse(url));

    test('normalizes_equivalent_addresses', () {
      final a = id('smb://NAS.local/Media/');
      expect(a, matches(RegExp(r'^s[0-9a-f]{16}$')));
      expect(id('smb://nas.local:445/media'), a);
      expect(id('smb://nas.local/MEDIA'), a);
      expect(id('smb://nas.local:4455/media'), isNot(a));
      expect(id('smb://nas.local/other'), isNot(a));
    });

    test('normalized_form_keeps_ipv6_brackets_and_odd_ports', () {
      expect(
          normalizeSmbUrl(Uri.parse('smb://[fe80::1]/M')), 'smb://[fe80::1]/m');
      expect(normalizeSmbUrl(Uri.parse('smb://NAS:4455/Media/')),
          'smb://nas:4455/media');
    });

    test('target_defaults_to_port_445', () {
      final t =
          smbTargetOf(Uri.parse(normalizeSmbUrl(Uri.parse('smb://nas/Media'))));
      expect((t.host, t.port, t.share), ('nas', 445, 'media'));
      final v6 = smbTargetOf(Uri.parse('smb://[fe80::1]:4455/m'));
      expect((v6.host, v6.port, v6.share), ('fe80::1', 4455, 'm'));
    });

    test('isSmbAccountId_is_exact', () {
      expect(isSmbAccountId('s0123456789abcdef'), isTrue);
      expect(isSmbAccountId('s0123456789abcde'), isFalse);
      expect(isSmbAccountId('s0123456789abcdeg'), isFalse);
      expect(isSmbAccountId('w0123456789abcdef'), isFalse);
      expect(isSmbAccountId('sources'), isFalse);
    });
  });
}
