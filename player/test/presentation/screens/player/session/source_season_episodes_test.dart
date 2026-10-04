import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/playback/simple_playback_transport.dart';
import 'package:player/core/player/progress_reporter.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/player/session/source_playback_session.dart';

import '../../sources/fake_media_source.dart';

class _TestSourceSession extends SourcePlaybackSession {
  _TestSourceSession(FakeMediaSource source)
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
}

class _BrokenSession extends _TestSourceSession {
  _BrokenSession() : super(FakeMediaSource());

  @override
  Future<ItemDetail> loadDetail() => Future.error(StateError('down'));
}

void main() {
  test('lists the season through the show', () async {
    final session = _TestSourceSession(FakeMediaSource());
    final episodes = await session.seasonEpisodes(1);
    expect(episodes?.map((e) => e.id), ['e1', 'e2']);
    expect(episodes?.first.fileIds, ['part-1']);
    expect(episodes?.last.episodeNumber, 2);
    expect(episodes?.last.seasonNumber, 1);
  });

  test('a missing season is null, not an error', () async {
    final session = _TestSourceSession(FakeMediaSource());
    expect(await session.seasonEpisodes(9), isNull);
  });

  test('a failing source is null, not an error', () async {
    expect(await _BrokenSession().seasonEpisodes(1), isNull);
  });

  test('the next episode goes to the source player route', () {
    final session = _TestSourceSession(FakeMediaSource());
    final location = Uri.parse(session.episodeLocation(
      episodeId: 'e2',
      fileId: 'part-2',
      title: 'Invented Series - S01E02',
      seasonNumber: 1,
      showId: 's1',
    ));
    expect(location.path, '/s/${fakeSourceId.value}/player/e2');
    expect(location.queryParameters, {
      'kind': 'episode',
      'fileId': 'part-2',
      'title': 'Invented Series - S01E02',
      'showId': 's1',
      'seasonNumber': '1',
    });
  });
}
