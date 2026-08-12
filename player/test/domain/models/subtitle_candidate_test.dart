import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/subtitle_candidate.dart';

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
        language: 'sv',
        format: 'srt',
        hearingImpaired: false,
        hashMatch: false,
        score: 10,
        providerName: 'p',
      );
      expect(other.displayLanguage, 'SV');
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
}
