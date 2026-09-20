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

  group('subtitlePreferenceLanguageEquals', () {
    test('matches the ISO 639-1 and 639-2 pairs the server knows', () {
      // The player and the server both decide "is this the same language"
      // about the same file: the server in SubtitlePreferences.operator_default/1
      // via LanguageCode.matches?/2, the player here. Two tables of different
      // sizes gave two answers.
      expect(subtitlePreferenceLanguageEquals('sv', 'swe'), isTrue);
      expect(subtitlePreferenceLanguageEquals('pl', 'pol'), isTrue);
      expect(subtitlePreferenceLanguageEquals('da', 'dan'), isTrue);
      expect(subtitlePreferenceLanguageEquals('he', 'heb'), isTrue);

      // ISO 639-2/B against /T, which is the pair Matroska actually writes.
      expect(subtitlePreferenceLanguageEquals('sq', 'alb'), isTrue);
      expect(subtitlePreferenceLanguageEquals('mkd', 'mac'), isTrue);

      // Still refused, on both sides: an untagged or undetermined track must
      // not satisfy a request for a specific language.
      expect(subtitlePreferenceLanguageEquals('und', 'eng'), isFalse);
      expect(subtitlePreferenceLanguageEquals('', 'eng'), isFalse);
      expect(subtitlePreferenceLanguageEquals('sv', 'nor'), isFalse);
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

  group('preferredSubtitleJsonForFile', () {
    // The generated shape of `subtitle_preference.graphql`: a root field, its
    // files, and each file's `preferredSubtitle`. Written as raw JSON because
    // that is what the helper reads, for the reason its own dartdoc gives.
    Map<String, dynamic> response(String root, List<Object?> files) => {
          root: {'id': 'media-1', 'files': files},
        };

    Map<String, dynamic> file(String id, Object? preferred) => {
          'id': id,
          'preferredSubtitle': preferred,
        };

    const preferred = {'mode': 'TRACK', 'language': 'eng'};

    test('reads the entry for the file id it was given, not the first one', () {
      final data = response('movie', [
        file('file-a', null),
        file('file-b', preferred),
      ]);

      expect(
        preferredSubtitleJsonForFile(data, root: 'movie', fileId: 'file-b'),
        preferred,
      );
    });

    test('the episode root carries the same shape', () {
      final data = response('episode', [file('file-a', preferred)]);

      expect(
        preferredSubtitleJsonForFile(data, root: 'episode', fileId: 'file-a'),
        preferred,
      );
    });

    test('a missing root, file, or preference is no opinion', () {
      // Junk entries are in the list because a response is decoded JSON, not a
      // typed object: a file the query did not select for still has to be
      // skipped rather than read as one.
      final data = response('movie', [
        null,
        'not a file',
        file('file-a', null),
      ]);

      for (final missing in [
        preferredSubtitleJsonForFile({'episode': data['movie']},
            root: 'movie', fileId: 'file-a'),
        preferredSubtitleJsonForFile(data, root: 'movie', fileId: 'file-b'),
        preferredSubtitleJsonForFile(data, root: 'movie', fileId: 'file-a'),
        preferredSubtitleJsonForFile({'movie': 'not a root'},
            root: 'movie', fileId: 'file-a'),
      ]) {
        expect(missing, isNull);
      }
    });
  });
}
