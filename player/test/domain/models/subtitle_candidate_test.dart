import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/subtitle_candidate.dart';
import 'package:player/graphql/queries/subtitle_search.graphql.dart';

void main() {
  group('SubtitleCandidate', () {
    const candidate = SubtitleCandidate(
      token: 'signed-token',
      language: 'en',
      releaseName: 'Movie.2020.1080p.BluRay.srt',
      format: 'srt',
      rating: 8.5,
      downloadCount: 4200,
      hearingImpaired: false,
      hashMatch: true,
      score: 180,
      providerName: 'Mydia Relay',
    );

    test('renders a human language name', () {
      expect(candidate.displayLanguage, 'English');
    });

    test('falls back to the uppercased code for unmapped languages', () {
      const other = SubtitleCandidate(
        token: 't',
        language: 'th',
        format: 'srt',
        hearingImpaired: false,
        hashMatch: false,
        score: 10,
        providerName: 'p',
      );
      expect(other.displayLanguage, 'TH');
    });
  });

  group('SubtitleCandidate.toIso6391', () {
    test('maps a three-letter ISO 639-2 code to its two-letter equivalent', () {
      expect(SubtitleCandidate.toIso6391('eng'), 'en');
    });

    test('passes through a code that is already two letters', () {
      expect(SubtitleCandidate.toIso6391('en'), 'en');
    });

    test('returns null for an unrecognised three-letter code', () {
      expect(SubtitleCandidate.toIso6391('xyz'), isNull);
    });

    test('maps both three-letter forms of French', () {
      expect(SubtitleCandidate.toIso6391('fre'), 'fr');
      expect(SubtitleCandidate.toIso6391('fra'), 'fr');
    });

    test('maps both three-letter forms of German', () {
      expect(SubtitleCandidate.toIso6391('ger'), 'de');
      expect(SubtitleCandidate.toIso6391('deu'), 'de');
    });

    test('maps both three-letter forms of Chinese', () {
      expect(SubtitleCandidate.toIso6391('chi'), 'zh');
      expect(SubtitleCandidate.toIso6391('zho'), 'zh');
    });

    test('maps both three-letter forms of Dutch', () {
      expect(SubtitleCandidate.toIso6391('dut'), 'nl');
      expect(SubtitleCandidate.toIso6391('nld'), 'nl');
    });
  });

  group('SubtitleProviderStatus', () {
    test('labels a known quota', () {
      const status = SubtitleProviderStatus(
        name: 'My OpenSubtitles',
        quotaRemaining: 42,
        quotaTotal: 200,
      );
      expect(status.quotaLabel, '42 of 200 left today');
    });

    test('has no label when the quota is unknown', () {
      const status = SubtitleProviderStatus(name: 'Mydia Relay');
      expect(status.quotaLabel, isNull);
    });

    test('reports failure', () {
      const status = SubtitleProviderStatus(
        name: 'My OpenSubtitles',
        error: 'Daily quota exhausted',
      );
      expect(status.failed, isTrue);
    });

    test('does not report failure when there is no error', () {
      const status = SubtitleProviderStatus(name: 'Mydia Relay');
      expect(status.failed, isFalse);
    });
  });

  group('SubtitleCandidate.fromGraphQL', () {
    Query$SubtitleSearch$subtitleSearch$results result({
      String token = 'signed-token',
      String language = 'en',
      String? releaseName = 'Movie.2020.1080p.BluRay.srt',
      String format = 'srt',
      double? rating = 8.5,
      int? downloadCount = 4200,
      bool hearingImpaired = false,
      bool hashMatch = true,
      int score = 180,
      String providerName = 'Mydia Relay',
    }) {
      return Query$SubtitleSearch$subtitleSearch$results(
        token: token,
        language: language,
        releaseName: releaseName,
        format: format,
        rating: rating,
        downloadCount: downloadCount,
        hearingImpaired: hearingImpaired,
        hashMatch: hashMatch,
        score: score,
        providerName: providerName,
      );
    }

    test('carries the token, which is the only handle download accepts', () {
      final candidate = SubtitleCandidate.fromGraphQL(result(token: 'tok-9'));

      expect(candidate.token, 'tok-9');
    });

    test('carries the server\'s score rather than re-deriving one', () {
      // The server weighs a hash match, the provider rating and popularity
      // together. A factory that recomputed or dropped this would reorder
      // the results list away from what the server ranked.
      final candidate = SubtitleCandidate.fromGraphQL(result(score: 205));

      expect(candidate.score, 205);
    });

    test('carries every field the results tile renders', () {
      final candidate = SubtitleCandidate.fromGraphQL(result(
        language: 'es',
        releaseName: 'Movie.2020.HI.srt',
        format: 'vtt',
        rating: 6.5,
        downloadCount: 12,
        hearingImpaired: true,
        hashMatch: false,
        providerName: 'My OpenSubtitles',
      ));

      expect(candidate.language, 'es');
      expect(candidate.releaseName, 'Movie.2020.HI.srt');
      expect(candidate.format, 'vtt');
      expect(candidate.rating, 6.5);
      expect(candidate.downloadCount, 12);
      expect(candidate.hearingImpaired, isTrue);
      expect(candidate.hashMatch, isFalse);
      expect(candidate.providerName, 'My OpenSubtitles');
    });

    test('keeps the optional fields null rather than substituting defaults',
        () {
      // A provider that reports no rating must not read as a zero-rated
      // subtitle: the tile hides the figure when it is null and would show
      // a misleading "0.0" otherwise.
      final candidate = SubtitleCandidate.fromGraphQL(result(
        releaseName: null,
        rating: null,
        downloadCount: null,
      ));

      expect(candidate.releaseName, isNull);
      expect(candidate.rating, isNull);
      expect(candidate.downloadCount, isNull);
    });
  });

  group('SubtitleProviderStatus.fromGraphQL', () {
    test('carries a provider\'s failure reason through', () {
      final status = SubtitleProviderStatus.fromGraphQL(
        Query$SubtitleSearch$subtitleSearch$providers(
          name: 'My OpenSubtitles',
          error: 'Daily quota exhausted',
        ),
      );

      expect(status.name, 'My OpenSubtitles');
      expect(status.error, 'Daily quota exhausted');
      expect(status.failed, isTrue);
    });

    test('carries a known quota so the sheet can label it', () {
      final status = SubtitleProviderStatus.fromGraphQL(
        Query$SubtitleSearch$subtitleSearch$providers(
          name: 'My OpenSubtitles',
          quotaRemaining: 42,
          quotaTotal: 200,
        ),
      );

      expect(status.quotaLabel, '42 of 200 left today');
      expect(status.failed, isFalse);
    });

    test('leaves an unknown quota null rather than zero', () {
      // The relay reports no quota at all (it is unlimited from the
      // client's side). Zeroes here would render "0 of 0 left today".
      final status = SubtitleProviderStatus.fromGraphQL(
        Query$SubtitleSearch$subtitleSearch$providers(name: 'Mydia Relay'),
      );

      expect(status.quotaRemaining, isNull);
      expect(status.quotaTotal, isNull);
      expect(status.quotaLabel, isNull);
    });
  });
}
