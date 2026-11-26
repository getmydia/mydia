import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart' show SourceId;
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/playback_sequence.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';
import 'package:player/presentation/screens/player/up_next_controller.dart';
import 'package:player/presentation/widgets/video_controls/up_next_countdown.dart';

SequenceNeighbour _scene(String id, int position) => SequenceNeighbour(
  item: ItemSummary(
    ref: ItemRef(
      sourceId: const SourceId('stash-1'),
      kind: ItemKind.movie,
      externalId: id,
    ),
    title: 'Invented Scene $id',
    subtitle: 'Invented Studio',
    defaultVersionId: 'file-$id',
  ),
  position: position,
);

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
    this.episode = true,
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
      navigateSequence: (n) async => sceneNavigations.add(n),
      playingSignal: () => playing,
      isEpisode: () => episode,
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
  final bool episode;
  late final UpNextController controller;
  final sceneNavigations = <SequenceNeighbour>[];
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

  test(
    'at season end, fetches the next season once and offers its premiere',
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
    },
  );

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

  test('completion does nothing for an episode', () {
    final h = _Harness();
    h.controller.setSeason(season, currentEpisodeId: 's1e1');
    h.controller.onPlaybackCompleted();
    expect(h.navigations, isEmpty);
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

  group('scene sequence', () {
    final previous = _scene('p', 3);
    final next = _scene('n', 5);

    test('previous and next come from the sequence', () {
      final h = _Harness(episode: false);
      expect(h.controller.hasSequence, isFalse);
      h.controller.setSequence(
        SequenceNeighbours(previous: previous, next: next),
      );
      expect(h.controller.hasSequence, isTrue);
      expect(h.controller.hasPrevious, isTrue);
      expect(h.controller.hasNext, isTrue);

      h.controller.playNext();
      h.controller.playPrevious();
      expect(h.sceneNavigations, [next, previous]);
      expect(h.navigations, isEmpty);
    });

    test('without a next scene, nothing is offered', () {
      final h = _Harness(episode: false);
      h.controller.setSequence(SequenceNeighbours(previous: previous));
      expect(h.controller.hasNext, isFalse);
      expect(h.controller.hasPrevious, isTrue);
      h.controller.onPositionTick();
      expect(h.controller.showing, isFalse);
      h.controller.playNext();
      expect(h.sceneNavigations, isEmpty);
    });

    test('offers the next scene for a movie-typed item', () {
      final h = _Harness(episode: false);
      h.controller.setSequence(SequenceNeighbours(next: next));
      h.controller.onPositionTick();
      expect(h.controller.showing, isTrue);
      expect(h.controller.target?.scene, next);
      expect(h.controller.target?.title, 'Invented Scene n');
      h.controller.dispose();
    });

    test('no amount of wall-clock time advances before the scene ends', () {
      fakeAsync((async) {
        final h = _Harness(episode: false);
        h.controller.setSequence(SequenceNeighbours(next: next));
        h.controller.trackScene(
          position: const Duration(seconds: 270),
          duration: const Duration(seconds: 300),
        );
        h.controller.onPositionTick();
        expect(h.controller.showing, isTrue);
        async.elapse(const Duration(minutes: 5));
        async.flushMicrotasks();
        expect(h.sceneNavigations, isEmpty);
        h.controller.dispose();
      });
    });

    test('the ring tracks the scene remaining over its window', () {
      final h = _Harness(episode: false);
      h.controller.setSequence(SequenceNeighbours(next: next));
      // 300s scene: a 30s window.
      h.controller.trackScene(
        position: const Duration(seconds: 270),
        duration: const Duration(seconds: 300),
      );
      h.controller.onPositionTick();
      expect(h.controller.countdown?.fraction, 1.0);
      h.controller.trackScene(
        position: const Duration(seconds: 285),
        duration: const Duration(seconds: 300),
      );
      expect(h.controller.countdown?.fraction, closeTo(0.5, 0.001));
      expect(h.controller.countdown?.remaining, const Duration(seconds: 15));
      h.controller.dispose();
    });

    test('completion advances to the next scene, once', () {
      final h = _Harness(episode: false);
      h.controller.setSequence(SequenceNeighbours(next: next));
      h.controller.onPositionTick();
      h.controller.onPlaybackCompleted();
      h.controller.onPlaybackCompleted();
      expect(h.sceneNavigations, [next]);
      h.controller.dispose();
    });

    test('completion advances even when the prompt never showed', () {
      final h = _Harness(episode: false);
      h.controller.setSequence(SequenceNeighbours(next: next));
      h.controller.onPlaybackCompleted();
      expect(h.sceneNavigations, [next]);
    });

    test('after a cancel completion does not navigate, a manual next '
        'does', () {
      final h = _Harness(episode: false);
      h.controller.setSequence(SequenceNeighbours(next: next));
      h.controller.onPositionTick();
      h.controller.cancel();
      h.controller.onPlaybackCompleted();
      expect(h.sceneNavigations, isEmpty);
      h.controller.playNext();
      expect(h.sceneNavigations, [next]);
      h.controller.dispose();
    });

    test('reset lets a new file advance on completion again', () {
      final h = _Harness(episode: false);
      h.controller.setSequence(SequenceNeighbours(next: next));
      h.controller.onPlaybackCompleted();
      h.controller.reset();
      h.controller.onPlaybackCompleted();
      expect(h.sceneNavigations, [next, next]);
    });

    test('a completion well before the end is a dead stream, not an end', () {
      final h = _Harness(episode: false);
      h.controller.setSequence(SequenceNeighbours(next: next));
      h.controller.trackScene(
        position: const Duration(seconds: 120),
        duration: const Duration(seconds: 300),
      );
      h.controller.onPlaybackCompleted();
      expect(h.sceneNavigations, isEmpty);

      h.controller.trackScene(
        position: const Duration(milliseconds: 298500),
        duration: const Duration(seconds: 300),
      );
      h.controller.onPlaybackCompleted();
      expect(h.sceneNavigations, [next]);
    });

    test('without a next scene, completion does nothing', () {
      final h = _Harness(episode: false);
      h.controller.setSequence(SequenceNeighbours(previous: previous));
      h.controller.onPlaybackCompleted();
      expect(h.sceneNavigations, isEmpty);
    });

    test('clearSequence returns to season mode', () {
      final h = _Harness();
      h.controller.setSequence(SequenceNeighbours(next: next));
      h.controller.clearSequence();
      expect(h.controller.hasSequence, isFalse);
      expect(h.controller.hasNext, isFalse);
      h.controller.setSeason(season, currentEpisodeId: 's1e1');
      expect(h.controller.hasNext, isTrue);
    });
  });
}
