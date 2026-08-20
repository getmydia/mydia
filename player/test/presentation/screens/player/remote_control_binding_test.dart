// Unit coverage for the pure functions backing `_PlayerScreenState`'s
// `RemotePlayerBinding` implementation: the wire's 0.0-1.0 volume level
// converted to and from media_kit's 0-100 scale, the mute-via-volume-snap
// semantics, the null-safe track lookup every `selectTrack` branch depends
// on, and the loading/error/buffering/completed/playing precedence in
// `_remoteControlPlaybackState`.
//
// Extracted rather than tested through a mounted `PlayerScreen`, for the
// same reason as `shouldRestartForSeek` (see that file's own comment):
// `PlayerScreen` always constructs a bare, real media_kit `Player()`, which
// needs native mpv/FFI not available under `flutter test`, and
// `_waitForPlaylist` polls a URL `flutter_test`'s `HttpOverrides` answers
// with 400 on every attempt, so the screen reaches its error state before a
// player is ever usable — `RemoteTargetController`'s own test suite covers
// dispatch through a hand-written `FakePlayerBinding`, but never reaches this
// arithmetic. `RemoteTargetController`'s tests cover the *dispatch*; this
// file covers the *conversions and mapping* `PlayerScreen`'s real binding
// does that a fake never exercises.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/native/lib.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

void main() {
  group('remoteControlVolumeToPlayerVolume', () {
    test('maps the wire\'s 0.0-1.0 onto media_kit\'s 0-100', () {
      expect(remoteControlVolumeToPlayerVolume(0.0), 0.0);
      expect(remoteControlVolumeToPlayerVolume(1.0), 100.0);
      expect(remoteControlVolumeToPlayerVolume(0.4), closeTo(40.0, 0.0001));
    });

    test('clamps a level below 0 rather than passing it through negative', () {
      expect(remoteControlVolumeToPlayerVolume(-0.5), 0.0);
    });

    test('clamps a level above 1 rather than overdriving the player', () {
      expect(remoteControlVolumeToPlayerVolume(1.5), 100.0);
    });
  });

  group('playerVolumeToRemoteControlVolume', () {
    test('is the exact inverse of remoteControlVolumeToPlayerVolume', () {
      expect(playerVolumeToRemoteControlVolume(0.0), 0.0);
      expect(playerVolumeToRemoteControlVolume(100.0), 1.0);
      expect(playerVolumeToRemoteControlVolume(40.0), closeTo(0.4, 0.0001));
    });

    test('round-trips through both conversions unchanged', () {
      for (final level in [0.0, 0.25, 0.4, 0.8, 1.0]) {
        final roundTripped = playerVolumeToRemoteControlVolume(
          remoteControlVolumeToPlayerVolume(level),
        );
        expect(roundTripped, closeTo(level, 0.0001));
      }
    });
  });

  group('remoteControlMuteVolume', () {
    test('muting snaps volume to 0', () {
      expect(remoteControlMuteVolume(true), 0.0);
    });

    test('unmuting snaps volume to full, not a remembered previous level', () {
      expect(remoteControlMuteVolume(false), 100.0);
    });
  });

  group('isPlayerVolumeMuted', () {
    test('zero volume reads as muted', () {
      expect(isPlayerVolumeMuted(0.0), isTrue);
    });

    test('any non-zero volume reads as not muted', () {
      expect(isPlayerVolumeMuted(0.01), isFalse);
      expect(isPlayerVolumeMuted(100.0), isFalse);
    });

    test('no player at all reads as not muted, not an error', () {
      expect(isPlayerVolumeMuted(null), isFalse);
    });

    test(
        'the mute-via-volume-snap round trip: describe() sees exactly what '
        'setMuted just set', () {
      expect(isPlayerVolumeMuted(remoteControlMuteVolume(true)), isTrue);
      expect(isPlayerVolumeMuted(remoteControlMuteVolume(false)), isFalse);
    });
  });

  group('findTrackById', () {
    test('finds the element whose idOf matches', () {
      final found = findTrackById(['eng', 'spa', 'fre'], 'spa', idOf: (s) => s);
      expect(found, 'spa');
    });

    test(
        'a remote-supplied id absent from the list resolves to null, not a throw',
        () {
      final found = findTrackById(['eng', 'spa'], 'jpn', idOf: (s) => s);
      expect(found, isNull);
    });

    test('an empty track list resolves to null', () {
      final found = findTrackById(<String>[], 'eng', idOf: (s) => s);
      expect(found, isNull);
    });

    test('works against the real domain type selectTrack actually searches',
        () {
      // Not just a generic-with-strings smoke test: this is the exact call
      // shape `selectTrack`'s audio branch makes against `_audioTracks`.
      const tracks = [
        FlutterTrackInfo(id: 'a1', label: 'English'),
        FlutterTrackInfo(id: 'a2', label: 'Spanish'),
      ];

      final found = findTrackById(tracks, 'a2', idOf: (t) => t.id);
      expect(found?.label, 'Spanish');

      final missing = findTrackById(tracks, 'a3', idOf: (t) => t.id);
      expect(missing, isNull);
    });
  });

  group('remoteControlPlaybackState', () {
    test('an error wins over every other flag, including playing', () {
      final state = remoteControlPlaybackState(
        hasError: true,
        isLoading: false,
        hasPlayer: true,
        buffering: false,
        completed: false,
        playing: true,
      );
      expect(state, FlutterPlaybackState.error);
    });

    test('the screen still loading wins over a live player that is playing',
        () {
      final state = remoteControlPlaybackState(
        hasError: false,
        isLoading: true,
        hasPlayer: true,
        buffering: false,
        completed: true,
        playing: true,
      );
      expect(state, FlutterPlaybackState.loading);
    });

    test('no player mounted at all reads as loading', () {
      final state = remoteControlPlaybackState(
        hasError: false,
        isLoading: false,
        hasPlayer: false,
        buffering: false,
        completed: false,
        playing: false,
      );
      expect(state, FlutterPlaybackState.loading);
    });

    test('buffering wins over playing, since media_kit can report both at once',
        () {
      final state = remoteControlPlaybackState(
        hasError: false,
        isLoading: false,
        hasPlayer: true,
        buffering: true,
        completed: false,
        playing: true,
      );
      expect(state, FlutterPlaybackState.buffering);
    });

    test('completed wins over playing, for a file media_kit has already ended',
        () {
      final state = remoteControlPlaybackState(
        hasError: false,
        isLoading: false,
        hasPlayer: true,
        buffering: false,
        completed: true,
        playing: true,
      );
      expect(state, FlutterPlaybackState.ended);
    });

    test(
        'a live, unbuffered, uncompleted player reports playing or paused '
        'off the playing flag alone', () {
      final playing = remoteControlPlaybackState(
        hasError: false,
        isLoading: false,
        hasPlayer: true,
        buffering: false,
        completed: false,
        playing: true,
      );
      expect(playing, FlutterPlaybackState.playing);

      final paused = remoteControlPlaybackState(
        hasError: false,
        isLoading: false,
        hasPlayer: true,
        buffering: false,
        completed: false,
        playing: false,
      );
      expect(paused, FlutterPlaybackState.paused);
    });
  });
}
