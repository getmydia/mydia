import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/subtitle_track.dart';
import 'package:player/presentation/screens/player/subtitle_preference.dart';

SubtitleTrack track(
  String id,
  String language, {
  String? title,
  bool forced = false,
  bool hearingImpaired = false,
}) =>
    SubtitleTrack(
      id: id,
      language: language,
      title: title,
      forced: forced,
      hearingImpaired: hearingImpaired,
    );

void main() {
  group('subtitlePreferenceFrom', () {
    test('reads the three server states', () {
      expect(subtitlePreferenceFrom(mode: null), isNull);
      expect(subtitlePreferenceFrom(mode: 'OFF'), isA<PreferOff>());

      final pref = subtitlePreferenceFrom(
        mode: 'TRACK',
        language: 'eng',
        forced: true,
        hearingImpaired: false,
        trackTitle: 'English (Signs & Songs)',
      );
      expect(pref, isA<PreferTrack>());
      expect((pref! as PreferTrack).language, 'eng');
      expect((pref as PreferTrack).forced, isTrue);
    });

    test('a TRACK with no language is not a usable preference', () {
      expect(subtitlePreferenceFrom(mode: 'TRACK', language: null), isNull);
    });
  });

  group('matchSubtitlePreference', () {
    test('separates a forced track from full dialogue in the same language',
        () {
      final tracks = [
        track('2', 'eng', title: 'English (Signs & Songs)', forced: true),
        track('3', 'eng', title: 'English'),
      ];

      final signs = matchSubtitlePreference(
        const PreferTrack(language: 'eng', forced: true),
        tracks,
      );
      expect(signs?.id, '2');

      final dialogue = matchSubtitlePreference(
        const PreferTrack(language: 'eng'),
        tracks,
      );
      expect(dialogue?.id, '3');
    });

    test('prefers an exact hearing-impaired match', () {
      final tracks = [
        track('2', 'eng', title: 'English'),
        track('3', 'eng', title: 'English (SDH)', hearingImpaired: true),
      ];

      final sdh = matchSubtitlePreference(
        const PreferTrack(language: 'eng', hearingImpaired: true),
        tracks,
      );
      expect(sdh?.id, '3');
    });

    test('falls back across a differing hearing-impaired flag', () {
      final tracks = [
        track('3', 'eng', title: 'English (SDH)', hearingImpaired: true)
      ];

      final match = matchSubtitlePreference(
        const PreferTrack(language: 'eng'),
        tracks,
      );
      expect(match?.id, '3');
    });

    test('breaks a tie on the remembered title', () {
      final tracks = [
        track('2', 'eng', title: 'English (Netherfield rip)'),
        track('3', 'eng', title: 'English (Team Verrow)'),
      ];

      final match = matchSubtitlePreference(
        const PreferTrack(language: 'eng', trackTitle: 'English (Team Verrow)'),
        tracks,
      );
      expect(match?.id, '3');
    });

    test('prefers a non-forced track when the preference is not forced', () {
      final tracks = [
        track('2', 'eng', title: 'English (Forced)', forced: true),
        track('3', 'eng', title: 'English'),
      ];

      final match = matchSubtitlePreference(
        const PreferTrack(language: 'eng'),
        tracks,
      );
      expect(match?.id, '3');
    });

    test('returns null when no track carries the language', () {
      final tracks = [track('2', 'jpn', title: 'Japanese')];

      expect(
        matchSubtitlePreference(const PreferTrack(language: 'eng'), tracks),
        isNull,
      );
    });

    test('never matches an untagged track', () {
      final tracks = [
        track('2', 'und', title: 'Subtitle'),
        track('3', '', title: 'Subtitle'),
      ];

      expect(
        matchSubtitlePreference(const PreferTrack(language: 'eng'), tracks),
        isNull,
      );
    });

    test('matches across the two-letter and three-letter forms of a language',
        () {
      final tracks = [track('2', 'ger', title: 'German')];

      expect(
        matchSubtitlePreference(const PreferTrack(language: 'de'), tracks)?.id,
        '2',
      );
    });
  });

  group('shouldApplySubtitlePreference', () {
    test('applies once, on a settled playback the viewer has not touched', () {
      expect(
        shouldApplySubtitlePreference(
          viewerChose: false,
          switchInFlight: false,
          intentPending: false,
          alreadyApplied: false,
          hasTracks: true,
        ),
        isTrue,
      );
    });

    test(
        'never over a viewer pick, a switch, a carried intent, a repeat, or no tracks',
        () {
      for (final blocked in [
        () => shouldApplySubtitlePreference(
            viewerChose: true,
            switchInFlight: false,
            intentPending: false,
            alreadyApplied: false,
            hasTracks: true),
        () => shouldApplySubtitlePreference(
            viewerChose: false,
            switchInFlight: true,
            intentPending: false,
            alreadyApplied: false,
            hasTracks: true),
        () => shouldApplySubtitlePreference(
            viewerChose: false,
            switchInFlight: false,
            intentPending: true,
            alreadyApplied: false,
            hasTracks: true),
        () => shouldApplySubtitlePreference(
            viewerChose: false,
            switchInFlight: false,
            intentPending: false,
            alreadyApplied: true,
            hasTracks: true),
        () => shouldApplySubtitlePreference(
            viewerChose: false,
            switchInFlight: false,
            intentPending: false,
            alreadyApplied: false,
            hasTracks: false),
      ]) {
        expect(blocked(), isFalse);
      }
    });
  });
}
