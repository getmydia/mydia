import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/progress.dart';
import 'package:player/domain/models/show_next_up.dart';
import 'package:player/presentation/widgets/next_up_labels.dart';

NextUpEpisode _episode({
  int? runtimeMinutes,
  int? positionSeconds,
  int? durationSeconds,
}) =>
    NextUpEpisode(
      id: '1',
      seasonNumber: 2,
      episodeNumber: 5,
      runtimeMinutes: runtimeMinutes,
      progress: positionSeconds == null
          ? null
          : Progress(
              positionSeconds: positionSeconds,
              durationSeconds: durationSeconds,
              percentage: 0,
              watched: false,
            ),
    );

// Progress requires positionSeconds, percentage and watched; durationSeconds
// and lastWatchedAt are optional. See player/lib/domain/models/progress.dart.

void main() {
  group('nextUpLabel', () {
    test('matches the web UI wording', () {
      expect(nextUpLabel(NextUpState.continueWatching), 'Continue Watching');
      expect(nextUpLabel(NextUpState.next), 'Play Next Episode');
      expect(nextUpLabel(NextUpState.start), 'Start Watching');
      expect(nextUpLabel(NextUpState.unknown), 'Play');
    });
  });

  group('remainingMinutes', () {
    test('prefers the duration recorded during playback', () {
      final episode = _episode(
        runtimeMinutes: 45,
        positionSeconds: 600,
        durationSeconds: 2700,
      );
      // 2700 - 600 = 2100s = 35 min, not the 45 - 10 the metadata implies.
      expect(remainingMinutes(episode), 35);
    });

    test('falls back to provider runtime when duration is absent', () {
      final episode = _episode(runtimeMinutes: 45, positionSeconds: 600);
      expect(remainingMinutes(episode), 35);
    });

    test('returns null when neither source is available', () {
      expect(remainingMinutes(_episode(positionSeconds: 600)), isNull);
    });

    test('returns null when there is no progress at all', () {
      expect(remainingMinutes(_episode(runtimeMinutes: 45)), isNull);
    });
  });

  group('nextUpCueLine', () {
    test('shows time remaining only in the continue state', () {
      final episode = _episode(
        runtimeMinutes: 45,
        positionSeconds: 600,
        durationSeconds: 2700,
      );

      expect(
        nextUpCueLine(episode, NextUpState.continueWatching,
            resolution: '1080p'),
        'S02E05 · 1080p · 35 min left',
      );
      expect(
        nextUpCueLine(episode, NextUpState.next, resolution: '1080p'),
        'S02E05 · 1080p',
      );
    });

    test('omits the resolution when none is known', () {
      expect(
        nextUpCueLine(_episode(), NextUpState.start),
        'S02E05',
      );
    });
  });
}
