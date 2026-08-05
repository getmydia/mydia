// Unit coverage for `detectAudioTracks` and `watchAudioTracks`, the pure
// pieces extracted from `_PlayerScreenState._detectTracks`.
//
// Extracted (rather than tested through a fully mounted `PlayerScreen`) for
// the same reason as `seek_restart_decision_test.dart`: reaching a non-null
// `_player` under `flutter test` needs a real, native-backed media_kit
// `Player`, and `PlayerScreen` always builds a bare `Player()` with no seam
// to substitute a fake. media_kit's `Tracks`/`AudioTrack` are plain const
// data classes with no native dependency, so the mapping and the
// late-arrival behaviour can both be driven directly.
//
// The late-arrival group is the one that matters. Track detection used to run
// exactly once, after a fixed 500ms sleep following `player.open(play:
// false)`, and nothing ever re-ran it. mpv discovers tracks asynchronously
// while it probes, so a file whose probe outran that sleep — a 4K HEVC remote
// stream, say — left the audio list permanently empty and the audio button
// disabled, with no way to reach a second language.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

/// The dual-language shape that exposed this: Italian first and flagged
/// default, English second. Mirrors the real streams in
/// `Silo.S03E03.A.Dark.Web.2160p...ENG.ITA...mkv`.
const _italian = AudioTrack('1', null, 'ita', isDefault: true);
const _english = AudioTrack('2', null, 'eng');

/// What media_kit reports before it has probed the file: sentinels only.
const _sentinelsOnly = Tracks();

void main() {
  group('detectAudioTracks', () {
    test('skips the auto and no sentinels', () {
      final detection = detectAudioTracks(const [
        AudioTrack('auto', null, null),
        AudioTrack('no', null, null),
      ]);

      expect(detection.tracks, isEmpty);
      expect(detection.byId, isEmpty);
    });

    test('reports both languages of a dual-language file', () {
      final detection = detectAudioTracks(const [
        AudioTrack('auto', null, null),
        AudioTrack('no', null, null),
        _italian,
        _english,
      ]);

      expect(detection.tracks.map((t) => t.language), ['ita', 'eng']);
      expect(
        detection.tracks.map((t) => t.displayName),
        ['Italian', 'English'],
      );
    });

    test('resolves each app track back to its media_kit track', () {
      final detection = detectAudioTracks(const [_italian, _english]);

      // The reverse lookup is what `_showAudioSelector` hands to
      // `player.setAudioTrack`, so a broken mapping silently no-ops the
      // user's choice.
      for (final track in detection.tracks) {
        expect(detection.byId[track.id], isNotNull);
        expect(detection.byId[track.id]!.id, track.id);
      }
    });

    test('marks the track media_kit flagged default, not merely the first', () {
      final detection = detectAudioTracks(const [_english, _italian]);

      final byLanguage = {for (final t in detection.tracks) t.language: t};
      expect(byLanguage['ita']!.isDefault, isTrue);
      expect(byLanguage['eng']!.isDefault, isFalse);
    });

    test('falls back to the first track when nothing is flagged default', () {
      final detection = detectAudioTracks(const [
        AudioTrack('1', null, 'eng'),
        AudioTrack('2', null, 'fre'),
      ]);

      expect(detection.tracks.first.isDefault, isTrue);
      expect(detection.tracks.last.isDefault, isFalse);
    });

    test('keeps an untagged track selectable rather than dropping it', () {
      final detection = detectAudioTracks(const [AudioTrack('1', null, null)]);

      expect(detection.tracks, hasLength(1));
      expect(detection.tracks.single.language, 'und');
    });
  });

  group('watchAudioTracks', () {
    test('reports tracks that media_kit only discovers after playback opens',
        () async {
      final controller = StreamController<Tracks>();
      addTearDown(controller.close);

      final seen = <AudioTrackDetection>[];
      final subscription = watchAudioTracks(controller.stream, seen.add);
      addTearDown(subscription.cancel);

      // The probe has not finished: this is exactly the state the old fixed
      // 500ms sample could land in.
      controller.add(_sentinelsOnly);
      await pumpEventQueue();
      expect(seen.last.tracks, isEmpty);

      // mpv finishes probing and revises the list.
      controller.add(const Tracks(audio: [_italian, _english]));
      await pumpEventQueue();

      expect(seen.last.tracks.map((t) => t.language), ['ita', 'eng']);
    });

    test('stops reporting once cancelled', () async {
      final controller = StreamController<Tracks>();
      addTearDown(controller.close);

      final seen = <AudioTrackDetection>[];
      final subscription = watchAudioTracks(controller.stream, seen.add);
      await subscription.cancel();

      controller.add(const Tracks(audio: [_italian, _english]));
      await pumpEventQueue();

      expect(seen, isEmpty);
    });
  });
}
