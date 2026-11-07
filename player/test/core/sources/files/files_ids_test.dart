import 'package:flutter_test/flutter_test.dart';
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
}
