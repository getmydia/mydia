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

  group('S3 account ids', () {
    String norm(String url) => normalizeS3Url(Uri.parse(url));

    test('normalizes_equivalent_connections', () {
      final a =
          norm('s3+https://H.example.com:443/bkt/media?style=path&region=r');
      expect(
          norm('s3+https://h.example.com/bkt//media/?region=r&style=path'), a);
      expect(
          norm('s3+https://h.example.com/bkt/media/?region=r&style=path'), a);
      expect(norm('s3+https://h.example.com/bkt/media?region=r&style=path'), a);
      expect(a, 's3+https://h.example.com/bkt/media/?region=r&style=path');
    });

    test('keys_are_case_sensitive', () {
      expect(
          norm('s3+https://h.example.com/bkt/Media/?region=r&style=path'),
          isNot(
              norm('s3+https://h.example.com/bkt/media/?region=r&style=path')));
    });

    test('http_drops_port_80_and_keeps_others', () {
      expect(norm('s3+http://h:80/bkt?region=r&style=path'),
          's3+http://h/bkt/?region=r&style=path');
      expect(norm('s3+http://h:9000/bkt?region=r&style=path'),
          's3+http://h:9000/bkt/?region=r&style=path');
      expect(norm('s3+https://h:9000/bkt?region=r&style=vhost'),
          's3+https://h:9000/bkt/?region=r&style=vhost');
    });

    test('a_non_s3_connection_throws', () {
      expect(() => norm('https://h.example.com/bkt'), throwsArgumentError);
    });

    test('ids_are_3_plus_16_hex_and_distinct_from_smb', () {
      final s3 = s3AccountId(
          Uri.parse('s3+https://h.example.com/bkt/?region=r&style=path'));
      expect(s3, matches(RegExp(r'^3[0-9a-f]{16}$')));
      expect(isS3AccountId(s3), isTrue);
      expect(isSmbAccountId(s3), isFalse);
      expect(
          isS3AccountId(smbAccountId(Uri.parse('smb://nas/media'))), isFalse);
      expect(isS3AccountId('w0123456789abcdef'), isFalse);
      expect(isS3AccountId('30123456789abcde'), isFalse);
    });
  });

  test('S3Credentials round-trip and never print the secret', () {
    const c =
        S3Credentials(accessKeyId: 'AKIDEXAMPLE', secretAccessKey: 'sekrit');
    final back = S3Credentials.fromJson(c.toJson());
    expect((back.accessKeyId, back.secretAccessKey), ('AKIDEXAMPLE', 'sekrit'));
    expect(c.toString(), contains('AKIDEXAMPLE'));
    expect(c.toString(), isNot(contains('sekrit')));
    expect(() => S3Credentials.fromJson('{"accessKeyId":"a"}'),
        throwsFormatException);
    expect(() => S3Credentials.fromJson('[]'), throwsFormatException);
  });
}
