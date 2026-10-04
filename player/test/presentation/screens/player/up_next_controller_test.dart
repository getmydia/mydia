import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';
import 'package:player/presentation/screens/player/up_next_controller.dart';
import 'package:player/presentation/widgets/video_controls/up_next_countdown.dart';

PlaybackEpisode _ep(int n, {int season = 1, List<String?>? files}) =>
    PlaybackEpisode(
      id: 's${season}e$n',
      seasonNumber: season,
      episodeNumber: n,
      title: 'Episode $n',
      fileIds: files ?? ['file-s${season}e$n'],
    );

class _Harness {
  _Harness({
    this.downloaded = const {},
    this.nextSeason,
    this.downloadedSource = false,
    this.playing,
  }) {
    controller = UpNextController(
      fetchSeason: (season) async {
        fetchedSeasons.add(season);
        return nextSeason;
      },
      isDownloaded: (id) async => downloaded.contains(id),
      navigate: (episodeId, fileId, title, {required seasonNumber}) async {
        navigations.add((episodeId, fileId, title, seasonNumber));
      },
      playingSignal: () => playing,
      isEpisode: () => true,
      hasShow: () => true,
      seasonNumber: () => 1,
      isDownloadedSource: () => downloadedSource,
      mounted: () => isMounted,
      onChanged: () => changes++,
    );
  }

  final Set<String> downloaded;
  final List<PlaybackEpisode>? nextSeason;
  final bool downloadedSource;
  final PlayingSignal? playing;
  late final UpNextController controller;
  final fetchedSeasons = <int>[];
  final navigations = <(String, String, String, int)>[];
  var isMounted = true;
  var changes = 0;
}

void main() {
  final season = [_ep(1), _ep(2), _ep(3)];

  test('offers the next episode in the season', () {
    final h = _Harness();
    h.controller.setSeason(season, currentEpisodeId: 's1e1');
    h.controller.onPositionTick();
    expect(h.controller.showing, isTrue);
    expect(h.controller.target?.episodeId, 's1e2');
    expect(h.changes, 1);
    h.controller.dispose();
  });

  test('hasNext and hasPrevious follow the index', () {
    final h = _Harness();
    expect(h.controller.hasNext, isFalse);
    h.controller.setSeason(season, currentEpisodeId: 's1e1');
    expect(h.controller.hasPrevious, isFalse);
    expect(h.controller.hasNext, isTrue);
    h.controller.setSeason(season, currentEpisodeId: 's1e3');
    expect(h.controller.hasPrevious, isTrue);
    expect(h.controller.hasNext, isFalse);
  });

  test('at season end, fetches the next season once and offers its premiere',
      () async {
    final h = _Harness(nextSeason: [_ep(2, season: 2), _ep(1, season: 2)]);
    h.controller.setSeason(season, currentEpisodeId: 's1e3');
    h.controller.onPositionTick();
    expect(h.controller.showing, isFalse);
    await Future<void>.delayed(Duration.zero);
    h.controller.onPositionTick();
    h.controller.onPositionTick();
    expect(h.fetchedSeasons, [2]);
    expect(h.controller.target?.episodeId, 's2e1');
    expect(h.controller.target?.crossesSeason, isTrue);
    h.controller.dispose();
  });

  test('resetNextSeason lets the lookup run again', () async {
    final h = _Harness(nextSeason: const []);
    h.controller.setSeason(season, currentEpisodeId: 's1e3');
    h.controller.onPositionTick();
    await Future<void>.delayed(Duration.zero);
    h.controller.resetNextSeason();
    h.controller.onPositionTick();
    expect(h.fetchedSeasons, [2, 2]);
  });

  test('a downloaded source only offers a downloaded next episode', () async {
    final notDownloaded = _Harness(downloadedSource: true);
    notDownloaded.controller.setSeason(season, currentEpisodeId: 's1e1');
    notDownloaded.controller.onPositionTick();
    await Future<void>.delayed(Duration.zero);
    expect(notDownloaded.controller.showing, isFalse);

    final downloaded = _Harness(downloadedSource: true, downloaded: {'s1e2'});
    downloaded.controller.setSeason(season, currentEpisodeId: 's1e1');
    downloaded.controller.onPositionTick();
    await Future<void>.delayed(Duration.zero);
    expect(downloaded.controller.showing, isTrue);
    downloaded.controller.dispose();
  });

  test('the countdown navigates when it elapses', () {
    fakeAsync((async) {
      final h = _Harness();
      h.controller.setSeason(season, currentEpisodeId: 's1e1');
      h.controller.onPositionTick();
      async.elapse(kUpNextCountdown + const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(h.navigations.single.$1, 's1e2');
      expect(h.navigations.single.$4, 1);
      h.controller.dispose();
    });
  });

  test('cancel stops the countdown synchronously and blocks auto-play', () {
    fakeAsync((async) {
      final h = _Harness();
      h.controller.setSeason(season, currentEpisodeId: 's1e1');
      h.controller.onPositionTick();
      h.controller.cancel();
      expect(h.controller.showing, isFalse);
      async.elapse(kUpNextCountdown + const Duration(seconds: 2));
      expect(h.navigations, isEmpty);
      // Re-offering is suppressed for the rest of the file.
      h.controller.onPositionTick();
      expect(h.controller.showing, isFalse);
      h.controller.dispose();
    });
  });

  test('a manual next still navigates after a cancel', () async {
    final h = _Harness();
    h.controller.setSeason(season, currentEpisodeId: 's1e1');
    h.controller.onPositionTick();
    h.controller.cancel();
    h.controller.playNext();
    await Future<void>.delayed(Duration.zero);
    expect(h.navigations.single.$1, 's1e2');
  });

  test('an auto-countdown fire after cancel is blocked', () async {
    final h = _Harness();
    h.controller.setSeason(season, currentEpisodeId: 's1e1');
    h.controller.onPositionTick();
    h.controller.cancel();
    h.controller.playNext(fromAutoCountdown: true);
    await Future<void>.delayed(Duration.zero);
    expect(h.navigations, isEmpty);
  });

  test('playNext with no prompt resolves the in-season next', () async {
    final h = _Harness();
    h.controller.setSeason(season, currentEpisodeId: 's1e2');
    h.controller.playNext();
    await Future<void>.delayed(Duration.zero);
    expect(h.navigations.single.$1, 's1e3');
  });

  test('playPrevious builds the route title from the episode', () async {
    final h = _Harness();
    h.controller.setSeason(season, currentEpisodeId: 's1e2');
    h.controller.playPrevious();
    await Future<void>.delayed(Duration.zero);
    expect(h.navigations.single, ('s1e1', 'file-s1e1', 'S1E1 - Episode 1', 1));
  });

  test('a paused player holds the countdown until it resumes', () async {
    final changes = StreamController<bool>.broadcast();
    final h = _Harness(playing: (playing: false, changes: changes.stream));
    h.controller.setSeason(season, currentEpisodeId: 's1e1');
    h.controller.onPositionTick();
    expect(h.controller.countdown?.isHeld, isTrue);
    changes.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(h.controller.countdown?.isHeld, isFalse);
    h.controller.dispose();
    await changes.close();
  });

  test('an unmounted screen gets a countdown but no prompt', () {
    final h = _Harness()..isMounted = false;
    h.controller.setSeason(season, currentEpisodeId: 's1e1');
    h.controller.onPositionTick();
    expect(h.controller.showing, isFalse);
    expect(h.changes, 0);
    h.controller.dispose();
  });

  test('reset forgets the prompt and the cancel', () {
    final h = _Harness();
    h.controller.setSeason(season, currentEpisodeId: 's1e1');
    h.controller.onPositionTick();
    h.controller.cancel();
    h.controller.reset();
    expect(h.controller.countdown, isNull);
    expect(h.controller.target, isNull);
    h.controller.onPositionTick();
    expect(h.controller.showing, isTrue);
    h.controller.dispose();
  });

  test('clearSeason drops the episode list', () {
    final h = _Harness();
    h.controller.setSeason(season, currentEpisodeId: 's1e1');
    h.controller.clearSeason();
    expect(h.controller.hasNext, isFalse);
  });
}
