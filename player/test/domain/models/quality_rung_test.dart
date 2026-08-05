import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/quality_rung.dart';

void main() {
  group('deriveQualityLadder', () {
    test('offers only Original when the source height is unknown', () {
      // Without metadata there is no honest way to know which rungs would
      // upscale, so offering a ladder would be guessing.
      final ladder = deriveQualityLadder(sourceHeight: null);

      expect(ladder, [QualityRung.original]);
    });

    test('offers every rung below a 4K source', () {
      final ladder = deriveQualityLadder(sourceHeight: 2160);

      expect(
        ladder.map((r) => r.label),
        ['Original', '1080p', '720p', '480p', '360p'],
      );
    });

    test('never offers a rung at or above the source height', () {
      // A 1080p rung on a 1080p source is just Original with extra CPU cost,
      // and anything above it would upscale.
      final ladder = deriveQualityLadder(sourceHeight: 1080);

      expect(ladder.map((r) => r.label), ['Original', '720p', '480p', '360p']);
    });

    test('collapses to Original alone for a source below every rung', () {
      final ladder = deriveQualityLadder(sourceHeight: 360);

      expect(ladder, [QualityRung.original]);
    });

    test('carries a bitrate cap on every rung except Original', () {
      final ladder = deriveQualityLadder(sourceHeight: 2160);

      expect(ladder.first.maxBitrateKbps, isNull);
      expect(ladder.first.height, isNull);
      for (final rung in ladder.skip(1)) {
        expect(rung.maxBitrateKbps, isNotNull);
        expect(rung.height, isNotNull);
      }
    });

    test('orders rungs from highest quality down', () {
      final heights = deriveQualityLadder(sourceHeight: 2160)
          .skip(1)
          .map((r) => r.height!)
          .toList();

      expect(heights, [1080, 720, 480, 360]);
    });
  });

  group('storage round-trip', () {
    test('Original uses the legacy "auto" key already in secure storage', () {
      // settings_service.dart has persisted 'auto' as the default since
      // before any of this worked; treating it as Original means an existing
      // install does not silently start capping quality after an update.
      expect(QualityRung.original.storageKey, 'auto');
      expect(QualityRung.fromStorageKey('auto'), QualityRung.original);
    });

    test('round-trips a capped rung', () {
      const rung =
          QualityRung(label: '720p', height: 720, maxBitrateKbps: 4000);

      expect(rung.storageKey, '720p');
      expect(QualityRung.fromStorageKey('720p'), rung);
    });

    test('returns null for an unrecognised key', () {
      // A key written by a newer build, or corrupted storage. Callers fall
      // back to Original rather than crashing on startup.
      expect(QualityRung.fromStorageKey('4320p'), isNull);
      expect(QualityRung.fromStorageKey(''), isNull);
    });
  });

  group('effectiveRungLabel', () {
    test('reports Original when the server applied no caps', () {
      expect(
        effectiveRungLabel(maxHeight: null, maxBitrateKbps: null),
        QualityRung.original,
      );
    });

    test('names the rung matching what the server actually applied', () {
      expect(
        effectiveRungLabel(maxHeight: 720, maxBitrateKbps: 4000)?.label,
        '720p',
      );
    });

    test(
        'falls back to the height when the server clamped to an off-ladder pair',
        () {
      // A relay clamps to 2000kbps and 720p, which is not a ladder pair. The
      // viewer still needs an honest label, so height wins.
      expect(
        effectiveRungLabel(maxHeight: 720, maxBitrateKbps: 2000)?.label,
        '720p',
      );
    });
  });
}
