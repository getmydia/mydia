import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/playback/playback_planner.dart';
import 'package:player/presentation/screens/player/stats_context_builder.dart';

PlanInputs _inputs(List<CandidateStrategy> candidates) => PlanInputs(
      candidates: candidates,
      isWeb: false,
      typeSupported: (_) => true,
      choice: QualityChoice.original,
    );

void main() {
  test('container and codec come from the first candidate', () {
    final inputs = _inputs(const [
      CandidateStrategy(
        strategy: 'DIRECT_PLAY',
        mime: 'video/x-matroska; codecs="hvc1"',
        videoCodec: 'hevc',
      ),
    ]);
    expect(sourceContainerOf(inputs), 'mkv');
    expect(sourceCodecOf(inputs), 'hevc');
  });

  test('codec falls through to the first candidate that names one', () {
    final inputs = _inputs(const [
      CandidateStrategy(strategy: 'TRANSCODE', mime: 'video/mp2t'),
      CandidateStrategy(
          strategy: 'HLS_COPY', mime: 'video/mp2t', videoCodec: 'h264'),
    ]);
    expect(sourceCodecOf(inputs), 'h264');
    expect(sourceContainerOf(inputs), 'ts');
  });

  test('unknown mime and missing inputs read as null', () {
    expect(
      sourceContainerOf(_inputs(const [
        CandidateStrategy(strategy: 'DIRECT_PLAY', mime: 'video/quicktime'),
      ])),
      isNull,
    );
    expect(sourceContainerOf(_inputs(const [])), isNull);
    expect(sourceCodecOf(null), isNull);
    expect(sourceContainerOf(null), isNull);
  });
}
