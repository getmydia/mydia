import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/playback/simple_playback_transport.dart';
import 'package:player/core/player/progress_reporter.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/playback_sequence.dart';
import 'package:player/presentation/screens/player/session/source_playback_session.dart';

import '../../sources/fake_media_source.dart';

const _sequence = PlaybackSequence(
  origin: SequenceOrigin.library,
  position: 3,
  sortId: 'date',
);

const _next = SequenceNeighbour(
  item: ItemSummary(
    ref: ItemRef(
      sourceId: fakeSourceId,
      kind: ItemKind.movie,
      externalId: 'm4',
    ),
    title: 'Invented Scene 4',
    defaultVersionId: 'part-4',
  ),
  position: 4,
);

class _SequencedSource extends FakeMediaSource implements SceneSequence {
  _SequencedSource({this.fail = false});
  final bool fail;
  final asked = <(ItemRef, PlaybackSequence)>[];

  @override
  Future<SequenceNeighbours> neighbours(
    ItemRef ref,
    PlaybackSequence sequence,
  ) async {
    asked.add((ref, sequence));
    if (fail) throw StateError('down');
    return const SequenceNeighbours(next: _next);
  }
}

class _Session extends SourcePlaybackSession {
  _Session(FakeMediaSource source, {super.sequence})
    : super(source: source, item: fakeMovie(3).ref, fileId: 'part-3');

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
  }) => throw UnimplementedError();
}

void main() {
  test('asks a SceneSequence source for the neighbours', () async {
    final source = _SequencedSource();
    final n = await _Session(source, sequence: _sequence).sequenceNeighbours();
    expect(n?.next, _next);
    expect(source.asked.single, (fakeMovie(3).ref, _sequence));
  });

  test('no sequence on the route means no neighbours', () async {
    final source = _SequencedSource();
    expect(await _Session(source).sequenceNeighbours(), isNull);
    expect(source.asked, isEmpty);
  });

  test('a source without SceneSequence ignores the sequence', () async {
    final session = _Session(FakeMediaSource(), sequence: _sequence);
    expect(await session.sequenceNeighbours(), isNull);
  });

  test('a failing lookup is null, not an error', () async {
    final session = _Session(_SequencedSource(fail: true), sequence: _sequence);
    expect(await session.sequenceNeighbours(), isNull);
  });

  test('a neighbour plays from the source route with its position', () {
    final session = _Session(_SequencedSource(), sequence: _sequence);
    final location = Uri.parse(session.sequenceLocation(_next));
    expect(location.path, '/s/${fakeSourceId.value}/player/m4');
    expect(location.queryParameters, {
      'kind': 'movie',
      'fileId': 'part-4',
      'title': 'Invented Scene 4',
      'seq': 'library',
      'seqPos': '4',
      'seqSort': 'date',
    });
  });
}
