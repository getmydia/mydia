import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/playback/quality_display.dart';
import 'package:player/domain/models/quality_rung.dart';

const _direct = DirectPlayPlan(reason: PlanReason.directPlayAccepted);
const _copy = HlsPlan(
  strategy: HlsStrategy.copy,
  rung: QualityRung.original,
  adaptive: false,
  reason: PlanReason.copyAccepted,
);
const _r720 = QualityRung(label: '720p', height: 720, maxBitrateKbps: 4000);
const _r1080 = QualityRung(label: '1080p', height: 1080, maxBitrateKbps: 8000);

HlsPlan _transcode(QualityRung rung) => HlsPlan(
      strategy: HlsStrategy.transcode,
      rung: rung,
      adaptive: false,
      reason: PlanReason.noDirectPlayCandidate,
    );

void main() {
  group('qualityControlAvailable', () {
    test('a local file or no plan offers nothing', () {
      expect(
        qualityControlAvailable(
            localFile: true, plan: _direct, sourceHeight: 1080),
        isFalse,
      );
      expect(
        qualityControlAvailable(
            localFile: false, plan: null, sourceHeight: 1080),
        isFalse,
      );
    });

    test('a source with an adaptive ladder offers a choice', () {
      expect(
        qualityControlAvailable(
            localFile: false,
            plan: _transcode(QualityRung.original),
            sourceHeight: 720),
        isTrue,
      );
    });

    test('a lossless source offers Auto against Original even with no ladder',
        () {
      expect(
        qualityControlAvailable(
            localFile: false, plan: _direct, sourceHeight: 240),
        isTrue,
      );
      expect(
        qualityControlAvailable(
            localFile: false, plan: _copy, sourceHeight: null),
        isTrue,
      );
    });

    test('a transcode with no adaptive ladder has nothing to choose', () {
      expect(
        qualityControlAvailable(
            localFile: false,
            plan: _transcode(QualityRung.original),
            sourceHeight: 240),
        isFalse,
      );
    });
  });

  group('qualityControlLabel', () {
    test('Auto names itself whatever the server applied', () {
      expect(qualityControlLabel(selected: QualityRung.auto, effective: _r720),
          'Auto');
    });

    test('any other choice shows what the server applied', () {
      expect(
          qualityControlLabel(selected: QualityRung.original, effective: _r720),
          '720p');
      expect(qualityControlLabel(selected: _r1080), '1080p');
    });
  });

  group('qualityClampNote', () {
    test('silent when the stream got what the plan asked for', () {
      expect(
          qualityClampNote(plan: _transcode(_r720), effective: _r720), isNull);
      expect(qualityClampNote(plan: _direct, effective: null), isNull);
      expect(
          qualityClampNote(plan: _transcode(_r720), effective: null), isNull);
    });

    test('names a rung below the one requested', () {
      expect(qualityClampNote(plan: _transcode(_r1080), effective: _r720),
          'Limited to 720p by your connection');
    });

    test('an uncapped request limited to a rung is a limit', () {
      expect(
        qualityClampNote(
            plan: _transcode(QualityRung.original), effective: _r720),
        'Limited to 720p by your connection',
      );
    });

    test('an uncapped answer is never a limit', () {
      expect(
        qualityClampNote(
            plan: _transcode(_r720), effective: QualityRung.original),
        isNull,
      );
    });
  });
}
