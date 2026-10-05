import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/playback/simple_playback_transport.dart';
import 'package:player/core/player/progress_reporter.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/domain/models/media_segment.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/player/session/source_playback_session.dart';

import '../../sources/fake_media_source.dart';

class _SegmentSource extends FakeMediaSource implements SkipSegments {
  _SegmentSource({this.error});

  final Exception? error;
  final requests = <(ItemRef, String?)>[];

  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.skipSegments};

  @override
  Future<List<MediaSegment>> skipSegments(ItemRef ref,
      {String? versionId}) async {
    requests.add((ref, versionId));
    final e = error;
    if (e != null) throw e;
    return const [
      MediaSegment(type: SegmentType.intro, startMs: 1000, endMs: 61000),
    ];
  }
}

class _Session extends SourcePlaybackSession {
  _Session(FakeMediaSource source)
      : super(source: source, item: fakeEpisode(1).ref, fileId: 'part-1');

  @override
  List<CandidateStrategy> candidatesFor(MediaVersion version) =>
      throw UnimplementedError();
  @override
  Future<String> fetchText(String path) => throw UnimplementedError();
  @override
  ProgressReporter createProgress() => throw UnimplementedError();
  @override
  StreamResolver createResolver(ItemDetail detail, MediaVersion version) =>
      throw UnimplementedError();
  @override
  StreamResolver createReceiverResolver(
    ItemDetail detail,
    MediaVersion version, {
    String? burnSubtitleStreamId,
  }) =>
      throw UnimplementedError();
}

void main() {
  test('a source without SkipSegments has no segments', () async {
    expect(await _Session(FakeMediaSource()).segments(), isNull);
  });

  test('asks the source for the playing item and version', () async {
    final source = _SegmentSource();
    final segments = await _Session(source).segments();
    expect(segments, hasLength(1));
    expect(segments!.single.type, SegmentType.intro);
    expect(source.requests.single.$1, fakeEpisode(1).ref);
    expect(source.requests.single.$2, 'part-1');
  });

  test('a failing source is null, not an error', () async {
    final source = _SegmentSource(error: const SourceException.unreachable());
    expect(await _Session(source).segments(), isNull);
  });
}
