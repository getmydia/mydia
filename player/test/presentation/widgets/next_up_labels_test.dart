import 'package:flutter/material.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';
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

final _en = lookupAppLocalizations(const Locale('en'));

// Progress requires positionSeconds, percentage and watched; durationSeconds
// and lastWatchedAt are optional. See player/lib/domain/models/progress.dart.

void main() {
  group('nextUpLabel', () {
    test('matches the web UI wording', () {
      expect(
          nextUpLabel(_en, NextUpState.continueWatching), 'Continue Watching');
      expect(nextUpLabel(_en, NextUpState.next), 'Play Next Episode');
      expect(nextUpLabel(_en, NextUpState.start), 'Start Watching');
      expect(nextUpLabel(_en, NextUpState.unknown), 'Play');
    });
  });

  group('remainingMinutes', () {
    test('prefers the duration recorded during playback', () {
      final episode = _episode(
        runtimeMinutes: 60,
        positionSeconds: 600,
        durationSeconds: 2700,
      );
      // The two sources deliberately disagree so precedence is observable:
      // the recorded duration gives (2700 - 600) / 60 = 35, while provider
      // runtime would give 60 - 10 = 50. Getting 35 proves the recorded
      // duration wins.
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
        nextUpCueLine(_en, episode, NextUpState.continueWatching,
            resolution: '1080p'),
        'S02E05 · 1080p · 35 min left',
      );
      expect(
        nextUpCueLine(_en, episode, NextUpState.next, resolution: '1080p'),
        'S02E05 · 1080p',
      );
    });

    test('omits the resolution when none is known', () {
      expect(
        nextUpCueLine(_en, _episode(), NextUpState.start),
        'S02E05',
      );
    });
  });
}
